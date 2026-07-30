import Foundation
import Observation

struct SpeedSample: Identifiable {
    let id = UUID()
    let elapsed: Double
    let speed: Double
}

enum CustomPatternMode: String, CaseIterable, Identifiable {
    case prefix, suffix, contains

    var id: String { rawValue }

    func label(_ lang: AppLanguage) -> String {
        switch self {
        case .prefix: return L.modePrefix.s(lang)
        case .suffix: return L.modeSuffix.s(lang)
        case .contains: return L.modeContains.s(lang)
        }
    }
}

@MainActor
@Observable
final class SessionViewModel {
    enum Phase: Equatable {
        case idle
        case running
        case stopping
    }

    /// Сентинел-ключ пресета для пользовательского паттерна — держим его в
    /// UI-состоянии; бэкенду он не передаётся как обычный preset key, вместо
    /// этого используется отдельный флаг --custom (см. start()).
    static let customPresetKey = "_custom"
    /// Верхний предел живого списка находок в интерфейсе (не в results/ —
    /// туда бэкенд пишет их всё равно, это только про рендеринг в UI).
    static let maxDisplayedFinds = 150

    let catalog: AppCatalog
    let maxWorkerCount: Int = max(1, ProcessInfo.processInfo.activeProcessorCount)

    var language: AppLanguage = .ru {
        didSet {
            guard language != oldValue else { return }
            saveSettings()
            // Описания пресетов (rarity, "Слово из списка" и т.п.) приходят из
            // bridge.py, а не хранятся в Swift — при смене языка нужно заново
            // спросить их у Python, иначе список условий останется на старом
            // языке до следующего перезапуска приложения.
            Task { await catalog.load(lang: language) }
        }
    }

    func t(_ key: L) -> String { key.s(language) }

    var phase: Phase = .idle
    var selectedNetworks: Set<String> = ["eth"]
    var selectedPreset: String = "all"
    var fakeMode: Bool = false
    var workerCount: Int

    var customPatternText: String = ""
    var customPatternMode: CustomPatternMode = .prefix
    var customPatternCaseSensitive: Bool = false

    /// Слова, которые реально участвуют в поиске условия "word" — объединение
    /// дефолтных (из patterns.py) и своих (customWords), минус снятые галочки.
    /// Список дефолтов сам по себе не хранится тут — он приходит из catalog.
    var selectedWords: Set<String> = []
    /// Слова, добавленные пользователем поверх дефолтного набора.
    var customWords: [String] = []

    var activeWords: [String] { Array(selectedWords) }

    /// Один раз, когда дефолтные слова только пришли из Python (и нет ранее
    /// сохранённого выбора), включаем их все — разумное стартовое состояние.
    func initializeWordsIfNeeded() {
        guard selectedWords.isEmpty, customWords.isEmpty, !catalog.defaultWords.isEmpty else { return }
        selectedWords = Set(catalog.defaultWords)
    }

    func addCustomWord(_ raw: String) {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !word.isEmpty, !customWords.contains(word), !catalog.defaultWords.contains(word) else { return }
        customWords.append(word)
        selectedWords.insert(word)
        saveSettings()
    }

    func removeCustomWord(_ word: String) {
        customWords.removeAll { $0 == word }
        selectedWords.remove(word)
        saveSettings()
    }

    func toggleWord(_ word: String) {
        if selectedWords.contains(word) {
            selectedWords.remove(word)
        } else {
            selectedWords.insert(word)
        }
        saveSettings()
    }

    /// Средняя скорость последнего прогона (только если он шёл ≥10 сек —
    /// короче считать ненадёжно) — используется для оценки времени
    /// нахождения ("1 : N" → "≈ столько-то времени"), сохраняется между
    /// запусками приложения.
    var lastMeasuredSpeed: Double?
    var speedEstimateAuto: Bool = true
    var manualSpeedText: String = ""

    var assumedSpeed: Double? {
        if speedEstimateAuto, let last = lastMeasuredSpeed, last > 0 { return last }
        let cleaned = manualSpeedText.filter { $0.isNumber || $0 == "." }
        guard let value = Double(cleaned), value > 0 else { return nil }
        return value
    }

    func etaSeconds(forRarity rarity: UInt64) -> Double? {
        guard let speed = assumedSpeed, speed > 0 else { return nil }
        return Double(rarity) / speed
    }

