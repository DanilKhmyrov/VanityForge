import AppKit
import SwiftUI

struct HistoryView: View {
    @Environment(SessionViewModel.self) private var session
    @State private var groups: [HistoryNetworkGroup] = []
    @State private var isLoading = true
    @State private var expanded: Set<String> = []

    private static var resultsDir: URL { ResultsLocation.directory }

    private var totalCount: Int { groups.reduce(0) { $0 + $1.totalCount } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(session.t(.historyTitle))
                    .font(.system(size: 16, weight: .semibold))
                if totalCount > 0 {
                    Text("\(totalCount)")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    let dir = ResultsLocation.directory
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(dir)
                } label: {
                    Label(session.t(.openResultsFolder), systemImage: "folder")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(0.05)))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Button { reload() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if groups.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(groups) { group in
                            networkSection(group)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .task { reload() }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(session.t(.historyEmpty))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func networkSection(_ group: HistoryNetworkGroup) -> some View {
        let accent = NetworkVisual.accent(for: group.network)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                NetworkIcon(key: group.network, size: 18)
                    .shadow(color: accent.opacity(0.5), radius: 5)
                Text(group.networkFull).font(.system(size: 13, weight: .semibold))
                Text("\(group.totalCount)").font(.system(size: 11)).foregroundStyle(.tertiary)
            }

            ForEach(group.presets) { preset in
                DisclosureGroup(isExpanded: expandedBinding(preset.id)) {
                    VStack(spacing: 6) {
                        ForEach(preset.entries) { entry in
                            HistoryRow(entry: entry, accent: accent)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    HStack {
                        Text(preset.name).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        Text("(\(preset.entries.count))").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, 17)
            }
        }
        .padding(14)
        .elevatedGlass(accent: accent, cornerRadius: 14, intensity: 0.5)
    }

    private func expandedBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { isOn in
                if isOn { expanded.insert(id) } else { expanded.remove(id) }
            }
        )
    }

    private func reload() {
        isLoading = true
        let dir = Self.resultsDir
        Task.detached(priority: .userInitiated) {
            let loaded = HistoryLoader.load(resultsDir: dir)
            await MainActor.run {
                groups = loaded
                isLoading = false
            }
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let accent: Color
    @State private var revealed = false
    @State private var hovering = false

    private func rowButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.address)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let salt = entry.salt {
                    Text(salt)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } else {
                    Text(entry.privateKey)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .blur(radius: revealed ? 0 : 5)
                        .onLongPressGesture(minimumDuration: 0.2, maximumDistance: 40) {
                        } onPressingChanged: { pressing in
                            withAnimation(.easeOut(duration: 0.15)) { revealed = pressing }
                        }
                }
            }
            Spacer()
            Text(entry.foundAt)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            HStack(spacing: 10) {
                rowButton("doc.on.doc", help: "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.address, forType: .string)
                }
                rowButton("doc.text", help: "Open") { NSWorkspace.shared.open(entry.fileURL) }
                rowButton("folder", help: "Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.fileURL]) }
            }
            .opacity(hovering ? 1 : 0.45)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(accent.opacity(hovering ? 0.35 : 0.12), lineWidth: 1)
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
