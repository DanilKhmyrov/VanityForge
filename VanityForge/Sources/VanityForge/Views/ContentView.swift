import SwiftUI

struct ContentView: View {
    @Environment(SessionViewModel.self) private var session
    @Environment(AppCatalog.self) private var catalog
    @State private var tab: Tab = .live

    enum Tab: CaseIterable, Hashable {
        case live, history

        func label(_ lang: AppLanguage) -> String {
            switch self {
            case .live: return L.tabSearch.s(lang)
            case .history: return L.tabHistory.s(lang)
            }
        }
    }

    var body: some View {
        ZStack {
            background

            HStack(spacing: 0) {
                NetworkPresetPicker()

                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 1)

                VStack(alignment: .leading, spacing: 18) {
                    TabSwitcher(tab: $tab)

                    switch tab {
                    case .live:
                        StatsDashboardView()
                        LiveFeedView()
                    case .history:
                        HistoryView()
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .overlay(alignment: .bottom) { errorBanner }
        .frame(minWidth: 1000, minHeight: 680)
        .task {
            if !catalog.isLoaded { await catalog.load(lang: session.language) }
            session.initializeWordsIfNeeded()
        }
    }

    @ViewBuilder
    private var background: some View {
        let accent = session.orderedNetworks.first.map(NetworkVisual.accent(for:)) ?? .accentColor
        if session.isRunning {
            // Живой "дышащий" фон, пока идёт поиск — лёгкая обратная связь,
            // что процесс активен. Таймер крутится только во время поиска,
            // чтобы не жечь CPU впустую, когда приложение просто открыто.
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let pulse = sin(t * 1.1) * 0.5 + 0.5
                backgroundLayers(accent: accent, pulse: pulse)
            }
        } else {
            backgroundLayers(accent: accent, pulse: 0.5)
                .animation(.easeInOut(duration: 0.6), value: accent)
        }
    }

    private func backgroundLayers(accent: Color, pulse: Double) -> some View {
        ZStack {
            Color(red: 0.06, green: 0.06, blue: 0.085)
            RadialGradient(
                colors: [accent.opacity(0.22 + pulse * 0.14), .clear],
                center: .topLeading,
                startRadius: 40,
                endRadius: 600 + pulse * 90
            )
            RadialGradient(
                colors: [Color.purple.opacity(0.08 + (1 - pulse) * 0.05), .clear],
                center: .bottomTrailing,
                startRadius: 60,
                endRadius: 700
            )
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let error = session.lastError {
            Text(error)
                .font(.system(size: 12))
                .padding(.horizontal, 14).padding(.vertical, 9)
                .elevatedGlass(accent: .red, cornerRadius: 10, intensity: 0.7)
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring, value: session.lastError)
        }
    }
}

private struct TabSwitcher: View {
    @Binding var tab: ContentView.Tab
    @Environment(SessionViewModel.self) private var session
    @Namespace private var pillNamespace

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ContentView.Tab.allCases, id: \.self) { t in
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { tab = t }
                } label: {
                    Text(t.label(session.language))
                        .font(.system(size: 12.5, weight: .medium))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background {
                            if tab == t {
                                Capsule()
                                    .fill(Color.white.opacity(0.12))
                                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
                                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                                    .matchedGeometryEffect(id: "tab-pill", in: pillNamespace)
                            }
                        }
                        .foregroundStyle(tab == t ? .primary : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.03)).overlay(Capsule().strokeBorder(Color.white.opacity(0.06), lineWidth: 1)))
    }
}