    var started: StartedEvent?
    var stats: StatsEvent?
    /// Экспоненциально сглаженное значение скорости для отображения — сырые
    /// показания приходят рывками (особенно в GPU-режиме, где keyhunt сам
    /// обновляет свой счётчик пачками раз в несколько секунд), поэтому UI
    /// показывает не «сырое» число, а сглаженное.
    var displaySpeed: Double = 0
    var speedHistory: [SpeedSample] = []
    var foundItems: [FoundEvent] = []
    /// Балансы ETH-находок по seq — приходят отдельным асинхронным событием
    /// (RPC-запрос не блокирует основной поиск), карточка сама подставляет
    /// значение, когда оно появляется здесь.
    var balancesBySeq: [Int: [String: Double]] = [:]
    var lastStopped: StoppedEvent?
    var lastError: String?

    /// Самый большой разрыв (по числу проверенных адресов) между двумя
    /// подряд находками за сессию — неформальный "рекорд редкости", просто
    /// забавная метрика, не влияет ни на что кроме бейджа в шапке.
    var rarestGap: UInt64?
    private var totalFoundCount = 0
    private var lastFoundTotalChecked: UInt64 = 0
    /// Инкрементируется на каждую находку — используется как seed для
    /// частиц (ParticleBurst), чтобы у каждой вспышки был свой узор.
    private(set) var burstSeed = 0

    private let bridge = PythonBridge()
    private var consumeTask: Task<Void, Never>?

    init(catalog: AppCatalog) {
        self.catalog = catalog
        self.workerCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
        loadSettings()
    }

    /// Оценка редкости прямо во время поиска (не только после Stop) —
    /// считается на лету из уже пришедшей статистики/находок.
    var liveRarity: UInt64? {
        guard phase == .running, let total = stats?.totalChecked, !foundItems.isEmpty else { return nil }
        return total / UInt64(foundItems.count)
    }

    var isRunning: Bool { phase != .idle }

    var orderedNetworks: [String] { catalog.networkOrder.filter { selectedNetworks.contains($0) } }

    var availablePresets: [PresetItem] { catalog.presetOptions(for: selectedNetworks) }

    var isCustomPreset: Bool { selectedPreset == Self.customPresetKey }

    private var trimmedCustomPattern: String {
        customPatternText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canStart: Bool {
        guard !selectedNetworks.isEmpty else { return false }
        if isCustomPreset { return !trimmedCustomPattern.isEmpty }
        if selectedPreset == "word" { return !selectedWords.isEmpty }
        return true
    }

    func toggleNetwork(_ key: String) {
        guard phase == .idle else { return }
        if selectedNetworks.contains(key) {
            selectedNetworks.remove(key)
        } else {
            selectedNetworks.insert(key)
        }
        if !isCustomPreset && !availablePresets.contains(where: { $0.key == selectedPreset }) {
            selectedPreset = availablePresets.first?.key ?? "all"
        }
    }

    private static let settingsKey = "VanityForge.lastSettings"

    private struct PersistedSettings: Codable {
        var networks: [String]
        var preset: String
        var workerCount: Int
        var customPatternText: String
        var customPatternMode: String
        var customPatternCaseSensitive: Bool?
        var lastMeasuredSpeed: Double?
        var speedEstimateAuto: Bool?
        var manualSpeedText: String?
        var language: String?
        var selectedWords: [String]?
        var customWords: [String]?
    }

    /// Настройки запоминаются между запусками приложения — чтобы не
    /// перевыбирать сети/условие/число процессов каждый раз заново.
    private func saveSettings() {
        let settings = PersistedSettings(
            networks: Array(selectedNetworks),
            preset: selectedPreset,
            workerCount: workerCount,
            customPatternText: customPatternText,
            customPatternMode: customPatternMode.rawValue,
            customPatternCaseSensitive: customPatternCaseSensitive,
            lastMeasuredSpeed: lastMeasuredSpeed,
            speedEstimateAuto: speedEstimateAuto,
            manualSpeedText: manualSpeedText,
            language: language.rawValue,
            selectedWords: Array(selectedWords),
            customWords: customWords
        )
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.settingsKey)
    }

