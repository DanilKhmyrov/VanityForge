import Foundation

struct GPUInfo: Codable, Hashable {
    let available: Bool
    let path: String?
    /// "keyhunt" (внешний, если установлен отдельно) или "ethvanity"
    /// (встроенный CPU-ускоритель) — какой инструмент реально ускоряет ETH.
    let tool: String?

    var toolLabel: String? {
        switch tool {
        case "keyhunt": return "keyhunt"
        case "ethvanity": return "ethvanity"
        default: return nil
        }
    }
}

struct StartedEvent: Codable, Hashable {
    let networks: [String]
    let networksFull: [String: String]
    let preset: String
    let presetDesc: String
    let cpuCount: Int
    let workersTotal: Int
    let gpu: GPUInfo
    let fake: Bool

    enum CodingKeys: String, CodingKey {
        case networks
        case networksFull = "networks_full"
        case preset
        case presetDesc = "preset_desc"
        case cpuCount = "cpu_count"
        case workersTotal = "workers_total"
        case gpu
        case fake
    }
}

struct StatsEvent: Codable, Hashable {
    let elapsedSeconds: Double
    let totalChecked: UInt64
    let speed: Int
    let workersTotal: Int

    enum CodingKeys: String, CodingKey {
        case elapsedSeconds = "elapsed_seconds"
        case totalChecked = "total_checked"
        case speed
        case workersTotal = "workers_total"
    }
}

struct FoundEvent: Codable, Hashable, Identifiable {
    let seq: Int
    let network: String
    let networkFull: String
    let address: String
    let checksumAddress: String?
    let privateKey: String
    let matched: [String]
    let matchedDesc: [String]
    let conditionsStr: String
    let foundWords: [String]
    let filepath: String
    let foundAt: String

    var id: Int { seq }

    enum CodingKeys: String, CodingKey {
        case seq
        case network
        case networkFull = "network_full"
        case address
        case checksumAddress = "checksum_address"
        case privateKey = "private_key"
        case matched
        case matchedDesc = "matched_desc"
        case conditionsStr = "conditions_str"
        case foundWords = "found_words"
        case filepath
        case foundAt = "found_at"
    }
}

struct BalanceEvent: Codable, Hashable {
    let seq: Int
    let address: String
    let balances: [String: Double]?
}

struct StoppedEvent: Codable, Hashable {
    let reason: String
    let totalChecked: UInt64
    let foundCount: Int
    let elapsedSeconds: Double
    let rarity1In: UInt64?

    enum CodingKeys: String, CodingKey {
        case reason
        case totalChecked = "total_checked"
        case foundCount = "found_count"
        case elapsedSeconds = "elapsed_seconds"
        case rarity1In = "rarity_1_in"
    }
}

struct ErrorEvent: Codable, Hashable {
    let message: String
    let fatal: Bool
}

struct PresetItem: Codable, Hashable, Identifiable {
    let key: String
    let description: String
    let rarity1In: UInt64?
    var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key
        case description
        case rarity1In = "rarity_1_in"
    }
}

struct PresetsEvent: Codable, Hashable {
    let networkOrder: [String]
    let networks: [String: String]
    let presetsByNetwork: [String: [PresetItem]]
    let alphabetSizes: [String: Int]
    let bodyLengths: [String: Int]
    let defaultWords: [String]

    enum CodingKeys: String, CodingKey {
        case networkOrder = "network_order"
        case networks
        case presetsByNetwork = "presets_by_network"
        case alphabetSizes = "alphabet_sizes"
        case bodyLengths = "body_lengths"
        case defaultWords = "default_words"
    }
}

enum BridgeEvent {
    case started(StartedEvent)
    case stats(StatsEvent)
    case found(FoundEvent)
    case stopped(StoppedEvent)
    case error(ErrorEvent)
    case presets(PresetsEvent)
    case balance(BalanceEvent)

    private struct TypeProbe: Decodable {
        let type: String
    }

    static func parse(line: String) -> BridgeEvent? {
        guard let data = line.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        guard let probe = try? decoder.decode(TypeProbe.self, from: data) else { return nil }
        switch probe.type {
        case "started":
            return (try? decoder.decode(StartedEvent.self, from: data)).map(BridgeEvent.started)
        case "stats":
            return (try? decoder.decode(StatsEvent.self, from: data)).map(BridgeEvent.stats)
        case "found":
            return (try? decoder.decode(FoundEvent.self, from: data)).map(BridgeEvent.found)
        case "stopped":
            return (try? decoder.decode(StoppedEvent.self, from: data)).map(BridgeEvent.stopped)
        case "error":
            return (try? decoder.decode(ErrorEvent.self, from: data)).map(BridgeEvent.error)
        case "presets":
            return (try? decoder.decode(PresetsEvent.self, from: data)).map(BridgeEvent.presets)
        case "balance":
            return (try? decoder.decode(BalanceEvent.self, from: data)).map(BridgeEvent.balance)
        default:
            return nil
        }
    }
}
