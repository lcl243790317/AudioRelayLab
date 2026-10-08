import SwiftUI

@main struct AudioRelayLabApp: App {
    @UIApplicationDelegateAdaptor(RevoiceBackgroundAppDelegate.self) private var appDelegate
    @StateObject private var coordinator = ExperimentCoordinator()
    @Environment(\.scenePhase) private var scenePhase
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
            ApplicationTabs(coordinator:coordinator,navigation:coordinator.navigation)
                .appAppearance()
                .buttonStyle(PaperButtonStyle(compact:true))
                .environment(\.locale, Locale(identifier: "zh_Hans_CN"))
                .onChange(of: scenePhase, initial: true) { _, phase in coordinator.sceneChanged(phase) }
    }
}