    private func loadSettings() {
        guard let data = UserDefaults.standard.data(forKey: Self.settingsKey),
              let settings = try? JSONDecoder().decode(PersistedSettings.self, from: data) else { return }
        if !settings.networks.isEmpty { selectedNetworks = Set(settings.networks) }
        if !settings.preset.isEmpty { selectedPreset = settings.preset }
        if settings.workerCount > 0 { workerCount = min(settings.workerCount, maxWorkerCount) }
        customPatternText = settings.customPatternText
        if let mode = CustomPatternMode(rawValue: settings.customPatternMode) { customPatternMode = mode }
        customPatternCaseSensitive = settings.customPatternCaseSensitive ?? false
        lastMeasuredSpeed = settings.lastMeasuredSpeed
        speedEstimateAuto = settings.speedEstimateAuto ?? true
        manualSpeedText = settings.manualSpeedText ?? ""
        if let lang = settings.language.flatMap(AppLanguage.init(rawValue:)) { language = lang }
        if let words = settings.selectedWords { selectedWords = Set(words) }
        customWords = settings.customWords ?? []
    }

    func start() {
        guard phase == .idle, canStart else { return }
        saveSettings()
        foundItems = []
        stats = nil
        displaySpeed = 0
        speedHistory = []
        balancesBySeq = [:]
        started = nil
        lastStopped = nil
        lastError = nil
        rarestGap = nil
        totalFoundCount = 0
        lastFoundTotalChecked = 0
        phase = .running

        let networks = orderedNetworks
        let fake = fakeMode ? 0.8 : nil
        let customPattern: (text: String, mode: CustomPatternMode, caseSensitive: Bool)? =
            isCustomPreset ? (trimmedCustomPattern, customPatternMode, customPatternCaseSensitive) : nil
        let preset = isCustomPreset ? "all" : selectedPreset
        let words = selectedPreset == "word" ? activeWords : nil
        let stream = bridge.start(
            networks: networks, preset: preset, fakeFoundInterval: fake,
            workerCount: workerCount, customPattern: customPattern, language: language, words: words
        )

        consumeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in stream {
                self.handle(event)
            }
            self.phase = .idle
        }
    }

    func stop() {
        guard phase == .running else { return }
        phase = .stopping
        bridge.stop()
    }

    private func handle(_ event: BridgeEvent) {
        switch event {
        case .started(let e):
            started = e
        case .stats(let e):
            stats = e
            let smoothing = 0.35
            displaySpeed = displaySpeed == 0 ? Double(e.speed) : (smoothing * Double(e.speed) + (1 - smoothing) * displaySpeed)
            speedHistory.append(SpeedSample(elapsed: e.elapsedSeconds, speed: displaySpeed))
            if speedHistory.count > 180 { speedHistory.removeFirst(speedHistory.count - 180) }
        case .found(let e):
            totalFoundCount += 1
            burstSeed += 1
            if let total = stats?.totalChecked, total >= lastFoundTotalChecked {
                let gap = total - lastFoundTotalChecked
                if gap > 0, (rarestGap == nil || gap > rarestGap!) { rarestGap = gap }
                lastFoundTotalChecked = total
            }
            // Жёсткий потолок на размер списка: при слишком "широком" паттерне
            // (например короткий префикс) находки могут сыпаться тысячами в
            // секунду — без ограничения список и анимации вставки заваливали
            // весь UI. Полная история всё равно остаётся на диске (results/).
            foundItems.insert(e, at: 0)
            if foundItems.count > Self.maxDisplayedFinds {
                let removed = foundItems.suffix(from: Self.maxDisplayedFinds)
                for old in removed { balancesBySeq.removeValue(forKey: old.seq) }
                foundItems.removeLast(foundItems.count - Self.maxDisplayedFinds)
            }
        case .stopped(let e):
            lastStopped = e
            phase = .idle
            // Короткие прогоны (<10с) слишком шумные для оценки скорости —
            // не перезаписываем ими предыдущее, более надёжное измерение.
            if e.elapsedSeconds >= 10, e.totalChecked > 0 {
                lastMeasuredSpeed = Double(e.totalChecked) / e.elapsedSeconds
                saveSettings()
            }
        case .error(let e):
            lastError = e.message
            if e.fatal { phase = .idle }
        case .presets:
            break
        case .balance(let e):
            if let balances = e.balances {
                balancesBySeq[e.seq] = balances
            }
        }
    }
}
