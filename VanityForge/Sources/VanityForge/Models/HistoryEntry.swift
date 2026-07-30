import Foundation

struct HistoryEntry: Identifiable, Hashable {
    let id = UUID()
    let network: String
    let networkFull: String
    let presetFolder: String
    let address: String
    let privateKey: String
    let conditions: String
    let foundAt: String
    let fileURL: URL

    static func parse(fileURL: URL, network: String, presetFolder: String) -> HistoryEntry? {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        var fields: [String: String] = [:]
        for line in content.split(separator: "\n") {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        guard let address = fields["Address"], let privateKey = fields["Private"] else { return nil }
        return HistoryEntry(
            network: network,
            networkFull: fields["Network"] ?? network,
            presetFolder: presetFolder,
            address: address,
            privateKey: privateKey,
            conditions: fields["Conditions"] ?? "",
            foundAt: fields["Found"] ?? "",
            fileURL: fileURL
        )
    }
}

struct HistoryPresetGroup: Identifiable {
    let id: String
    let name: String
    let entries: [HistoryEntry]
}

struct HistoryNetworkGroup: Identifiable {
    let id: String
    let network: String
    let networkFull: String
    let presets: [HistoryPresetGroup]

    var totalCount: Int { presets.reduce(0) { $0 + $1.entries.count } }
}

enum HistoryLoader {
    static let networkFullNames: [String: String] = [
        "sol": "Solana", "eth": "EVM (ETH, BSC, Polygon)", "trx": "Tron", "ton": "TON",
    ]

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    static func load(resultsDir: URL) -> [HistoryNetworkGroup] {
        let fm = FileManager.default
        guard let networkDirs = try? fm.contentsOfDirectory(at: resultsDir, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        var groups: [HistoryNetworkGroup] = []
        for networkDir in networkDirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let network = networkDir.lastPathComponent
            guard isDirectory(networkDir), !network.hasPrefix("_") else { continue }
            guard let presetDirs = try? fm.contentsOfDirectory(at: networkDir, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }

            var presetGroups: [HistoryPresetGroup] = []
            for presetDir in presetDirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard isDirectory(presetDir) else { continue }
                guard let files = try? fm.contentsOfDirectory(at: presetDir, includingPropertiesForKeys: nil) else { continue }
                let entries = files
                    .filter { $0.pathExtension == "txt" }
                    .compactMap { HistoryEntry.parse(fileURL: $0, network: network, presetFolder: presetDir.lastPathComponent) }
                    .sorted { $0.foundAt > $1.foundAt }
                if !entries.isEmpty {
                    presetGroups.append(HistoryPresetGroup(id: "\(network)/\(presetDir.lastPathComponent)", name: presetDir.lastPathComponent, entries: entries))
                }
            }
            if !presetGroups.isEmpty {
                groups.append(HistoryNetworkGroup(
                    id: network,
                    network: network,
                    networkFull: networkFullNames[network] ?? network,
                    presets: presetGroups
                ))
            }
        }
        return groups
    }
}
