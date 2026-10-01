import Observation
import SwiftUI

/// Цвета/градиенты — чисто визуальные детали дизайна, не данные, поэтому
/// живут в Swift. Всё, что является "фактом" о сетях/пресетах, приходит из
/// bridge.py (см. AppCatalog), чтобы не рассинхронизироваться с patterns.py.
enum NetworkVisual {
    static let colors: [String: [Color]] = [
        "sol": [Color(red: 0.60, green: 0.32, blue: 1.00), Color(red: 0.05, green: 0.90, blue: 0.65)],
        "eth": [Color(red: 0.40, green: 0.52, blue: 0.98), Color(red: 0.72, green: 0.80, blue: 0.92)],
        "trx": [Color(red: 0.96, green: 0.22, blue: 0.27), Color(red: 0.98, green: 0.56, blue: 0.24)],
        "ton": [Color(red: 0.16, green: 0.64, blue: 0.98), Color(red: 0.42, green: 0.86, blue: 1.00)],
        "create2": [Color(red: 0.98, green: 0.72, blue: 0.22), Color(red: 0.96, green: 0.42, blue: 0.30)],
        "create3": [Color(red: 0.36, green: 0.86, blue: 0.62), Color(red: 0.18, green: 0.62, blue: 0.86)],
    ]

