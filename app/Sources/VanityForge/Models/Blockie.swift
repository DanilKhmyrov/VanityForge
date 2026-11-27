import SwiftUI

/// Аватарка blockies — квадратная иконка адреса в Etherscan и MetaMask
/// (ethereum/blockies). Выводится из адреса в нижнем регистре: сид — строка
/// «0x…», четыре 32-битных слова h = h·31 + символ по кругу, затем xorshift128.
/// Сдвиги в нём знаковые, старший бит результата всегда 0, поэтому rand() =
/// u / 2^31 лежит в [0, 1). Формулы — как в JS (python/avatar.py сверен с
/// оригиналом); подбор по аватарке идёт на видеокарте (metalvanity-evm).
struct Blockie: Equatable {
    struct HSL: Equatable {
        let hue: Double
        let saturation: Double
        let lightness: Double

        /// CSS hsl() → RGB.
        var color: Color {
            let s = saturation / 100, l = lightness / 100
            let c = (1 - abs(2 * l - 1)) * s
            let h = hue / 60
            let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
            let (r, g, b): (Double, Double, Double)
            switch h {
            case 0..<1: (r, g, b) = (c, x, 0)
            case 1..<2: (r, g, b) = (x, c, 0)
            case 2..<3: (r, g, b) = (0, c, x)
            case 3..<4: (r, g, b) = (0, x, c)
            case 4..<5: (r, g, b) = (x, 0, c)
            default: (r, g, b) = (c, 0, x)
            }
            let m = l - c / 2
            return Color(red: r + m, green: g + m, blue: b + m)
        }
    }

    let color: HSL
    let background: HSL
    let spot: HSL
    /// 64 клетки 8×8 построчно: 0 фон, 1 цвет, 2 пятна.
    let cells: [Int]

    init(address: String) {
        var s: [UInt32] = [0, 0, 0, 0]
        for (i, scalar) in address.lowercased().unicodeScalars.enumerated() {
            s[i % 4] = s[i % 4] &* 31 &+ scalar.value
        }
        func rand() -> Double {
            let t = s[0] ^ (s[0] << 11)
            s[0] = s[1]; s[1] = s[2]; s[2] = s[3]
            let s3 = Int32(bitPattern: s[3]), ti = Int32(bitPattern: t)
            s[3] = UInt32(bitPattern: s3 ^ (s3 >> 19) ^ ti ^ (ti >> 8))
            return Double(s[3]) / 2_147_483_648
        }
        func makeColor() -> HSL {
            let hue = floor(rand() * 360).truncatingRemainder(dividingBy: 360)
            let saturation = min(100, rand() * 60 + 40)
            let lightness = min(100, (rand() + rand() + rand() + rand()) * 25)
            return HSL(hue: hue, saturation: saturation, lightness: lightness)
        }
        color = makeColor()
        background = makeColor()
        spot = makeColor()
        var cells: [Int] = []
        for _ in 0..<8 {
            let row = (0..<4).map { _ in min(2, Int(floor(rand() * 2.3))) }
            cells += row + row.reversed()
        }
        self.cells = cells
    }

    func fill(_ cell: Int) -> Color {
        switch cell {
        case 0: return background.color
        case 1: return color.color
        default: return spot.color
        }
    }
}

/// Иконка 8×8 — как её рисует браузер.
struct BlockieView: View {
    let address: String
    var size: CGFloat = 24
    var cornerRadius: CGFloat? = nil

