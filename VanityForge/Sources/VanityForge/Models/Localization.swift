import Foundation

enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case ru, en
    var id: String { rawValue }
}

/// Централизованный каталог строк интерфейса — вместо `NSLocalizedString`/
/// String Catalog (`.xcstrings`), т.к. компиляция `.xcstrings` идёт через ту
/// же `actool`-зависимую машинерию сборки, которой на этой машине нет (см.
/// NetworkIcon.swift — та же причина, по которой иконки грузятся как сырой
/// SVG, а не через Assets.xcassets). Обычная таблица строк — единственный
/// вариант, не зависящий от полного Xcode при сборке через `swift build`.
enum L: String {
    // MARK: NetworkPresetPicker
    case appSubtitle
    case sectionNetworks
    case sectionCondition
    case workersTitle
    case workersSubtitle
    case demoModeTitle
    case demoModeSubtitle
    case customPatternPlaceholderShort
    case selectCondition
    case customPatternSelected
    case speedEstimateTitle
    case speedAuto
    case speedManual
    case unitAddrPerSec
    case noData
    case placeholderPrefix
    case placeholderSuffix
    case placeholderContains
    case caseSensitiveToggle
    case dangerousPatternPrefix
    case rarityApprox
    case etaLabel
    case alphabetHintHelp
    case allowedChars
    case startSearch
    case wordListDefaults
    case wordListCustom
    case wordListAddPlaceholder
    case wordListNoneSelected
    case stopSearch
    case stopping

    // MARK: StatsDashboardView
    case statSpeed
    case statChecked
    case statTime
    case statWorkers
    case unitAddresses
    case unitProcesses
    case accelerated
    case demoBadge
    case rarestFindHelp
    case avgRarity
    case statusStopped
    case statusReady
    case statusSearching

    // MARK: Formatting
    case durSecShort
    case durSec
    case durMin
    case durHour
    case durDay
    case durYear
    case magThousand
    case magMillion
    case magBillion
    case magTrillion
    case magQuadrillion

    // MARK: SystemMetricsView
    case systemHeader
    case memory
    case notAvailable

    // MARK: NetworkAlphabet
    case alphabetNoteEth
    case alphabetNoteSol
    case alphabetNoteTrx
    case alphabetNoteTon

    // MARK: SpeedChartView
    case speedChartHeader
    case speedChartEmpty

    // MARK: SessionViewModel (CustomPatternMode)
    case modePrefix
    case modeSuffix
    case modeContains

    // MARK: ContentView
    case tabSearch
    case tabHistory

    // MARK: HistoryView
    case historyTitle
    case historyEmpty

    // MARK: LiveFeedView
    case liveFeedRunning
    case liveFeedIdle

    // MARK: FoundCardView
    case revealInFinder
    case calculatingBalance
    case holdToRevealKey

    // MARK: PythonBridge
    case processLaunchFailed

    func s(_ lang: AppLanguage) -> String {
        Self.table[self]?[lang] ?? rawValue
    }

