import SwiftUI

@main struct AudioRelayLabApp: App {
    @UIApplicationDelegateAdaptor(RevoiceBackgroundAppDelegate.self) private var appDelegate
    @StateObject private var coordinator = ExperimentCoordinator()
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = ProcessInfo.processInfo.arguments.contains("voice-snapshot") || ProcessInfo.processInfo.arguments.contains("voice-custom-snapshot") || ProcessInfo.processInfo.arguments.contains("mix-snapshot") ? 1 : 0
    init() {
        if ProcessInfo.processInfo.arguments.contains("night-snapshot") {
            UserDefaults.standard.set(true,forKey:"appearance.nightMode")
        } else if ProcessInfo.processInfo.arguments.contains("day-snapshot") {
            UserDefaults.standard.set(false,forKey:"appearance.nightMode")
        }
        PaperTheme.configure()
    }
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("interaction-test") {
                InteractionTestScreen()
            } else { applicationContent }
            #else
            applicationContent
            #endif
        }
    }
    private var applicationContent:some View {
            TabView(selection:$selectedTab) {
                MainView(coordinator:coordinator).tabItem { Label("播放",systemImage:"music.note") }.tag(0)
                VoiceLabView(coordinator:coordinator).tabItem { Label("工坊",systemImage:"mic") }.tag(1)
                LibraryHubView(coordinator:coordinator).tabItem { Label("音频库",systemImage:"folder") }.tag(2)
            }
                .appAppearance()
                .buttonStyle(PaperButtonStyle(compact:true))
                .environment(\.locale, Locale(identifier: "zh_Hans_CN"))
                .onChange(of: scenePhase, initial: true) { _, phase in coordinator.sceneChanged(phase) }
    }
}
