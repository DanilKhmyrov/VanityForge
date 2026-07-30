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

    /// Оценка «1 из N» для своего паттерна на самой "щедрой" (частой) из
    /// выбранных сетей — то есть худший/самый частый случай, чтобы
    /// предупреждение было консервативным, а не оптимистичным.
    func customPatternRarity(pattern: String, mode: CustomPatternMode, networks: Set<String>, caseSensitive: Bool = false) -> UInt64? {
        guard !pattern.isEmpty else { return nil }
        let len = Double(pattern.count)
        var worst: Double?
        for net in networks {
            let alphabet = Double(alphabetSizes[net] ?? 58)
            let body = Double(bodyLengths[net] ?? 40)
            var probability: Double
            switch mode {
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