    var body: some View {
        let blockie = Blockie(address: address)
        Canvas { context, canvasSize in
            let cell = canvasSize.width / 8
            context.fill(Path(CGRect(origin: .zero, size: canvasSize)), with: .color(blockie.background.color))
            for (i, value) in blockie.cells.enumerated() where value != 0 {
                let rect = CGRect(x: CGFloat(i % 8) * cell, y: CGFloat(i / 8) * cell, width: cell + 0.5, height: cell + 0.5)
                context.fill(Path(rect), with: .color(blockie.fill(value)))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius ?? size * 0.18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius ?? size * 0.18, style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
    }
}

// MARK: - Цель поиска по аватарке

enum AvatarCell: Int, Codable, CaseIterable {
    case background = 0, color = 1, spot = 2, any = 3

    var code: Character {
        switch self {
        case .background: return "b"
        case .color: return "c"
        case .spot: return "s"
        case .any: return "."
        }
    }

    init?(code: Character) {
        guard let cell = AvatarCell.allCases.first(where: { $0.code == code }) else { return nil }
        self = cell
    }

    /// Порядок при щелчке по клетке: любая → фон → цвет → пятна → любая.
    var next: AvatarCell {
        switch self {
        case .any: return .background
        case .background: return .color
        case .color: return .spot
        case .spot: return .any
        }
    }

    /// Вероятность клетки: floor(rand·2.3), rand ∈ [0, 1).
    var probability: Double {
        switch self {
        case .background, .color: return 10.0 / 23
        case .spot: return 3.0 / 23
        case .any: return 1
        }
    }
}

/// Цвет как условие: диапазон оттенка (по кругу) и яркости.
enum AvatarSwatch: String, Codable, CaseIterable, Identifiable {
    case any, red, orange, yellow, green, cyan, blue, purple, pink, light, dark
    var id: String { rawValue }

    /// Оттенок от, до (градусы, через 0° — если от > до), яркость от, до (%).
    var range: (hueLo: Int, hueHi: Int, lightLo: Int, lightHi: Int) {
        switch self {
        case .any: return (0, 359, 0, 200)
        case .red: return (345, 14, 25, 75)
        case .orange: return (15, 44, 25, 75)
        case .yellow: return (45, 69, 25, 75)
        case .green: return (70, 164, 25, 75)
        case .cyan: return (165, 199, 25, 75)
        case .blue: return (200, 254, 25, 75)
        case .purple: return (255, 289, 25, 75)
        case .pink: return (290, 344, 25, 75)
        case .light: return (0, 359, 70, 200)
        case .dark: return (0, 359, 0, 30)
        }
    }

    var preview: Color {
        switch self {
        case .any: return .clear
        case .light: return Color(white: 0.85)
        case .dark: return Color(white: 0.16)
        default:
            let r = range
            let span = r.hueLo <= r.hueHi ? r.hueHi - r.hueLo : r.hueHi + 360 - r.hueLo
            let mid = Double((r.hueLo + span / 2) % 360)
            return Blockie.HSL(hue: mid, saturation: 75, lightness: 50).color
        }
    }

    var label: L {
        switch self {
        case .any: return .swatchAny
        case .red: return .swatchRed
        case .orange: return .swatchOrange
        case .yellow: return .swatchYellow
        case .green: return .swatchGreen
        case .cyan: return .swatchCyan
        case .blue: return .swatchBlue
        case .purple: return .swatchPurple
        case .pink: return .swatchPink
        case .light: return .swatchLight
        case .dark: return .swatchDark
        }
    }

    var specValue: String {
        let r = range
        return "\(r.hueLo)-\(r.hueHi)/\(r.lightLo)-\(r.lightHi)"
    }

    /// Доля адресов с таким цветом: оттенок равномерен по 0..359, яркость —
    /// 25·(сумма четырёх U[0,1)), распределение Ирвина — Холла.
    var probability: Double {
        guard self != .any else { return 1 }
        let r = range
        let hues = r.hueLo <= r.hueHi ? r.hueHi - r.hueLo + 1 : r.hueHi + 361 - r.hueLo
        let light = Self.irwinHall4(Double(min(r.lightHi, 100)) / 25) - Self.irwinHall4(Double(r.lightLo) / 25)
        return Double(hues) / 360 * light
    }

    /// P(U1 + U2 + U3 + U4 ≤ t).
    static func irwinHall4(_ t: Double) -> Double {
        guard t > 0 else { return 0 }
        guard t < 4 else { return 1 }
        var sum = 0.0
        for k in 0...Int(floor(t)) {
            let sign: Double = k % 2 == 0 ? 1 : -1
            let binom = [1.0, 4, 6, 4, 1][k]
            sum += sign * binom * pow(t - Double(k), 4)
        }
        return sum / 24
    }
}

struct AvatarTarget: Codable, Equatable {
    /// Левая половина 8×8 построчно, 8 строк по 4 (правая — зеркало).
    var cells: [AvatarCell]
    var misses: Int
    var color: AvatarSwatch
    var background: AvatarSwatch
    var spot: AvatarSwatch

    static let cellCount = 32
    static let maxMisses = 8

    static let blank = AvatarTarget(cells: Array(repeating: .any, count: cellCount), misses: 0,
                                    color: .any, background: .any, spot: .any)

    init(cells: [AvatarCell], misses: Int, color: AvatarSwatch, background: AvatarSwatch, spot: AvatarSwatch) {
        self.cells = cells
        self.misses = misses
        self.color = color
        self.background = background
        self.spot = spot
    }

    /// Из 8 строк по 4 символа «. b c s».
    init(rows: [String], misses: Int = 0, color: AvatarSwatch = .any, background: AvatarSwatch = .any) {
        let cells = rows.joined().compactMap(AvatarCell.init(code:))
        self.init(cells: cells.count == Self.cellCount ? cells : Self.blank.cells, misses: misses,
                  color: color, background: background, spot: .any)
    }

    func cell(row: Int, column: Int) -> AvatarCell {
        cells[row * 4 + (column < 4 ? column : 7 - column)]
    }

    mutating func cycle(row: Int, column: Int) {
        let i = row * 4 + (column < 4 ? column : 7 - column)
        cells[i] = cells[i].next
    }

    var constrainedCells: Int { cells.filter { $0 != .any }.count }
    var hasColors: Bool { [color, background, spot].contains { $0 != .any } }
    var isEmpty: Bool { constrainedCells == 0 && !hasColors }

    /// Строка для bridge.py / metalvanity-evm (формат — в python/avatar.py).
    var spec: String {
        var parts = ["cells=" + String(cells.map(\.code)), "miss=\(misses)"]
        for (name, swatch) in [("color", color), ("bg", background), ("spot", spot)] where swatch != .any {
            parts.append("\(name)=\(swatch.specValue)")
        }
        return parts.joined(separator: ";")
    }

    /// Вероятность совпадения: цвета × P(не больше misses несовпавших клеток).
    var probability: Double {
        var dist = [1.0]  // dist[k] — вероятность ровно k промахов среди уже учтённых клеток
        for cell in cells where cell != .any {
            let p = cell.probability
            var next = Array(repeating: 0.0, count: dist.count + 1)
            for (k, value) in dist.enumerated() {
                next[k] += value * p
                next[k + 1] += value * (1 - p)
            }
            dist = next
        }
        let cellsOK = dist.prefix(misses + 1).reduce(0, +)
        return cellsOK * color.probability * background.probability * spot.probability
    }

    var rarity: UInt64? {
        let p = probability
        guard p > 0, !isEmpty else { return nil }
        let n = 1 / p
        return n >= Double(UInt64.max) ? UInt64.max : UInt64(n.rounded())
    }
}

/// Готовые рисунки (левая половина, 8 строк по 4).
enum AvatarDrawing: String, CaseIterable, Identifiable {
    case smile, heart, frame, cross, plain, clear
    var id: String { rawValue }

    var rows: [String] {
        switch self {
        case .smile: return ["bbbb", "bbbb", "bbcb", "bbbb", "bcbb", "bbcc", "bbbb", "bbbb"]
        case .heart: return ["bccb", "cccc", "cccc", "cccc", "bccc", "bbcc", "bbbc", "bbbb"]
        case .frame: return ["cccc", "cbbb", "cbbb", "cbbb", "cbbb", "cbbb", "cbbb", "cccc"]
        case .cross: return ["bbbc", "bbbc", "bbbc", "cccc", "cccc", "bbbc", "bbbc", "bbbc"]
        case .plain: return Array(repeating: "bbbb", count: 8)
        case .clear: return Array(repeating: "....", count: 8)
        }
    }

    var label: L {
        switch self {
        case .smile: return .avatarDrawingSmile
        case .heart: return .avatarDrawingHeart
        case .frame: return .avatarDrawingFrame
        case .cross: return .avatarDrawingCross
        case .plain: return .avatarDrawingPlain
        case .clear: return .avatarDrawingClear
        }
    }
}
