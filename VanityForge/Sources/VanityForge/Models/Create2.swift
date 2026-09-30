import Foundation

/// Что ищем: адреса кошельков (приватные ключи) или адреса контрактов
/// (salt для CREATE2 — майнинг для заказчика, ключей нет вообще).
enum SearchMode: String, Codable, CaseIterable, Identifiable {
    case wallets, contracts
    var id: String { rawValue }

    func label(_ lang: AppLanguage) -> String {
        switch self {
        case .wallets: return L.modeWallets.s(lang)
        case .contracts: return L.modeContracts.s(lang)
        }
    }
}

/// Фабрики CREATE2 с одинаковым адресом во всех EVM-сетях. От фабрики
/// зависит итоговый адрес, поэтому её выбирает заказчик, а не мы.
enum Create2Factory: String, Codable, CaseIterable, Identifiable {
    case immutable, arachnid, custom
    var id: String { rawValue }

    var address: String? {
        switch self {
        case .immutable: return "0x0000000000FFe8B47B3e2130213B802212439497"
        case .arachnid: return "0x4e59b44847b379578588920cA78FbF26c0B4956C"
        case .custom: return nil
        }
    }

    func label(_ lang: AppLanguage) -> String {
        switch self {
        case .immutable: return "ImmutableCreate2Factory"
        case .arachnid: return "Deterministic Deployment Proxy"
        case .custom: return L.create2FactoryCustom.s(lang)
        }
    }

    /// ImmutableCreate2Factory проверяет, что первые 20 байт salt — это
    /// msg.sender, поэтому найденный salt бесполезен для всех, кроме заказчика.
    /// Deterministic Deployment Proxy (его использует Foundry) такой защиты не
    /// даёт: salt, увиденный в мемпуле, может перехватить кто угодно.
    var protectsCaller: Bool { self == .immutable }
}

enum Create2Goal: String, Codable, CaseIterable, Identifiable {
    case leading, zeros, prefix, hook
    var id: String { rawValue }

    func label(_ lang: AppLanguage) -> String {
        switch self {
        case .leading: return L.create2GoalLeading.s(lang)
        case .zeros: return L.create2GoalZeros.s(lang)
        case .prefix: return L.create2GoalPrefix.s(lang)
        case .hook: return L.create2GoalHook.s(lang)
        }
    }

    func hint(_ lang: AppLanguage) -> String {
        switch self {
        case .leading: return L.create2HintLeading.s(lang)
        case .zeros: return L.create2HintZeros.s(lang)
        case .prefix: return L.create2HintPrefix.s(lang)
        case .hook: return L.create2HintHook.s(lang)
        }
    }
}

/// Права хука Uniswap v4 — зашиты в младшие 14 бит адреса (Hooks.sol).
struct HookFlag: Identifiable, Hashable {
    let name: String
    let bit: Int
    var id: Int { bit }
    var mask: UInt16 { 1 << UInt16(bit) }

    static let all: [HookFlag] = [
        HookFlag(name: "beforeInitialize", bit: 13),
        HookFlag(name: "afterInitialize", bit: 12),
        HookFlag(name: "beforeAddLiquidity", bit: 11),
        HookFlag(name: "afterAddLiquidity", bit: 10),
        HookFlag(name: "beforeRemoveLiquidity", bit: 9),
        HookFlag(name: "afterRemoveLiquidity", bit: 8),
        HookFlag(name: "beforeSwap", bit: 7),
        HookFlag(name: "afterSwap", bit: 6),
        HookFlag(name: "beforeDonate", bit: 5),
        HookFlag(name: "afterDonate", bit: 4),
        HookFlag(name: "beforeSwapReturnDelta", bit: 3),
        HookFlag(name: "afterSwapReturnDelta", bit: 2),
        HookFlag(name: "afterAddLiquidityReturnDelta", bit: 1),
        HookFlag(name: "afterRemoveLiquidityReturnDelta", bit: 0),
    ]
}

enum Create2Math {
    static let addressBytes = 20

    static func isHex(_ raw: String, bytes: Int) -> Bool {
        let body = strip(raw)
        return body.count == bytes * 2 && body.allSatisfy(\.isHexDigit)
    }

    static func strip(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.lowercased().hasPrefix("0x") ? String(trimmed.dropFirst(2)) : trimmed
    }

    /// «1 из N» для одного адреса — та же шкала, что у пресетов кошельков.
    static func rarity(goal: Create2Goal, minBytes: Int, prefix: String) -> UInt64? {
        switch goal {
        case .leading:
            return pow256(minBytes)
        case .zeros:
            let p = 1.0 / 256
            var tail = 0.0
            for k in minBytes...addressBytes {
                tail += binomial(addressBytes, k) * pow(p, Double(k)) * pow(1 - p, Double(addressBytes - k))
            }
            return tail > 0 ? clamp(1 / tail) : nil
        case .prefix:
            let body = strip(prefix)
            guard !body.isEmpty, body.allSatisfy(\.isHexDigit) else { return nil }
            return clamp(pow(16, Double(body.count)))
        case .hook:
            return 1 << 14
        }
    }

    private static func pow256(_ n: Int) -> UInt64 { clamp(pow(256, Double(n))) }

    private static func clamp(_ value: Double) -> UInt64 {
        value >= Double(UInt64.max) ? UInt64.max : UInt64(value)
    }

    private static func binomial(_ n: Int, _ k: Int) -> Double {
        guard k >= 0, k <= n else { return 0 }
        var result = 1.0
        for i in 0..<k { result = result * Double(n - i) / Double(i + 1) }
        return result
    }
}
