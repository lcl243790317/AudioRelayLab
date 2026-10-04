import SwiftUI

@main struct AudioRelayLabApp: App {
    @UIApplicationDelegateAdaptor(RevoiceBackgroundAppDelegate.self) private var appDelegate
    @StateObject private var coordinator = ExperimentCoordinator()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance.nightMode") private var nightMode = false
    @State private var selectedTab = ProcessInfo.processInfo.arguments.contains("voice-snapshot") || ProcessInfo.processInfo.arguments.contains("voice-custom-snapshot") ? 1 : 0
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
                MainView(coordinator:coordinator).tabItem { Label("音频",systemImage:"music.note") }.tag(0)
                VoiceLabView(coordinator:coordinator).tabItem { Label("配音",systemImage:"mic") }.tag(1)
                LibraryHubView(coordinator:coordinator).tabItem { Label("资料",systemImage:"folder") }.tag(2)
            }
                .tint(PaperTheme.accent)
                .preferredColorScheme(nightMode ? .dark : .light)
                .transformEnvironment(\.dynamicTypeSize) { size in
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("voice-large-type") { size = .accessibility3 }
                    #endif
                }
                .buttonStyle(PaperButtonStyle(compact:true))
                .environment(\.locale, Locale(identifier: "zh_Hans_CN"))
                .onChange(of: scenePhase, initial: true) { _, phase in coordinator.sceneChanged(phase) }
    }
}