    static func gradient(for key: String) -> LinearGradient {
        LinearGradient(
            colors: colors[key] ?? [.gray, .gray.opacity(0.6)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static func accent(for key: String) -> Color {
        colors[key]?.first ?? .gray
    }
}

@MainActor
@Observable
final class AppCatalog {
    private(set) var networkOrder: [String] = []
    private(set) var networkNames: [String: String] = [:]
    private(set) var presetsByNetwork: [String: [PresetItem]] = [:]
    /// Размер алфавита адреса и примерная длина "тела" адреса по сети —
    /// приходят из bridge.py (единственный источник истины), нужны только
    /// для мгновенной, посчитанной на лету оценки редкости своего паттерна,
    /// пока пользователь его печатает (без похода в Python на каждый символ).
    private(set) var alphabetSizes: [String: Int] = [:]
    private(set) var bodyLengths: [String: Int] = [:]
    /// Дефолтные слова для условия "word" — приходят из patterns.py, чтобы
    /// не дублировать список в Swift (см. WordListInput в NetworkPresetPicker).
    private(set) var defaultWords: [String] = []
    private(set) var isLoaded = false
    private(set) var loadFailed = false

    func load(lang: AppLanguage = .ru) async {
        guard let event = await PythonBridge.loadCatalog(lang: lang) else {
            loadFailed = true
            return
        }
        networkOrder = event.networkOrder
        networkNames = event.networks
        presetsByNetwork = event.presetsByNetwork
        alphabetSizes = event.alphabetSizes
        bodyLengths = event.bodyLengths
        defaultWords = event.defaultWords
        isLoaded = true
    }

    /// Список пресетов, валидных для всех выбранных сетей одновременно
    /// (пересечение), в порядке первой выбранной сети.
    func presetOptions(for networks: Set<String>) -> [PresetItem] {
        guard !networks.isEmpty else { return [] }
        var commonKeys: Set<String>?
        for net in networks {
            let keys = Set((presetsByNetwork[net] ?? []).map(\.key))
            commonKeys = commonKeys.map { $0.intersection(keys) } ?? keys
        }
        guard let referenceNet = networkOrder.first(where: { networks.contains($0) }),
              let commonKeys else { return [] }
        return (presetsByNetwork[referenceNet] ?? []).filter { commonKeys.contains($0.key) }
    }

    private static let base58 = Set("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
    /// Символы адреса сети (ETH — в нижнем регистре, так их сравнивает bridge.py):
    /// слово с другими символами не совпадёт никогда и в оценку не входит.
    private static let alphabetChars: [String: Set<Character>] = [
        "eth": Set("0123456789abcdef"),
        "sol": base58,
        "trx": base58,
        "ton": Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"),
    ]

    /// «1 из N» для условия «слово в начале или в конце адреса» по выбранным
    /// словам — на самой частой из выбранных сетей. Оценка из bridge.py
    /// считается один раз для стандартного списка и выбор слов не учитывает.
    func wordRarity(words: [String], networks: Set<String>) -> UInt64? {
        var worst = 0.0
        for net in networks {
            let alphabet = Double(alphabetSizes[net] ?? 58)
            let chars = Self.alphabetChars[net]
            let probability = words
                .filter { word in !word.isEmpty && (chars.map { allowed in word.allSatisfy { allowed.contains($0) } } ?? true) }
                .reduce(0.0) { sum, word in
                    let end = pow(alphabet, -Double(word.count))
                    // Начало TRON-адреса — не случайные символы (всегда «T» и узкий
                    // выбор второго), поэтому для него — точная доля.
                    let start = net == "trx" ? Self.tronPrefixProbability(word, caseSensitive: true) : end
                    return sum + start + end
                }
            worst = max(worst, probability)
        }
        guard worst > 0 else { return nil }
        let rarity = 1 / worst
        guard rarity.isFinite, rarity < Double(UInt64.max) else { return nil }
        return UInt64(rarity)
    }

    /// Оценка «1 из N» для своего паттерна на самой "щедрой" (частой) из
    /// выбранных сетей — то есть худший/самый частый случай, чтобы
    /// предупреждение было консервативным, а не оптимистичным.
    /// Может ли паттерн вообще встретиться в адресе сети: все символы есть в её
    /// алфавите (без учёта регистра — хоть в одном написании; у ETH с учётом
    /// регистра сравнивается checksum, где есть и A-F), а начало TRON — с T.
    func patternPossible(_ pattern: String, mode: CustomPatternMode, network: String, caseSensitive: Bool) -> Bool {
        guard var chars = Self.alphabetChars[network] else { return true }
        if network == "eth" { chars.formUnion("ABCDEF") }
        let ok = pattern.allSatisfy { c in
            chars.contains(c) || (!caseSensitive && chars.contains { $0.lowercased() == c.lowercased() })
        }
        if network == "trx", mode == .prefix {
            return ok && Self.tronPrefixProbability(pattern, caseSensitive: caseSensitive) > 0
        }
        return ok
    }

    // Все адреса TRON — base58 от 0x41 ++ 20 байт ++ checksum, то есть лежат между
    // этими двумя строками. Поэтому второй символ бывает только 9, A–H, J–N, P–Z,
    // а «T1…» или «Ta…» не встречаются вовсе.
    private static let tronMin = "T9yD14Nj9j7xAB4dbGeiX9h8unkKDDv9ZR"
    private static let tronMax = "TZJozAg1ruapycCicgz31GxvYJ1FvTVysk"
    private static let base58Order = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

    private static func base58Value(_ s: String) -> Double {
        s.reduce(0.0) { $0 * 58 + Double(base58Order.firstIndex(of: $1) ?? 0) }
    }

    /// Доля адресов TRON, начинающихся с prefix: пересечение диапазона строк
    /// prefix111…/prefixzzz… с реальным диапазоном адресов. Без учёта регистра —
    /// сумма по всем написаниям (их немного: у base58 нет 0, O, I, l).
    static func tronPrefixProbability(_ prefix: String, caseSensitive: Bool) -> Double {
        guard prefix.count <= 34 else { return 0 }
        var variants = [""]
        for c in prefix {
            let options = caseSensitive
                ? [c]
                : Array(Set([Character(c.lowercased()), Character(c.uppercased())]))
            variants = variants.flatMap { v in options.filter { base58Order.contains($0) }.map { v + String($0) } }
            if variants.count > 4096 { return 0 }
        }
        let fill = 34 - prefix.count
        let ones = String(repeating: "1", count: fill), zs = String(repeating: "z", count: fill)
        // Строки base58 одной длины сравниваются как числа (алфавит идёт в порядке
        // ASCII). Ширину считаем по хвосту после префикса: разность 34-значных
        // чисел в Double теряет всю точность уже на префиксе из десятка символов.
        let width = variants.reduce(0.0) { sum, v in
            let low = v + ones, high = v + zs
            guard high >= tronMin, low <= tronMax else { return sum }
            let tail = { (s: String) in base58Value(String(s.dropFirst(v.count))) }
            let lo = low >= tronMin ? base58Value(ones) : tail(tronMin)
            let hi = high <= tronMax ? base58Value(zs) : tail(tronMax)
            return sum + max(0, hi - lo)
        }
        return width / (base58Value(String(tronMax.dropFirst())) - base58Value(String(tronMin.dropFirst())))
    }

    func customPatternRarity(pattern: String, mode: CustomPatternMode, networks: Set<String>, caseSensitive: Bool = false) -> UInt64? {
        guard !pattern.isEmpty else { return nil }
        let len = Double(pattern.count)
        var worst: Double?
        for net in networks where patternPossible(pattern, mode: mode, network: net, caseSensitive: caseSensitive) {
            let alphabet = Double(alphabetSizes[net] ?? 58)
            let body = Double(bodyLengths[net] ?? 40)
            var probability: Double
            switch mode {
            case .prefix where net == "trx":
                probability = Self.tronPrefixProbability(pattern, caseSensitive: caseSensitive)
            case .prefix, .suffix:
                probability = pow(alphabet, -len)
            case .contains:
                probability = min(1, body * pow(alphabet, -len))
            }
            // На ETH сырой адрес без регистра — совпадение по регистру
            // (checksum) для каждой hex-буквы (a-f) добавляет независимый
            // множитель ~1/2. У base58/64-сетей регистр уже часть алфавита,
            // дополнительной поправки не нужно.
            if caseSensitive, net == "eth" {
                let letterCount = Double(pattern.filter { $0.isLetter }.count)
                probability *= pow(0.5, letterCount)
            }
            worst = worst.map { max($0, probability) } ?? probability
        }
        guard let worst, worst > 0 else { return nil }
        let rarity = 1 / worst
        guard rarity.isFinite, rarity < Double(UInt64.max) else { return nil }
        return UInt64(rarity)
    }
}
