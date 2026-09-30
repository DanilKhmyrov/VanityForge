import AppKit
import SwiftUI

struct LiveFeedView: View {
    @Environment(SessionViewModel.self) private var session

    var body: some View {
        Group {
            if session.foundItems.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    feedHeader
                    feedList
                }
            }
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
            Text(session.isRunning ? session.t(.liveFeedRunning) : session.t(session.searchMode == .contracts ? .liveFeedIdleContracts : .liveFeedIdle))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
