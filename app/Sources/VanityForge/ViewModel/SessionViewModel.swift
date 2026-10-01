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

    var phase: Phase = .idle {
        didSet {
            guard phase != oldValue else { return }
            if phase == .running {
                sleepGuard.begin(reason: "VanityForge: address search")
            } else if phase == .idle {
                sleepGuard.end()
            }
        }
    }
    private let sleepGuard = SleepGuard()
    private let notifier = FoundNotifier()
    /// Mac не заснёт, пока идёт поиск (см. SleepGuard).
    var keepsAwake: Bool { phase != .idle }
    var searchMode: SearchMode = .wallets {
        didSet { if searchMode != oldValue { saveSettings() } }
    }
    var selectedNetworks: Set<String> = ["eth"]
    var selectedPreset: String = "all"
    var fakeMode: Bool = false
    var workerCount: Int

    var customPatternText: String = ""
    var customPatternMode: CustomPatternMode = .prefix
    var customPatternCaseSensitive: Bool = false

    var splitKeyEnabled: Bool = false {
        didSet { if splitKeyEnabled != oldValue { saveSettings() } }
    }
    var splitKeyPublic: String = ""
    static let splitKeyNetworks: Set<String> = ["eth", "trx"]

    var splitKeyTrimmed: String { Create2Math.strip(splitKeyPublic) }
    var splitKeyValid: Bool {
        let body = splitKeyTrimmed
        guard body.allSatisfy(\.isHexDigit) else { return false }
        return (body.count == 66 && (body.hasPrefix("02") || body.hasPrefix("03")))
            || (body.count == 130 && body.hasPrefix("04"))
    }
    var splitKeyNetworksOK: Bool { selectedNetworks.isSubset(of: Self.splitKeyNetworks) }

    var contractKind: ContractKind = .create2
    var create2Factory: Create2Factory = .immutable
    var create2CustomFactory: String = ""
    var create2InitCodeHash: String = ""
    var create2Caller: String = ""
    var create2Goal: Create2Goal = .leading
    var create2MinBytes: Int = 4
    var create2Prefix: String = ""
    var create2HookFlags: UInt16 = 0
    /// GPU (Metal) для EVM-кошельков и контрактов; выключается, если видеокарта нужна под другое.
    var useGPU: Bool = true
    /// Потолок нагрузки на видеокарту, % (паузы между пачками): меньше — тише и холоднее.
    var gpuLoad: Int = 100
    static let gpuLoadSteps = [25, 50, 75, 100]

    var create2FactoryAddress: String {
        create2Factory.address ?? create2CustomFactory.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var create2FactoryValid: Bool { Create2Math.isHex(create2FactoryAddress, bytes: 20) }
    var create2InitCodeHashValid: Bool { Create2Math.isHex(create2InitCodeHash, bytes: 32) }
    var create2CallerTrimmed: String { create2Caller.trimmingCharacters(in: .whitespacesAndNewlines) }
    var create2CallerValid: Bool { create2CallerTrimmed.isEmpty || Create2Math.isHex(create2CallerTrimmed, bytes: 20) }
    var create2PrefixValid: Bool {
        let body = Create2Math.strip(create2Prefix)
        return !body.isEmpty && body.count <= 40 && body.allSatisfy(\.isHexDigit)
    }

    var create2Rarity: UInt64? {
        Create2Math.rarity(goal: create2Goal, minBytes: create2MinBytes, prefix: create2Prefix)
    }

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
    /// Скорость кошельков на видеокарте — в сотни раз выше CPU, поэтому хранится
    /// отдельно: иначе оценка для условия, которое пойдёт на процессор, врала бы.
    var lastMeasuredGPUSpeed: Double?
    /// Перебор salt для CREATE2 в разы быстрее перебора ключей — его скорость
    /// меряется и хранится отдельно, иначе оценки времени врали бы в обе стороны.
    var lastMeasuredCreate2Speed: Double?
    var lastMeasuredCreate3Speed: Double?
    var speedEstimateAuto: Bool = true
    var manualSpeedText: String = ""

    var assumedSpeed: Double? {
        let last: Double?
        switch (searchMode, contractKind) {
        case (.contracts, .create2): last = lastMeasuredCreate2Speed
        case (.contracts, .create3): last = lastMeasuredCreate3Speed
        default: last = willUseGPU ? (lastMeasuredGPUSpeed ?? lastMeasuredSpeed) : lastMeasuredSpeed
        }
        if speedEstimateAuto, let last, last > 0 { return last }
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
    /// показания приходят рывками (движки отдают счётчик пачками), поэтому UI
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

    /// Пойдёт ли текущий поиск кошельков на видеокарту: GPU-движок знает EVM и TRON.
    var willUseGPU: Bool {
        useGPU && !fakeMode && !selectedNetworks.isEmpty && selectedNetworks.isSubset(of: ["eth", "trx"])
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// Свой паттерн может встретиться хотя бы в одной из выбранных сетей.
    var customPatternPossible: Bool {
        selectedNetworks.contains { net in
            catalog.patternPossible(trimmedCustomPattern, mode: customPatternMode, network: net,
                                    caseSensitive: customPatternCaseSensitive)
        }
    }

    /// Почему свой паттерн невозможен — конкретно: какие символы и в какой сети,
    /// и поможет ли снять «Учитывать регистр». nil — паттерн возможен.
    var customPatternIssue: String? {
        let pattern = trimmedCustomPattern
        guard !pattern.isEmpty, !customPatternPossible else { return nil }
        let net = catalog.networkOrder.first { selectedNetworks.contains($0) } ?? "eth"
        let name = catalog.networkNames[net] ?? net
        let bad = catalog.invalidCharacters(pattern, network: net, caseSensitive: customPatternCaseSensitive)
        var message: String
        if bad.isEmpty {
            message = t(.patternTronStart)
        } else {
            let list = bad.map { "«\($0)»" }.joined(separator: ", ")
            let alphabet: L = net == "eth" ? .alphabetHex : (net == "ton" ? .alphabetTon : .alphabetBase58)
            message = t(.patternBadChars)
                .replacingOccurrences(of: "{chars}", with: list)
                .replacingOccurrences(of: "{network}", with: name) + " " + t(alphabet)
        }
        if customPatternCaseSensitive, selectedNetworks.contains(where: {
            catalog.patternPossible(pattern, mode: customPatternMode, network: $0, caseSensitive: false)
        }) {
            message += " " + t(.patternTryIgnoreCase)
        }
        return message
    }

    /// Редкость текущего условия (1 к N) — для шанса находки и оценок времени.
    var targetRarity: UInt64? {
        if searchMode == .contracts { return create2Rarity }
        if isCustomPreset {
            return catalog.customPatternRarity(pattern: trimmedCustomPattern, mode: customPatternMode,
                                               networks: selectedNetworks, caseSensitive: customPatternCaseSensitive)
        }
        return availablePresets.first(where: { $0.key == selectedPreset }).flatMap(presetRarity)
    }

    /// Редкость пресета; для «Слово из списка» — по реально выбранным словам.
    func presetRarity(_ preset: PresetItem) -> UInt64? {
        if preset.key == "word" { return catalog.wordRarity(words: activeWords, networks: selectedNetworks) }
        return preset.rarity1In
    }

    /// Вероятность, что за уже проверенное число адресов нашлось хотя бы одно
    /// совпадение: 1 − e^(−проверено/N). Не «прогресс»: у перебора нет конца,
    /// 63% — это ровно среднее ожидание, дальше шанс растёт всё медленнее.
    var findChance: Double? {
        guard let rarity = targetRarity, rarity > 0, let checked = stats?.totalChecked else { return nil }
        return 1 - exp(-Double(checked) / Double(rarity))
    }

    /// Среднее время на одну находку при текущей скорости.
    var secondsPerFind: Double? {
        guard let rarity = targetRarity, displaySpeed > 0 else { return nil }
        return Double(rarity) / displaySpeed
    }

    /// Находки, для которых сейчас идёт запрос баланса, и те, где он не удался.
    var balanceLoading: Set<Int> = []
    var balanceFailed: Set<Int> = []

    func checkBalance(for event: FoundEvent) {
        guard !balanceLoading.contains(event.seq) else { return }
        balanceLoading.insert(event.seq)
        balanceFailed.remove(event.seq)
        let address = event.checksumAddress ?? event.address
        Task { @MainActor in
            let balances = await PythonBridge.fetchBalance(address: address)
            balanceLoading.remove(event.seq)
            if let balances { balancesBySeq[event.seq] = balances } else { balanceFailed.insert(event.seq) }
        }
    }

    /// Убирает карточки из ленты (файлы находок на диске не трогает).
    func clearFeed() {
        foundItems = []
        balancesBySeq = [:]
        balanceLoading = []
        balanceFailed = []
        DockBadge.set(nil)
    }

    var orderedNetworks: [String] { catalog.networkOrder.filter { selectedNetworks.contains($0) } }

    /// Ключ цвета для фона/кнопок: у режима контрактов свой акцент.
    var accentKey: String? { searchMode == .contracts ? contractKind.rawValue : orderedNetworks.first }

    var availablePresets: [PresetItem] { catalog.presetOptions(for: selectedNetworks) }

    var isCustomPreset: Bool { selectedPreset == Self.customPresetKey }

    private var trimmedCustomPattern: String {
        customPatternText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canStart: Bool {
        if searchMode == .contracts {
            guard create2CallerValid else { return false }
            if contractKind == .create2 { guard create2FactoryValid, create2InitCodeHashValid else { return false } }
            if create2Goal == .prefix { return create2PrefixValid }
            return true
        }
        guard !selectedNetworks.isEmpty else { return false }
        if splitKeyEnabled { guard splitKeyValid, splitKeyNetworksOK, !fakeMode else { return false } }
        if isCustomPreset { return !trimmedCustomPattern.isEmpty && customPatternPossible }
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
        var lastMeasuredGPUSpeed: Double?
        var speedEstimateAuto: Bool?
        var manualSpeedText: String?
        var language: String?
        var selectedWords: [String]?
        var customWords: [String]?
        var searchMode: String?
        var splitKeyEnabled: Bool?
        var splitKeyPublic: String?
        var contractKind: String?
        var create2Factory: String?
        var create2CustomFactory: String?
        var create2InitCodeHash: String?
        var create2Caller: String?
        var create2Goal: String?
        var create2MinBytes: Int?
        var create2Prefix: String?
        var create2HookFlags: UInt16?
        var useGPU: Bool?
        var gpuLoad: Int?
        var lastMeasuredCreate2Speed: Double?
        var lastMeasuredCreate3Speed: Double?
    }

    /// Настройки запоминаются между запусками приложения — чтобы не
    /// перевыбирать сети/условие/число процессов каждый раз заново.
    /// Пока идёт loadSettings(), didSet-ы (language, searchMode) не должны
    /// сохранять: иначе на диск уходят ещё не прочитанные поля по умолчанию
    /// и затирают настоящие значения (хеш, кошелёк, выбранные слова).
    private var isLoadingSettings = false

    private func saveSettings() {
        guard !isLoadingSettings else { return }
        let settings = PersistedSettings(
            networks: Array(selectedNetworks),
            preset: selectedPreset,
            workerCount: workerCount,
            customPatternText: customPatternText,
            customPatternMode: customPatternMode.rawValue,
            customPatternCaseSensitive: customPatternCaseSensitive,
            lastMeasuredSpeed: lastMeasuredSpeed,
            lastMeasuredGPUSpeed: lastMeasuredGPUSpeed,
            speedEstimateAuto: speedEstimateAuto,
            manualSpeedText: manualSpeedText,
            language: language.rawValue,
            selectedWords: Array(selectedWords),
            customWords: customWords,
            searchMode: searchMode.rawValue,
            splitKeyEnabled: splitKeyEnabled,
            splitKeyPublic: splitKeyPublic,
            contractKind: contractKind.rawValue,
            create2Factory: create2Factory.rawValue,
            create2CustomFactory: create2CustomFactory,
            create2InitCodeHash: create2InitCodeHash,
            create2Caller: create2Caller,
            create2Goal: create2Goal.rawValue,
            create2MinBytes: create2MinBytes,
            create2Prefix: create2Prefix,
            create2HookFlags: create2HookFlags,
            useGPU: useGPU,
            gpuLoad: gpuLoad,
            lastMeasuredCreate2Speed: lastMeasuredCreate2Speed,
            lastMeasuredCreate3Speed: lastMeasuredCreate3Speed
        )
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.settingsKey)
    }

    private func loadSettings() {
        guard let data = UserDefaults.standard.data(forKey: Self.settingsKey),
              let settings = try? JSONDecoder().decode(PersistedSettings.self, from: data) else { return }
        isLoadingSettings = true
        defer { isLoadingSettings = false }
        if !settings.networks.isEmpty { selectedNetworks = Set(settings.networks) }
        if !settings.preset.isEmpty { selectedPreset = settings.preset }
        if settings.workerCount > 0 { workerCount = min(settings.workerCount, maxWorkerCount) }
        customPatternText = settings.customPatternText
        if let mode = CustomPatternMode(rawValue: settings.customPatternMode) { customPatternMode = mode }
        customPatternCaseSensitive = settings.customPatternCaseSensitive ?? false
        lastMeasuredSpeed = settings.lastMeasuredSpeed
        lastMeasuredGPUSpeed = settings.lastMeasuredGPUSpeed
        // До 1.2.2 скорость GPU-прогонов писалась в общую ячейку; CPU здесь
        // не выдаёт и 10 млн/с, так что такое значение — точно от видеокарты.
        if lastMeasuredGPUSpeed == nil, let speed = lastMeasuredSpeed, speed > 10_000_000 {
            lastMeasuredGPUSpeed = speed
            lastMeasuredSpeed = nil
        }
        speedEstimateAuto = settings.speedEstimateAuto ?? true
        manualSpeedText = settings.manualSpeedText ?? ""
        if let lang = settings.language.flatMap(AppLanguage.init(rawValue:)) { language = lang }
        if let words = settings.selectedWords { selectedWords = Set(words) }
        customWords = settings.customWords ?? []
        if let mode = settings.searchMode.flatMap(SearchMode.init(rawValue:)) { searchMode = mode }
        splitKeyEnabled = settings.splitKeyEnabled ?? false
        splitKeyPublic = settings.splitKeyPublic ?? ""
        if let kind = settings.contractKind.flatMap(ContractKind.init(rawValue:)) { contractKind = kind }
        if let factory = settings.create2Factory.flatMap(Create2Factory.init(rawValue:)) { create2Factory = factory }
        create2CustomFactory = settings.create2CustomFactory ?? ""
        create2InitCodeHash = settings.create2InitCodeHash ?? ""
        create2Caller = settings.create2Caller ?? ""
        if let goal = settings.create2Goal.flatMap(Create2Goal.init(rawValue:)) { create2Goal = goal }
        if let minBytes = settings.create2MinBytes { create2MinBytes = min(max(minBytes, 1), Create2Math.addressBytes) }
        create2Prefix = settings.create2Prefix ?? ""
        create2HookFlags = settings.create2HookFlags ?? 0
        useGPU = settings.useGPU ?? true
        if let load = settings.gpuLoad, Self.gpuLoadSteps.contains(load) { gpuLoad = load }
        lastMeasuredCreate2Speed = settings.lastMeasuredCreate2Speed
        lastMeasuredCreate3Speed = settings.lastMeasuredCreate3Speed
    }

    func start() {
        guard phase == .idle, canStart else { return }
        saveSettings()
        foundItems = []
        stats = nil
        displaySpeed = 0
        speedHistory = []
        balancesBySeq = [:]
        balanceLoading = []
        balanceFailed = []
        started = nil
        lastStopped = nil
        lastError = nil
        rarestGap = nil
        totalFoundCount = 0
        lastFoundTotalChecked = 0
        DockBadge.set(nil)
        notifier.prepare()
        phase = .running

        if searchMode == .contracts {
            let stream = bridge.startCreate2(
                kind: contractKind, factory: create2FactoryAddress, initCodeHash: create2InitCodeHash.trimmingCharacters(in: .whitespacesAndNewlines),
                caller: create2CallerTrimmed, goal: create2Goal, minBytes: create2MinBytes,
                prefix: Create2Math.strip(create2Prefix), hookFlags: create2HookFlags, useGPU: useGPU, gpuLoad: gpuLoad,
                workerCount: workerCount, language: language
            )
            consume(stream)
            return
        }

        let networks = orderedNetworks
        let fake = fakeMode ? 0.8 : nil
        let customPattern: (text: String, mode: CustomPatternMode, caseSensitive: Bool)? =
            isCustomPreset ? (trimmedCustomPattern, customPatternMode, customPatternCaseSensitive) : nil
        let preset = isCustomPreset ? "all" : selectedPreset
        let words = selectedPreset == "word" ? activeWords : nil
        let stream = bridge.start(
            networks: networks, preset: preset, fakeFoundInterval: fake,
            workerCount: workerCount, customPattern: customPattern, language: language, words: words,
            splitKey: splitKeyEnabled ? splitKeyTrimmed : nil, useGPU: useGPU, gpuLoad: gpuLoad
        )
        consume(stream)
    }

    func saveCreate2Settings() { saveSettings() }

    private func consume(_ stream: AsyncStream<BridgeEvent>) {
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
            DockBadge.set(totalFoundCount)
            notifier.found(e, lang: language)
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
                let speed = Double(e.totalChecked) / e.elapsedSeconds
                if let net = started?.networks.first, let kind = ContractKind(rawValue: net) {
                    if kind == .create3 { lastMeasuredCreate3Speed = speed } else { lastMeasuredCreate2Speed = speed }
                } else if started?.gpu.tool == "metal" {
                    lastMeasuredGPUSpeed = speed
                } else {
                    lastMeasuredSpeed = speed
                }
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
