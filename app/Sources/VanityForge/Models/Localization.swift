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
    case liveFeedIdleContracts

    // MARK: FoundCardView
    case revealInFinder
    case calculatingBalance
    case holdToRevealKey

    // MARK: PythonBridge
    case processLaunchFailed

    // MARK: CREATE2
    case modeWallets
    case modeContracts
    case sectionFactory
    case sectionContract
    case sectionTarget
    case create2FactoryCustom
    case create2FactoryPlaceholder
    case create2InitCodeHash
    case create2InitCodeHashHelp
    case create2Caller
    case create2CallerHelp
    case create2CallerMissing
    case create2FactoryUnprotected
    case create2InvalidHex
    case create2GoalLeading
    case create2GoalZeros
    case create2GoalPrefix
    case create2GoalHook
    case create2HintLeading
    case create2HintZeros
    case create2HintPrefix
    case create2HintHook
    case create2MinBytes
    case create2PrefixPlaceholder
    case create2HookMask
    case create2Explain
    case create2Salt
    case create2Factory
    case create2Deployer
    case create2CopyForClient
    case create2ZeroBytes
    case create2LeadingZeroBytes
    case unitAttemptsPerSec
    case create2KindHint
    case create3KindHint
    case create3CallerMissing
    case sectionKind
    case splitKeyTitle
    case splitKeySubtitle
    case splitKeyPlaceholder
    case splitKeyHint
    case splitKeyNetworksOnly
    case splitKeyInvalid
    case splitKeyTweak
    case splitKeyBadge
    case useGPU
    case gpuNotUsedNote
    case cpuOnlyChip
    case cpuOnlyHelp
    case patternBadChars
    case patternTronStart
    case patternTryIgnoreCase
    case alphabetHex
    case alphabetBase58
    case alphabetTon
    case checkBalance
    case checkBalanceHelp
    case balanceFailed
    case gpuLoadLabel
    case openFile
    case openExplorer
    case showQR
    case qrCaption
    case copyAll
    case copiedToast
    case fileMissing
    case statChance
    case chanceAvgPrefix
    case chanceNoData
    case feedTitle
    case openResultsFolder
    case clearFeed
    case sectionSettings
    case notifyFoundTitle
    case notifyMoreFinds
    case keepAwakeChip
    case keepAwakeHelp
    case useGPUHintContracts
    case useGPUHintWallets

    // MARK: Улов, аватарка, оценка
    case bycatchTitle
    case bycatchToggle
    case bycatchToggleHint
    case bycatchCount
    case bycatchCPUNote
    case modeAvatar
    case sectionAvatarDrawing
    case sectionAvatarColors
    case avatarHint
    case avatarMisses
    case avatarColorMain
    case avatarColorBackground
    case avatarColorSpot
    case avatarDrawingSmile
    case avatarDrawingHeart
    case avatarDrawingFrame
    case avatarDrawingCross
    case avatarDrawingPlain
    case avatarDrawingClear
    case avatarEmpty
    case avatarSpotsNote
    case avatarGPUOnly
    case liveFeedIdleAvatar
    case swatchAny
    case swatchRed
    case swatchOrange
    case swatchYellow
    case swatchGreen
    case swatchCyan
    case swatchBlue
    case swatchPurple
    case swatchPink
    case swatchLight
    case swatchDark
    case tabRarity
    case rarityTitle
    case raritySubtitle
    case rarityPlaceholder
    case rarityUnknown
    case rarityNothing
    case rarityOneIn
    case rarityBits
    case rarityTimeOnMac
    case rarityBetterThan
    case rarityFeaturesTitle
    case rarityCopyCard
    case raritySaveCard
    case rarityCardFooter
    case rarityRecentFinds
    case rarityRunStart
    case rarityRunEnd
    case rarityRunInside
    case rarityWordStart
    case rarityWordEnd
    case rarityMirror
    case rarityDigitsOnly
    case rarityLettersOnly
    case rarityFewChars
    case tierOrdinary
    case tierNice
    case tierRare
    case tierVeryRare
    case tierExceptional
    case tierLegendary

    case rarityChecksumUpper
    case rarityChecksumLower
    case avatarFitTime

    case avatarStyleBlockies
    case avatarStyleJazzicon
    case sectionJazziconGallery
    case jazziconMore
    case jazziconPick
    case jazziconSelectedHint
    case jazziconHint

    case alphabetNoteBtc
    case alphabetNoteBtc1

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
        .liveFeedIdleContracts: [.ru: "Вставьте хеш кода и кошелёк заказчика, выберите условие и нажмите «Начать поиск»", .en: "Paste the code hash and the client's wallet, pick a condition, then click \u{201c}Start search\u{201d}"],
        .liveFeedIdle: [.ru: "Выберите сети и условие, затем нажмите «Начать поиск»", .en: "Select networks and a condition, then click \u{201c}Start search\u{201d}"],

        .revealInFinder: [.ru: "Показать в Finder", .en: "Show in Finder"],
        .calculatingBalance: [.ru: "считаем баланс…", .en: "checking balance…"],
        .holdToRevealKey: [.ru: "удерживайте, чтобы показать приватный ключ", .en: "hold to reveal the private key"],

        .processLaunchFailed: [.ru: "Не удалось запустить процесс: ", .en: "Failed to launch process: "],

        .modeWallets: [.ru: "Кошельки", .en: "Wallets"],
        .modeContracts: [.ru: "Контракты", .en: "Contracts"],
        .sectionFactory: [.ru: "Фабрика CREATE2", .en: "CREATE2 factory"],
        .sectionContract: [.ru: "Контракт заказчика", .en: "Client's contract"],
        .sectionTarget: [.ru: "Какой адрес ищем", .en: "Target address"],
        .create2FactoryCustom: [.ru: "Своя фабрика…", .en: "Custom factory…"],
        .create2FactoryPlaceholder: [.ru: "адрес фабрики 0x…", .en: "factory address 0x…"],
        .create2InitCodeHash: [.ru: "хеш кода: keccak256(init code), 0x…", .en: "code hash: keccak256(init code), 0x…"],
        .create2InitCodeHashHelp: [.ru: "Даёт заказчик. Любое изменение кода или параметров конструктора меняет хеш — и адрес. Майнить только под финальный код.", .en: "Provided by the client. Any change to the code or constructor arguments changes the hash — and the address. Mine only for final code."],
        .create2Caller: [.ru: "кошелёк заказчика 0x…", .en: "client's wallet 0x…"],
        .create2CallerHelp: [.ru: "Вписывается в первые 20 байт salt: этот salt сможет использовать только этот кошелёк.", .en: "Goes into the first 20 bytes of the salt: only this wallet will be able to use it."],
        .create2CallerMissing: [.ru: "Без кошелька заказчика salt сможет использовать кто угодно", .en: "Without the client's wallet anyone can use the salt"],
        .create2FactoryUnprotected: [.ru: "Эта фабрика не проверяет кошелёк в salt — найденный адрес могут перехватить при развёртывании", .en: "This factory doesn't check the wallet in the salt — the address can be front-run at deployment"],
        .create2InvalidHex: [.ru: "неверный hex", .en: "invalid hex"],
        .create2GoalLeading: [.ru: "Нули в начале", .en: "Leading zeros"],
        .create2GoalZeros: [.ru: "Нули где угодно", .en: "Zeros anywhere"],
        .create2GoalPrefix: [.ru: "Префикс", .en: "Prefix"],
        .create2GoalHook: [.ru: "Uniswap v4 hook", .en: "Uniswap v4 hook"],
        .create2HintLeading: [.ru: "0x0000…: экономит газ на каждом вызове и выглядит солидно. Показываем каждый новый рекорд.", .en: "0x0000…: saves gas on every call and looks serious. Every new record is shown."],
        .create2HintZeros: [.ru: "Нулевой байт в calldata стоит 4 газа вместо 16 — важен каждый ноль, где бы он ни был. Показываем каждый новый рекорд.", .en: "A zero byte in calldata costs 4 gas instead of 16 — every zero counts, wherever it is. Every new record is shown."],
        .create2HintPrefix: [.ru: "Красивое начало адреса: dead, cafe, название проекта в hex. Первое совпадение, дальше только варианты с бо́льшим числом нулей.", .en: "A nice address start: dead, cafe, a project name in hex. First match, then only variants with more zero bytes."],
        .create2HintHook: [.ru: "В v4 права хука зашиты в младшие 14 бит адреса. Отметьте ровно те, что реализует контракт. Первое совпадение, дальше только варианты с бо́льшим числом нулей.", .en: "In v4 hook permissions live in the lowest 14 bits of the address. Tick exactly the ones the contract implements. First match, then only variants with more zero bytes."],
        .create2MinBytes: [.ru: "Минимум нулевых байт", .en: "Minimum zero bytes"],
        .create2PrefixPlaceholder: [.ru: "например dead", .en: "e.g. dead"],
        .create2HookMask: [.ru: "маска", .en: "mask"],
        .create2Explain: [.ru: "Адрес контракта = keccak256(0xff, фабрика, salt, хеш кода). Фабрику и хеш даёт заказчик, мы перебираем salt. Ключей нет: salt не секретный, его можно спокойно отдать заказчику.", .en: "Contract address = keccak256(0xff, factory, salt, code hash). The client provides the factory and hash; we iterate the salt. No keys involved: the salt isn't secret and can be handed to the client."],
        .create2Salt: [.ru: "salt", .en: "salt"],
        .create2Factory: [.ru: "фабрика", .en: "factory"],
        .create2Deployer: [.ru: "кошелёк", .en: "wallet"],
        .create2CopyForClient: [.ru: "Скопировать для заказчика", .en: "Copy for the client"],
        .create2ZeroBytes: [.ru: "нулевых байт: ", .en: "zero bytes: "],
        .create2LeadingZeroBytes: [.ru: "в начале: ", .en: "leading: "],
        .create2KindHint: [.ru: "Адрес зависит от кода контракта: нужен хеш кода от заказчика.", .en: "The address depends on the contract code: you need the client's code hash."],
        .create3KindHint: [.ru: "Адрес не зависит от кода: намайнил один раз — развернуть можно любой контракт через CreateX.deployCreate3.", .en: "The address doesn't depend on the code: mine once, deploy any contract later via CreateX.deployCreate3."],
        .create3CallerMissing: [.ru: "Без кошелька salt сможет использовать кто угодно — и положить на адрес свой код", .en: "Without a wallet anyone can use the salt — and put their own code at the address"],
        .splitKeyTitle: [.ru: "Для заказчика (split-key)", .en: "For a client (split-key)"],
        .splitKeySubtitle: [.ru: "ключ адреса узнает только он", .en: "only they will know the key"],
        .splitKeyPlaceholder: [.ru: "публичный ключ заказчика 02… / 03… / 04…", .en: "client's public key 02… / 03… / 04…"],
        .splitKeyHint: [.ru: "Заказчик создаёт ключ у себя (python3 python/splitkey.py new) и присылает только публичный. Вы находите добавку k, он сам собирает приватный ключ: python3 python/splitkey.py combine <его ключ> <k>.", .en: "The client creates a key locally (python3 python/splitkey.py new) and sends only the public key. You find the tweak k; they build the private key themselves: python3 python/splitkey.py combine <their key> <k>."],
        .splitKeyNetworksOnly: [.ru: "Split-key работает только для EVM и TRON — снимите остальные сети", .en: "Split-key works only for EVM and TRON — deselect the other networks"],
        .splitKeyInvalid: [.ru: "это не публичный ключ secp256k1", .en: "not a secp256k1 public key"],
        .splitKeyTweak: [.ru: "добавка k", .en: "tweak k"],
        .splitKeyBadge: [.ru: "ключ только у заказчика", .en: "key stays with the client"],
        .openFile: [.ru: "Открыть файл", .en: "Open file"],
        .openExplorer: [.ru: "Обозреватель", .en: "Explorer"],
        .showQR: [.ru: "QR-код", .en: "QR code"],
        .qrCaption: [.ru: "Адрес для перевода — приватный ключ здесь не показывается", .en: "Address for receiving — the private key is not shown here"],
        .copyAll: [.ru: "Скопировать всё", .en: "Copy all"],
        .copiedToast: [.ru: "Скопировано", .en: "Copied"],
        .fileMissing: [.ru: "Файл находки не найден: ", .en: "Result file not found: "],
        .statChance: [.ru: "Шанс найти", .en: "Find chance"],
        .chanceAvgPrefix: [.ru: "в среднем 1 за ", .en: "on average 1 per "],
        .chanceNoData: [.ru: "нет оценки редкости", .en: "no rarity estimate"],
        .feedTitle: [.ru: "Находки", .en: "Finds"],
        .openResultsFolder: [.ru: "Папка с находками", .en: "Results folder"],
        .clearFeed: [.ru: "Очистить ленту", .en: "Clear feed"],
        .sectionSettings: [.ru: "Параметры", .en: "Settings"],
        .notifyFoundTitle: [.ru: "Найден адрес", .en: "Address found"],
        .notifyMoreFinds: [.ru: " и ещё находок: ", .en: " and more finds: "],
        .keepAwakeChip: [.ru: "Mac не уснёт", .en: "Mac stays awake"],
        .keepAwakeHelp: [.ru: "Во время поиска Mac не уходит в сон (экран может гаснуть)", .en: "While searching the Mac won't go to sleep (the display may still turn off)"],
        .gpuLoadLabel: [.ru: "Нагрузка", .en: "Load"],
        .checkBalance: [.ru: "Проверить баланс", .en: "Check balance"],
        .checkBalanceHelp: [.ru: "Адрес отправится в публичные RPC-узлы — поэтому только по нажатию", .en: "The address is sent to public RPC nodes — so only on click"],
        .balanceFailed: [.ru: "не удалось получить баланс", .en: "couldn't get the balance"],
        .gpuNotUsedNote: [.ru: "Solana и TON видеокарта не умеет — поиск пойдёт на процессоре, в сотни раз медленнее", .en: "The GPU can't do Solana or TON — the search runs on the CPU, hundreds of times slower"],
        .cpuOnlyChip: [.ru: "на процессоре", .en: "on the CPU"],
        .cpuOnlyHelp: [.ru: "Видеокарта включена, но это условие она не умеет — считает процессор", .en: "The GPU is on, but it can't do this condition — the CPU is searching"],
        .patternBadChars: [.ru: "Символов {chars} нет в адресах {network}", .en: "Addresses on {network} never contain {chars}"],
        .patternTronStart: [.ru: "Адреса TRON так не начинаются: после T идут только 9, A–H, J–N, P–Z", .en: "TRON addresses never start like this: after T come only 9, A–H, J–N, P–Z"],
        .patternTryIgnoreCase: [.ru: "— снимите «Учитывать регистр», и совпадение станет возможным.", .en: "— turn off \"Case sensitive\" and a match becomes possible."],
        .alphabetHex: [.ru: "(там только 0–9 и a–f)", .en: "(only 0–9 and a–f)"],
        .alphabetBase58: [.ru: "(в base58 нет 0, O, I и l)", .en: "(base58 has no 0, O, I or l)"],
        .alphabetTon: [.ru: "(только латиница, цифры, - и _)", .en: "(only Latin letters, digits, - and _)"],
        .useGPU: [.ru: "Считать на видеокарте", .en: "Use the GPU"],
        .useGPUHintWallets: [.ru: "Metal: EVM, TRON и Bitcoin (и для split-key) в 15–30 раз быстрее, «содержит» — в сотни. Solana и TON считаются на процессоре.", .en: "Metal: EVM, TRON and Bitcoin (split-key too) 15–30× faster, \"contains\" hundreds of times. Solana and TON run on the CPU."],
        .useGPUHintContracts: [.ru: "Metal, в ~5 раз быстрее процессора. Выключите, если видеокарта нужна под другое.", .en: "Metal, about 5× faster than the CPU. Turn off if you need the GPU for something else."],
        .sectionKind: [.ru: "Способ развёртывания", .en: "Deployment method"],
        .unitAttemptsPerSec: [.ru: "попыток/с", .en: "tries/s"],
        .bycatchTitle: [.ru: "Попалось по пути", .en: "Caught along the way"],
        .bycatchToggle: [.ru: "Побочный улов", .en: "Bycatch"],
        .bycatchToggleHint: [.ru: "Видеокарта заодно ловит адреса, которые не подходят под условие, но красивы сами по себе: 9+ одинаковых символов на краю или слово вроде deadc0ffee. Скорость не падает.", .en: "The GPU also catches addresses that miss the condition but are pretty on their own: 9+ identical characters at an edge or a word like deadc0ffee. No speed cost."],
        .bycatchCount: [.ru: "улов: ", .en: "bycatch: "],
        .bycatchCPUNote: [.ru: "Только на видеокарте", .en: "GPU only"],
        .modeAvatar: [.ru: "Аватарка", .en: "Avatar"],
        .sectionAvatarDrawing: [.ru: "Рисунок", .en: "Drawing"],
        .sectionAvatarColors: [.ru: "Цвета", .en: "Colors"],
        .avatarHint: [.ru: "Иконка адреса в Etherscan и MetaMask (blockies). Щёлкайте клетки: любая → фон → цвет → пятна. Правая половина — зеркало левой.", .en: "The address icon in Etherscan and MetaMask (blockies). Click cells: any → background → color → spots. The right half mirrors the left."],
        .avatarMisses: [.ru: "Может не совпасть клеток", .en: "Cells allowed to differ"],
        .avatarColorMain: [.ru: "Цвет", .en: "Color"],
        .avatarColorBackground: [.ru: "Фон", .en: "Background"],
        .avatarColorSpot: [.ru: "Пятна", .en: "Spots"],
        .avatarDrawingSmile: [.ru: "Смайлик", .en: "Smiley"],
        .avatarDrawingHeart: [.ru: "Сердце", .en: "Heart"],
        .avatarDrawingFrame: [.ru: "Рамка", .en: "Frame"],
        .avatarDrawingCross: [.ru: "Крест", .en: "Cross"],
        .avatarDrawingPlain: [.ru: "Чистый фон", .en: "Plain"],
        .avatarDrawingClear: [.ru: "Сбросить", .en: "Clear"],
        .avatarEmpty: [.ru: "Нарисуйте что-нибудь или выберите цвет", .en: "Draw something or pick a color"],
        .avatarSpotsNote: [.ru: "Пятна выпадают в 13% клеток, фон и цвет — в 43%: рисунок из пятен в разы реже.", .en: "Spots fill 13% of cells, background and color 43% each: a drawing made of spots is far rarer."],
        .avatarGPUOnly: [.ru: "Без видеокарты аватарка ищется на процессоре — в сотни раз медленнее", .en: "Without the GPU the avatar is searched on the CPU — hundreds of times slower"],
        .liveFeedIdleAvatar: [.ru: "Нарисуйте аватарку слева — найдём адрес с такой иконкой", .en: "Draw an avatar on the left — we'll find an address with that icon"],
        .swatchAny: [.ru: "любой", .en: "any"],
        .swatchRed: [.ru: "красный", .en: "red"],
        .swatchOrange: [.ru: "оранжевый", .en: "orange"],
        .swatchYellow: [.ru: "жёлтый", .en: "yellow"],
        .swatchGreen: [.ru: "зелёный", .en: "green"],
        .swatchCyan: [.ru: "бирюзовый", .en: "cyan"],
        .swatchBlue: [.ru: "синий", .en: "blue"],
        .swatchPurple: [.ru: "фиолетовый", .en: "purple"],
        .swatchPink: [.ru: "розовый", .en: "pink"],
        .swatchLight: [.ru: "светлый", .en: "light"],
        .swatchDark: [.ru: "тёмный", .en: "dark"],
        .tabRarity: [.ru: "Оценка", .en: "Rate"],
        .rarityTitle: [.ru: "Насколько красив адрес", .en: "How rare is an address"],
        .raritySubtitle: [.ru: "Вставьте любой адрес — свой, чужой, из обозревателя. Ничего никуда не отправляется: всё считается здесь.", .en: "Paste any address — yours, someone else's, from an explorer. Nothing is sent anywhere: it's all computed locally."],
        .rarityPlaceholder: [.ru: "0x…, T…, адрес Solana или TON", .en: "0x…, T…, a Solana or TON address"],
        .rarityUnknown: [.ru: "Не похоже на адрес EVM, TRON, Solana или TON", .en: "Doesn't look like an EVM, TRON, Solana or TON address"],
        .rarityNothing: [.ru: "Ничего особенного — обычный случайный адрес", .en: "Nothing special — an ordinary random address"],
        .rarityOneIn: [.ru: "1 из {n} адресов", .en: "1 in {n} addresses"],
        .rarityBits: [.ru: "бит редкости", .en: "bits of rarity"],
        .rarityTimeOnMac: [.ru: "Столько искать на этом Mac", .en: "Time to find on this Mac"],
        .rarityBetterThan: [.ru: "редче, чем {p} адресов", .en: "rarer than {p} of addresses"],
        .rarityFeaturesTitle: [.ru: "Что в нём красивого", .en: "What makes it pretty"],
        .rarityCopyCard: [.ru: "Скопировать картинку", .en: "Copy image"],
        .raritySaveCard: [.ru: "Сохранить PNG", .en: "Save PNG"],
        .rarityCardFooter: [.ru: "оценка редкости адреса", .en: "address rarity check"],
        .rarityRecentFinds: [.ru: "Из последних находок", .en: "From recent finds"],
        .rarityRunStart: [.ru: "{n} × «{c}» в начале", .en: "{n} × '{c}' at the start"],
        .rarityRunEnd: [.ru: "{n} × «{c}» в конце", .en: "{n} × '{c}' at the end"],
        .rarityRunInside: [.ru: "{n} × «{c}» подряд внутри", .en: "{n} × '{c}' in a row inside"],
        .rarityWordStart: [.ru: "«{w}» в начале", .en: "'{w}' at the start"],
        .rarityWordEnd: [.ru: "«{w}» в конце", .en: "'{w}' at the end"],
        .rarityMirror: [.ru: "Зеркальные края: {n} символов", .en: "Mirrored edges: {n} characters"],
        .rarityDigitsOnly: [.ru: "Только цифры", .en: "Digits only"],
        .rarityLettersOnly: [.ru: "Только буквы", .en: "Letters only"],
        .rarityFewChars: [.ru: "Всего {n} разных символов", .en: "Only {n} distinct characters"],
        .tierOrdinary: [.ru: "обычный", .en: "ordinary"],
        .tierNice: [.ru: "симпатичный", .en: "nice"],
        .tierRare: [.ru: "редкий", .en: "rare"],
        .tierVeryRare: [.ru: "очень редкий", .en: "very rare"],
        .tierExceptional: [.ru: "исключительный", .en: "exceptional"],
        .tierLegendary: [.ru: "легендарный", .en: "legendary"],
        .rarityChecksumUpper: [.ru: "Checksum: все {n} букв заглавные", .en: "Checksum: all {n} letters uppercase"],
        .rarityChecksumLower: [.ru: "Checksum: все {n} букв строчные", .en: "Checksum: all {n} letters lowercase"],
        .avatarFitTime: [.ru: "Подобрать допуск под время", .en: "Fit tolerance to a time"],
        .avatarStyleBlockies: [.ru: "Etherscan", .en: "Etherscan"],
        .avatarStyleJazzicon: [.ru: "MetaMask", .en: "MetaMask"],
        .sectionJazziconGallery: [.ru: "Выберите иконку", .en: "Pick an icon"],
        .jazziconMore: [.ru: "Ещё", .en: "More"],
        .jazziconPick: [.ru: "Выберите иконку из галереи", .en: "Pick an icon from the gallery"],
        .jazziconSelectedHint: [.ru: "Иконку MetaMask задают первые 8 символов адреса — их и ищем", .en: "The MetaMask icon is set by the first 8 characters of the address — that's what we search for"],
        .jazziconHint: [.ru: "MetaMask рисует иконку по первым 8 символам адреса. Выберите понравившуюся — видеокарта найдёт адрес с таким началом примерно за минуту.", .en: "MetaMask draws the icon from the first 8 characters of the address. Pick one you like — the GPU finds an address with that start in about a minute."],
        .alphabetNoteBtc: [.ru: "bech32: только строчные, нет 1, b, i, o; адрес начинается с bc1q", .en: "bech32: lowercase only, no 1, b, i, o; address starts with bc1q"],
        .alphabetNoteBtc1: [.ru: "base58: нет 0, O, I, l; адрес всегда начинается с 1", .en: "base58: no 0, O, I, l; address always starts with 1"],
    ]
}
