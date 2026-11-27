import Foundation

/// Jazzicon — круглая иконка адреса в MetaMask (danfinlay/jazzicon). Сид —
/// первые 8 hex-символов адреса (jsNumberForAddress: parseInt(addr.slice(2, 10), 16)),
/// поэтому иконку можно выбрать заранее из галереи, а потом найти адрес с таким
/// началом: 2^32 попыток, на видеокарте — около минуты.
///
/// Алгоритм: MersenneTwister(seed); палитра из 10 цветов поворачивается по оттенку
/// на random()·30 − 15° (библиотека color 0.11: HSL и RGB округляются до целых);
/// фон и три квадрата во весь размер берут цвета из палитры без повторов, квадраты
/// сдвинуты и повёрнуты; всё обрезано кругом.
struct Jazzicon: Equatable {
    struct RGB: Equatable {
        let r: Int, g: Int, b: Int
        var hex: String { String(format: "#%02X%02X%02X", r, g, b) }
    }

    struct Shape: Equatable {
        /// Сдвиг в долях диаметра.
        let tx: Double
        let ty: Double
        /// Поворот вокруг центра, градусы (по часовой, как в SVG).
        let rotation: Double
        let color: RGB
    }

    let background: RGB
    let shapes: [Shape]

    static let palette = ["01888C", "FC7500", "034F5D", "F73F01", "FC1960", "C7144C", "F3C100", "1598F2", "2465E1", "F19E02"]

    /// Сид MetaMask для адреса: первые 8 hex-символов после 0x.
    static func seed(forAddress address: String) -> UInt32? {
        let body = address.hasPrefix("0x") || address.hasPrefix("0X") ? address.dropFirst(2) : Substring(address)
        return UInt32(body.prefix(8), radix: 16)
    }

    init?(address: String) {
        guard let seed = Self.seed(forAddress: address) else { return nil }
        self.init(seed: seed)
    }

    init(seed: UInt32) {
        var twister = MersenneTwister(seed: seed)
        let amount = twister.random() * 30 - 15
        var colors = Self.palette.map { Self.rotate(hex: $0, by: amount) }
        func pickColor() -> RGB {
            _ = twister.random()
            let index = Int(floor(Double(colors.count) * twister.random()))
            return colors.remove(at: index)
        }
        background = pickColor()
        var shapes: [Shape] = []
        let total = 3.0
        for i in 0..<3 {
            let firstRot = twister.random()
            let angle = Double.pi * 2 * firstRot
            let velocity = twister.random() / total + Double(i) / total
            let secondRot = twister.random()
            shapes.append(Shape(tx: cos(angle) * velocity, ty: sin(angle) * velocity,
                                rotation: firstRot * 360 + secondRot * 180, color: pickColor()))
        }
        self.shapes = shapes
    }

    // MARK: - color 0.11 / color-convert 1.3

    private static func jsRound(_ x: Double) -> Int { Int(floor(x + 0.5)) }

    private static func rotate(hex: String, by degrees: Double) -> RGB {
        let value = Int(hex, radix: 16)!
        let rgb = [Double((value >> 16) & 0xff), Double((value >> 8) & 0xff), Double(value & 0xff)]
        let hsl = rgbToHSL(rgb).enumerated().map { i, v in Double(jsRound(max(0, min([360.0, 100, 100][i], v)))) }
        var hue = (hsl[0] + degrees).truncatingRemainder(dividingBy: 360)
        if hue < 0 { hue += 360 }
        let h = Double(jsRound(max(0, min(360, hue))))
        let out = hslToRGB([h, hsl[1], hsl[2]]).map { jsRound(max(0, min(255, $0))) }
        return RGB(r: out[0], g: out[1], b: out[2])
    }

    private static func rgbToHSL(_ rgb: [Double]) -> [Double] {
        let r = rgb[0] / 255, g = rgb[1] / 255, b = rgb[2] / 255
        let lo = min(r, g, b), hi = max(r, g, b), delta = hi - lo
        var h: Double
        if hi == lo { h = 0 } else if r == hi { h = (g - b) / delta } else if g == hi { h = 2 + (b - r) / delta } else { h = 4 + (r - g) / delta }
        h = min(h * 60, 360)
        if h < 0 { h += 360 }
        let l = (lo + hi) / 2
        let s: Double = hi == lo ? 0 : (l <= 0.5 ? delta / (hi + lo) : delta / (2 - hi - lo))
        return [h, s * 100, l * 100]
    }

    private static func hslToRGB(_ hsl: [Double]) -> [Double] {
        let h = hsl[0] / 360, s = hsl[1] / 100, l = hsl[2] / 100
        if s == 0 { return [l * 255, l * 255, l * 255] }
        let t2 = l < 0.5 ? l * (1 + s) : l + s - l * s
        let t1 = 2 * l - t2
        return (0..<3).map { i in
            var t3 = h + 1.0 / 3 * -Double(i - 1)
            if t3 < 0 { t3 += 1 }
            if t3 > 1 { t3 -= 1 }
            let val: Double
            if 6 * t3 < 1 { val = t1 + (t2 - t1) * 6 * t3 } else if 2 * t3 < 1 { val = t2 } else if 3 * t3 < 2 { val = t1 + (t2 - t1) * (2.0 / 3 - t3) * 6 } else { val = t1 }
            return val * 255
        }
    }
}

/// MT19937, как в npm mersenne-twister 1.1.0 (init_genrand / genrand_int32).
struct MersenneTwister {
    private var mt = [UInt32](repeating: 0, count: 624)
    private var index = 624

    init(seed: UInt32) {
        mt[0] = seed
        for i in 1..<624 {
            let s = mt[i - 1] ^ (mt[i - 1] >> 30)
            mt[i] = 1_812_433_253 &* s &+ UInt32(i)
        }
    }

    mutating func next() -> UInt32 {
        if index >= 624 {
            for k in 0..<624 {
                let y = (mt[k] & 0x8000_0000) | (mt[(k + 1) % 624] & 0x7fff_ffff)
                mt[k] = mt[(k + 397) % 624] ^ (y >> 1) ^ (y & 1 == 0 ? 0 : 0x9908_b0df)
            }
            index = 0
        }
        var y = mt[index]
        index += 1
        y ^= y >> 11
        y ^= (y << 7) & 0x9d2c_5680
        y ^= (y << 15) & 0xefc6_0000
        y ^= y >> 18
        return y
    }

    mutating func random() -> Double { Double(next()) / 4_294_967_296 }
}