    private static let table: [L: [AppLanguage: String]] = [
        .appSubtitle: [.ru: "Генератор красивых адресов", .en: "Vanity address generator"],
        .sectionNetworks: [.ru: "Сети", .en: "Networks"],
        .sectionCondition: [.ru: "Условие поиска", .en: "Search condition"],
        .workersTitle: [.ru: "Процессы", .en: "Processes"],
        .workersSubtitle: [.ru: "параллельных воркеров", .en: "parallel workers"],
        .demoModeTitle: [.ru: "Демо-режим", .en: "Demo mode"],
        .demoModeSubtitle: [.ru: "быстрые тестовые находки", .en: "fast test finds"],
        .customPatternPlaceholderShort: [.ru: "Свой паттерн…", .en: "Custom pattern…"],
        .selectCondition: [.ru: "Выберите условие", .en: "Select condition"],
        .customPatternSelected: [.ru: "Свой паттерн", .en: "Custom pattern"],
        .speedEstimateTitle: [.ru: "Скорость для оценки времени", .en: "Speed for time estimate"],
        .speedAuto: [.ru: "Авто", .en: "Auto"],
        .speedManual: [.ru: "Вручную", .en: "Manual"],
        .unitAddrPerSec: [.ru: "addr/с", .en: "addr/s"],
        .noData: [.ru: "нет данных", .en: "no data"],
        .placeholderPrefix: [.ru: "например cafe", .en: "e.g. cafe"],
        .placeholderSuffix: [.ru: "например dead", .en: "e.g. dead"],
        .placeholderContains: [.ru: "например 1337", .en: "e.g. 1337"],
        .caseSensitiveToggle: [.ru: "Учитывать регистр (DeaD ≠ dead)", .en: "Case-sensitive (DeaD ≠ dead)"],
        .dangerousPatternPrefix: [.ru: "очень частый паттерн — ", .en: "very common pattern — "],
        .rarityApprox: [.ru: "≈ ", .en: "≈ "],
        .etaLabel: [.ru: "оценка времени: ≈ ", .en: "time estimate: ≈ "],
        .alphabetHintHelp: [.ru: "Какие символы можно писать в паттерне", .en: "Which characters can be used in the pattern"],
        .allowedChars: [.ru: "Допустимые символы", .en: "Allowed characters"],
        .startSearch: [.ru: "Начать поиск  ⌘⏎", .en: "Start search  ⌘⏎"],
        .wordListDefaults: [.ru: "Дефолтные слова", .en: "Default words"],
        .wordListCustom: [.ru: "Свои слова", .en: "Custom words"],
        .wordListAddPlaceholder: [.ru: "добавить слово…", .en: "add a word…"],
        .wordListNoneSelected: [.ru: "выберите хотя бы одно слово", .en: "select at least one word"],
        .stopSearch: [.ru: "Остановить", .en: "Stop"],
        .stopping: [.ru: "Останавливаем…", .en: "Stopping…"],

        .statSpeed: [.ru: "Скорость", .en: "Speed"],
        .statChecked: [.ru: "Проверено", .en: "Checked"],
        .statTime: [.ru: "Время", .en: "Time"],
        .statWorkers: [.ru: "Воркеры", .en: "Workers"],
        .unitAddresses: [.ru: "адресов", .en: "addresses"],
        .unitProcesses: [.ru: "процессов", .en: "processes"],
        .accelerated: [.ru: "Ускорено: ", .en: "Accelerated: "],
        .demoBadge: [.ru: "Демо", .en: "Demo"],
        .rarestFindHelp: [.ru: "Самая редкая находка за сессию", .en: "Rarest find this session"],
        .avgRarity: [.ru: "Средняя редкость: 1 : ", .en: "Average rarity: 1 : "],
        .statusStopped: [.ru: "Остановлено", .en: "Stopped"],
        .statusReady: [.ru: "Готов к запуску", .en: "Ready to start"],
        .statusSearching: [.ru: "Идёт поиск…", .en: "Searching…"],

        .durSecShort: [.ru: "< 1 сек", .en: "< 1 sec"],
        .durSec: [.ru: "сек", .en: "sec"],
        .durMin: [.ru: "мин", .en: "min"],
        .durHour: [.ru: "ч", .en: "h"],
        .durDay: [.ru: "дн", .en: "d"],
        .durYear: [.ru: "лет", .en: "y"],
        .magThousand: [.ru: "тыс", .en: "K"],
        .magMillion: [.ru: "млн", .en: "M"],
        .magBillion: [.ru: "млрд", .en: "B"],
        .magTrillion: [.ru: "трлн", .en: "T"],
        .magQuadrillion: [.ru: "квдрлн", .en: "Qa"],

        .systemHeader: [.ru: "СИСТЕМА", .en: "SYSTEM"],
        .memory: [.ru: "Память", .en: "Memory"],
        .notAvailable: [.ru: "н/д", .en: "n/a"],

        .alphabetNoteEth: [.ru: "адрес всегда начинается с 0x — это не часть паттерна", .en: "address always starts with 0x — not part of the pattern"],
        .alphabetNoteSol: [.ru: "base58: нет 0, O, I, l", .en: "base58: no 0, O, I, l"],
        .alphabetNoteTrx: [.ru: "base58: нет 0, O, I, l; адрес всегда начинается с T", .en: "base58: no 0, O, I, l; address always starts with T"],
        .alphabetNoteTon: [.ru: "адрес всегда начинается с EQ или UQ", .en: "address always starts with EQ or UQ"],

        .speedChartHeader: [.ru: "СКОРОСТЬ ВО ВРЕМЕНИ", .en: "SPEED OVER TIME"],
        .speedChartEmpty: [.ru: "График появится после запуска поиска", .en: "Chart will appear once search starts"],

        .modePrefix: [.ru: "Начало", .en: "Starts"],
        .modeSuffix: [.ru: "Конец", .en: "Ends"],
        .modeContains: [.ru: "Содержит", .en: "Contains"],

        .tabSearch: [.ru: "Поиск", .en: "Search"],
        .tabHistory: [.ru: "История", .en: "History"],

        .historyTitle: [.ru: "История находок", .en: "Found history"],
        .historyEmpty: [.ru: "Пока ничего не найдено — история появится после первых находок", .en: "Nothing found yet — history will appear after the first finds"],

        .liveFeedRunning: [.ru: "Ищем адрес — находки появятся здесь", .en: "Searching — finds will appear here"],
        .liveFeedIdle: [.ru: "Выберите сети и условие, затем нажмите «Начать поиск»", .en: "Select networks and a condition, then click \u{201c}Start search\u{201d}"],

        .revealInFinder: [.ru: "Показать в Finder", .en: "Show in Finder"],
        .calculatingBalance: [.ru: "считаем баланс…", .en: "checking balance…"],
        .holdToRevealKey: [.ru: "удерживайте, чтобы показать приватный ключ", .en: "hold to reveal the private key"],

        .processLaunchFailed: [.ru: "Не удалось запустить процесс: ", .en: "Failed to launch process: "],
    ]
}
