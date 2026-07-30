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
            FloatingIcon()
            Text(session.isRunning ? session.t(.liveFeedRunning) : session.t(.liveFeedIdle))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FloatingIcon: View {
    @State private var floating = false

    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 30))
            .foregroundStyle(.tertiary)
            .shadow(color: .white.opacity(0.15), radius: 10)
            .offset(y: floating ? -5 : 5)
            .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: floating)
            .onAppear { floating = true }
    }
}
