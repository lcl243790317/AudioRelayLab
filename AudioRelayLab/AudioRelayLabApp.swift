import SwiftUI

@main struct AudioRelayLabApp: App {
    @StateObject private var coordinator = ExperimentCoordinator()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            TabView {
                MainView(coordinator: coordinator).tabItem { Label("Audio", systemImage: "waveform") }
                VoiceLabView(coordinator: coordinator, mixer: false).tabItem { Label("Voice Lab", systemImage: "mic") }
                VoiceLabView(coordinator: coordinator, mixer: true).tabItem { Label("Mixer", systemImage: "slider.horizontal.3") }
                NavigationStack { HistoryView(coordinator: coordinator) }.tabItem { Label("History", systemImage: "clock") }
                NavigationStack { DiagnosticsView(coordinator: coordinator) }.tabItem { Label("Diagnostics", systemImage: "doc.text") }
            }
                .environment(\.locale, Locale(identifier: "zh_Hans_CN"))
                .onChange(of: scenePhase, initial: true) { _, phase in coordinator.sceneChanged(phase) }
        }
    }
}
