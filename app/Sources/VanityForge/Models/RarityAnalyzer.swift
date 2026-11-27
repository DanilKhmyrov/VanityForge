import Foundation

/// Чем красив произвольный адрес и насколько это редкость: вероятность каждого
/// признака у случайного адреса, лучший из них — «сколько попыток стоил бы
/// такой адрес». Оценки те же, что у условий поиска (серия длины n на краю —
/// alphabet^(n−1), конкретное слово длины n на краю — alphabet^n).
struct RarityFeature: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let probability: Double
    /// Какие символы адреса это дают (индексы по строке целиком) — для подсветки.
    let highlight: Range<Int>?
}

struct RarityReport {
    let network: String
    let address: String
    /// Самый редкий признак первым.
    let features: [RarityFeature]

    var best: RarityFeature? { features.first }
    var probability: Double { best?.probability ?? 1 }
    var attempts: Double { 1 / probability }
    var bits: Double { -log2(probability) }

    enum Tier: Int, CaseIterable {
        case ordinary, nice, rare, veryRare, exceptional, legendary

        init(bits: Double) {
            switch bits {
            case ..<14: self = .ordinary
            case ..<24: self = .nice
            case ..<32: self = .rare
            case ..<40: self = .veryRare
            case ..<48: self = .exceptional
            default: self = .legendary
            }
        }

        var label: L {
            switch self {
            case .ordinary: return .tierOrdinary
            case .nice: return .tierNice
            case .rare: return .tierRare
            case .veryRare: return .tierVeryRare
            case .exceptional: return .tierExceptional
            case .legendary: return .tierLegendary
            }
        }
    }

    var tier: Tier { Tier(bits: bits) }
    var highlights: [Range<Int>] { features.compactMap(\.highlight) }
}

