import SwiftUI

struct AppToolsMenu:View {
    @ObservedObject var coordinator:ExperimentCoordinator
    var beforePresentation:(()->Void)? = nil
    @State private var cloud = false
    @State private var computer = false
    var body:some View {
        Menu {
            Button("云端连接设置") { beforePresentation?(); KeyboardDismiss.perform(); cloud = true }
                .disabled(coordinator.revoice.busy || coordinator.revoice.hasPendingJob || coordinator.rawRecorder.isActive)
            Button("重新连接云端") { coordinator.revoice.connect() }
                .disabled(!coordinator.revoice.configured || coordinator.revoice.connecting || coordinator.rawRecorder.isActive)
            NavigationLink("电脑变声") {
                PaperScreen { VoiceAIView(coordinator:coordinator) { beforePresentation?(); computer = true } }
                    .navigationTitle("电脑变声").navigationBarTitleDisplayMode(.inline)
            }
            NavigationLink("实验历史") { HistoryView(coordinator:coordinator) }
            NavigationLink("诊断与日志") { DiagnosticsView(coordinator:coordinator) }
        } label: { Label("工具",systemImage:"ellipsis.circle") }
        .accessibilityIdentifier("workshop.tools")
        .sheet(isPresented:$cloud) { CloudConnectionView(ai:coordinator.revoice) }
        .sheet(isPresented:$computer) { AIConnectionView(ai:coordinator.aiVoice) }
    }
}
