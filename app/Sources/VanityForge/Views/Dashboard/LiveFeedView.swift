import AppKit
import SwiftUI

struct LiveFeedView: View {
    @Environment(SessionViewModel.self) private var session

    var body: some View {
        Group {
            if session.foundItems.isEmpty && session.bycatchItems.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    feedHeader
                    feedList
                }
            }
        }
    }

    private var idleText: String {
        if session.isRunning { return session.t(.liveFeedRunning) }
        switch session.searchMode {
        case .contracts: return session.t(.liveFeedIdleContracts)
        case .avatar: return session.t(.liveFeedIdleAvatar)
        case .wallets: return session.t(.liveFeedIdle)
        }
    }

    private var feedHeader: some View {
        HStack(spacing: 8) {
            Text(session.t(.feedTitle))
                .font(.system(size: 13, weight: .semibold))
            Text("\(session.foundItems.count)")
                .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.1)))
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.2), value: session.foundItems.count)
            Spacer()
            FeedButton(title: session.t(.openResultsFolder), icon: "folder") { openResultsFolder() }
            FeedButton(title: session.t(.clearFeed), icon: "xmark.bin") {
                withAnimation(.easeOut(duration: 0.2)) { session.clearFeed() }
            }
        }
    }

    private func openResultsFolder() {
        let dir = ResultsLocation.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    private var feedList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if !session.bycatchItems.isEmpty {
                    BycatchSection()
                }
                ForEach(session.foundItems) { item in
                    FoundCardView(event: item)
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity
                        ))
                }
            }
            .padding(.vertical, 4)
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: session.foundItems.map(\.id))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            FloatingIcon(active: session.isRunning)
            Text(idleText)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// «Попалось по пути»: свёрнуто — полоса с аватарками и тем, чем адрес красив;
/// развёрнуто — полные карточки (с ключом), как у обычных находок.
private struct BycatchSection: View {
    @Environment(SessionViewModel.self) private var session
    @State private var expanded = false
    private let gold = NetworkVisual.accent(for: "bycatch")

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { expanded.toggle() }
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles").foregroundStyle(gold)
                        Text(session.t(.bycatchTitle)).font(.system(size: 12.5, weight: .semibold))
                        Text("\(session.bycatchItems.count)")
                            .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(gold.opacity(0.18)))
                            .foregroundStyle(gold)
                            .contentTransition(.numericText())
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                            .foregroundStyle(.secondary)
                    }
                    if !expanded {
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(session.bycatchItems.prefix(12)) { item in chip(item) }
                            }
                        }
                        .scrollIndicators(.never)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(session.bycatchItems) { item in
                    FoundCardView(event: item)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(gold.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(gold.opacity(0.25), lineWidth: 1))
        )
    }

    private func chip(_ item: FoundEvent) -> some View {
        HStack(spacing: 7) {
            BlockieView(address: item.address, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(chipAddress(item))
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                Text(item.bycatch?.desc ?? "")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(gold)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Capsule().fill(Color.white.opacity(0.05)))
    }

    /// Короткий адрес, но так, чтобы красивая часть была видна целиком.
    private func chipAddress(_ item: FoundEvent) -> String {
        guard let info = item.bycatch else { return Format.shortAddress(item.address) }
        let n = info.length
        return info.position == "start"
            ? "0x\(item.address.dropFirst(2).prefix(n))…\(item.address.suffix(4))"
            : "\(item.address.prefix(6))…\(item.address.suffix(n))"
    }
}

/// Парит только во время поиска: бесконечная repeatForever-анимация из
/// onAppear перерисовывала окно 60 раз в секунду и в простое (10–20% CPU).
private struct FloatingIcon: View {
    let active: Bool

    var body: some View {
        if active {
            TimelineView(.animation) { timeline in
                icon(offset: sin(timeline.date.timeIntervalSinceReferenceDate * .pi / 1.8) * 5)
            }
        } else {
            icon(offset: 0)
        }
    }

    private func icon(offset: Double) -> some View {
        Image(systemName: "sparkles")
            .font(.system(size: 30))
            .foregroundStyle(.tertiary)
            .shadow(color: .white.opacity(0.15), radius: 10)
            .offset(y: offset)
    }
}

private struct FeedButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(hovering ? 0.12 : 0.05)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
