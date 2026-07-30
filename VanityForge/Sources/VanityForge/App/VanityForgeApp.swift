import SwiftUI

@main
struct VanityForgeApp: App {
    @State private var catalog = AppCatalog()
    @State private var session: SessionViewModel
    @State private var systemMonitor = SystemMonitor()

    init() {
        let catalog = AppCatalog()
        _catalog = State(initialValue: catalog)
        _session = State(initialValue: SessionViewModel(catalog: catalog))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(catalog)
                .environment(session)
                .environment(systemMonitor)
                .preferredColorScheme(.dark)
                .task { await catalog.load() }
                .task { systemMonitor.start() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 1180, height: 860)
    }
}