enum RarityAnalyzer {
    private static let base58 = Set("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
    private static let tonChars = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    private static let bech32Chars = Set("qpzry9x8gf2tvdw0s3jn54khce6mua7l")

    /// Сеть по виду адреса: eth, trx, btc (bc1q…), btc1 (1…), sol, ton или nil.
    static func network(of raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count == 42, s.hasPrefix("0x"), s.dropFirst(2).allSatisfy(\.isHexDigit) { return "eth" }
        if s.count == 34, s.hasPrefix("T"), s.allSatisfy(base58.contains) { return "trx" }
        let lower = s.lowercased()
        if s.count == 42, lower.hasPrefix("bc1q"), (s == lower || s == s.uppercased()),
           lower.dropFirst(4).allSatisfy(bech32Chars.contains) { return "btc" }
        if (26...34).contains(s.count), s.hasPrefix("1"), s.allSatisfy(base58.contains) { return "btc1" }
        if s.count == 48, ["EQ", "UQ", "kQ", "0Q"].contains(String(s.prefix(2))), s.allSatisfy(tonChars.contains) { return "ton" }
        if (32...44).contains(s.count), s.allSatisfy(base58.contains) { return "sol" }
        return nil
    }

    /// words — слова для поиска в начале и в конце: hex (для EVM) или любые.
    static func analyze(_ raw: String, words: [String], lang: AppLanguage) -> RarityReport? {
        var address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let network = network(of: address) else { return nil }
        if network == "eth" { address = Keccak.checksumAddress(address) }
        let features = network == "eth"
            ? evmFeatures(address, words: words, lang: lang)
            : textFeatures(address, network: network, words: words, lang: lang)
        return RarityReport(network: network, address: address,
                            features: features.sorted { $0.probability < $1.probability })
    }

    private static func run(_ chars: [Character]) -> Int {
        guard let first = chars.first else { return 0 }
        return chars.prefix(while: { $0 == first }).count
    }

    private static func evmFeatures(_ address: String, words: [String], lang: AppLanguage) -> [RarityFeature] {
        let body = Array(address.dropFirst(2).lowercased())
        let n = body.count
        var out: [RarityFeature] = []
        func add(_ title: String, _ p: Double, _ start: Int? = nil, _ length: Int = 0) {
            out.append(RarityFeature(title: title, probability: min(1, p),
                                     highlight: start.map { (2 + $0)..<(2 + $0 + length) }))
        }

        let head = run(body), tail = run(body.reversed())
        if head >= 3 { add(L.rarityRunStart.s(lang).fill(head, body[0]), pow(16, -Double(head - 1)), 0, head) }
        if tail >= 3 { add(L.rarityRunEnd.s(lang).fill(tail, body[n - 1]), pow(16, -Double(tail - 1)), n - tail, tail) }

        // Самая длинная серия внутри (не у краёв).
        var best = (start: 0, length: 0), i = 0
        while i < n {
            var j = i
            while j < n && body[j] == body[i] { j += 1 }
            if i > 0, j < n, j - i > best.length { best = (i, j - i) }
            i = j
        }
        if best.length >= 5 {
            let p = Double(n - best.length + 1) * pow(16, -Double(best.length - 1))
            add(L.rarityRunInside.s(lang).fill(best.length, body[best.start]), p, best.start, best.length)
        }

        let text = String(body)
        for word in Set(words.map { $0.lowercased() }) where word.count >= 4 && word.allSatisfy(\.isHexDigit) {
            let p = pow(16, -Double(word.count))
            if text.hasPrefix(word) { add(L.rarityWordStart.s(lang).replacingOccurrences(of: "{w}", with: word), p, 0, word.count) }
            if text.hasSuffix(word) { add(L.rarityWordEnd.s(lang).replacingOccurrences(of: "{w}", with: word), p, n - word.count, word.count) }
        }

        // Зеркальные края: 0xabcd…dcba.
        var mirror = 0
        while mirror < n / 2 && body[mirror] == body[n - 1 - mirror] { mirror += 1 }
        if mirror >= 4 { add(L.rarityMirror.s(lang).fill(mirror, nil), pow(16, -Double(mirror))) }

        if body.allSatisfy(\.isNumber) { add(L.rarityDigitsOnly.s(lang), pow(10.0 / 16, Double(n))) }
        if body.allSatisfy({ !$0.isNumber }) { add(L.rarityLettersOnly.s(lang), pow(6.0 / 16, Double(n))) }

        // EIP-55: регистр каждой буквы — бит хеша, то есть монетка на букву.
        let checksum = Array(Keccak.checksumAddress(address).dropFirst(2))
        let letters = checksum.filter(\.isLetter)
        if letters.count >= 8 {
            let p = pow(0.5, Double(letters.count))
            if letters.allSatisfy(\.isUppercase) { add(L.rarityChecksumUpper.s(lang).fill(letters.count, nil), p) }
            if letters.allSatisfy(\.isLowercase) { add(L.rarityChecksumLower.s(lang).fill(letters.count, nil), p) }
        }

        let distinct = Set(body).count
        if distinct <= 8 {
            // Все символы — из какого-то набора размера k: C(16, k)·(k/16)^n (верхняя оценка).
            var binom = 1.0
            for k in 0..<distinct { binom = binom * Double(16 - k) / Double(k + 1) }
            let share: Double = pow(Double(distinct) / 16, Double(n))
            add(L.rarityFewChars.s(lang).fill(distinct, nil), binom * share)
        }
        return out
    }

    private static func textFeatures(_ address: String, network: String, words: [String], lang: AppLanguage) -> [RarityFeature] {
        let chars = Array(address)
        let alphabet: Double = network == "ton" ? 64 : (network == "btc" ? 32 : 58)
        // У TRON первая T всегда, у Bitcoin — «1» или «bc1q», у TON — двухбуквенный тег.
        let skip: Int
        switch network {
        case "trx", "btc1": skip = 1
        case "ton": skip = 2
        case "btc": skip = 4
        default: skip = 0
        }
        let body = Array(chars[skip...])
        let n = body.count
        var out: [RarityFeature] = []
        func add(_ title: String, _ p: Double, _ start: Int? = nil, _ length: Int = 0) {
            out.append(RarityFeature(title: title, probability: min(1, p),
                                     highlight: start.map { (skip + $0)..<(skip + $0 + length) }))
        }

        let head = run(body), tail = run(body.reversed())
        if head >= 3 { add(L.rarityRunStart.s(lang).fill(head, body[0]), pow(alphabet, -Double(head - 1)), 0, head) }
        if tail >= 3 { add(L.rarityRunEnd.s(lang).fill(tail, body[n - 1]), pow(alphabet, -Double(tail - 1)), n - tail, tail) }

        let lower = String(body).lowercased()
        let valid = network == "ton" ? tonChars : (network == "btc" ? bech32Chars : base58)
        for word in Set(words.map { $0.lowercased() }) where word.count >= 3 {
            // Без учёта регистра: у буквы до двух написаний в алфавите.
            let p = word.reduce(1.0) { acc, c in
                let variants = Set([Character(c.lowercased()), Character(c.uppercased())]).filter(valid.contains).count
                return acc * Double(variants) / alphabet
            }
            guard p > 0 else { continue }
            if lower.hasPrefix(word) { add(L.rarityWordStart.s(lang).replacingOccurrences(of: "{w}", with: word), p, 0, word.count) }
            if lower.hasSuffix(word) { add(L.rarityWordEnd.s(lang).replacingOccurrences(of: "{w}", with: word), p, n - word.count, word.count) }
        }
        return out
    }
}

private extension String {
    /// «{n}» — число, «{c}» — символ.
    func fill(_ count: Int, _ char: Character?) -> String {
        var s = replacingOccurrences(of: "{n}", with: String(count))
        if let char { s = s.replacingOccurrences(of: "{c}", with: String(char)) }
        return s
    }
}
