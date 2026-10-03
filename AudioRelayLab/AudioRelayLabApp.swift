import SwiftUI

@main struct AudioRelayLabApp: App {
    @StateObject private var coordinator = ExperimentCoordinator()
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = ProcessInfo.processInfo.arguments.contains("voice-snapshot") ? 1 : 0
    init() { PaperTheme.configure() }
    var body: some Scene {
        WindowGroup {
            TabView(selection:$selectedTab) {
                MainView(coordinator:coordinator).tabItem { Label("音频",systemImage:"music.note") }.tag(0)
                VoiceLabView(coordinator:coordinator).tabItem { Label("变声",systemImage:"mic") }.tag(1)
                LibraryHubView(coordinator:coordinator).tabItem { Label("资料",systemImage:"folder") }.tag(2)
            }
                .tint(PaperTheme.accent).preferredColorScheme(.light)
                .environment(\.locale, Locale(identifier: "zh_Hans_CN"))
                .onChange(of: scenePhase, initial: true) { _, phase in coordinator.sceneChanged(phase) }
        }
    }
}
