import SwiftUI

struct LiveFeedView: View {
    @Environment(SessionViewModel.self) private var session

    var body: some View {
        Group {
            if session.foundItems.isEmpty {
                emptyState
            } else {
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
        }
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
