import Foundation

enum Format {
    private static let grouped: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = " "
        f.usesGroupingSeparator = true
        return f
    }()

    static func count(_ value: Int) -> String {
        grouped.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func count(_ value: UInt64) -> String {
        grouped.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// Компактная форма для крупных чисел ("2.62 млрд" вместо "2 615 517 184") —
    /// длинные цифры иначе не помещаются в фиксированную ширину плашки и
    /// переносятся на вторую строку, ломая вёрстку.
    static func compact(_ value: Double, _ lang: AppLanguage = .ru) -> String {
        let v = abs(value)
        let sign = value < 0 ? "-" : ""
        switch v {
        case 0..<1000:
            return sign + String(Int(v.rounded()))
        case 1000..<1_000_000:
            return sign + String(format: "%.1f \(L.magThousand.s(lang))", v / 1_000)
        case 1_000_000..<1_000_000_000:
            return sign + String(format: "%.2f \(L.magMillion.s(lang))", v / 1_000_000)
        case 1_000_000_000..<1_000_000_000_000:
            return sign + String(format: "%.2f \(L.magBillion.s(lang))", v / 1_000_000_000)
        case 1_000_000_000_000..<1_000_000_000_000_000:
            return sign + String(format: "%.2f \(L.magTrillion.s(lang))", v / 1_000_000_000_000)
        default:
            return sign + String(format: "%.2f \(L.magQuadrillion.s(lang))", v / 1_000_000_000_000_000)
        }
    }

    static func compact(_ value: UInt64, _ lang: AppLanguage = .ru) -> String {
        compact(Double(value), lang)
    }

    /// Цвет-индикатор "насколько это разумно" — привязан к тому же порогу,
    /// что и защита от затопления в bridge.py (MAX_DETAILED_FINDS): если
    /// находок за сессию будет больше — UI честно предупреждает ДО старта.
    static func rarityIsDangerous(_ rarity: UInt64) -> Bool {
        rarity < 200_000
    }

    static func elapsed(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    /// Человекочитаемая оценка времени по числу секунд — от "меньше секунды"
    /// до "N млрд лет" (редкие паттерны на медленной скорости легко уходят
    /// за пределы возраста Вселенной, это тоже нужно уметь показать разумно).
    static func duration(seconds: Double, _ lang: AppLanguage = .ru) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let minute = 60.0, hour = 3600.0, day = 86400.0, year = 365.25 * day
        switch seconds {
        case 0..<1:
            return L.durSecShort.s(lang)
        case 1..<minute:
            return "\(Int(seconds)) \(L.durSec.s(lang))"
        case minute..<hour:
            return "\(Int(seconds / minute)) \(L.durMin.s(lang))"
        case hour..<day:
            return String(format: "%.1f \(L.durHour.s(lang))", seconds / hour)
        case day..<year:
            return String(format: "%.1f \(L.durDay.s(lang))", seconds / day)
        default:
            return "≈ \(compact(seconds / year, lang)) \(L.durYear.s(lang))"
        }
    }

    static func shortAddress(_ address: String, head: Int = 10, tail: Int = 8) -> String {
        guard address.count > head + tail + 3 else { return address }
        return "\(address.prefix(head))…\(address.suffix(tail))"
    }
}
