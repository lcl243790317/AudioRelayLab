import SwiftUI

struct VoiceLabView: View {
    @ObservedObject var coordinator: ExperimentCoordinator
    @State private var showComputerConnection = false
    var body: some View {
        NavigationStack {
            PaperScreen {
                PaperHeader(title:"声音工坊",subtitle:"文字交给另一种声线。",symbol:"mic")
                VoiceRevoiceView(coordinator:coordinator)
                DisclosureGroup("高级：电脑变声") {
                    VoiceAIView(coordinator:coordinator) { KeyboardDismiss.perform(); showComputerConnection = true }
                }
                PaperCard {
                    NavigationLink("录音与已生成的声音") { VoiceRecordLibraryView(coordinator:coordinator) }
                    PaperCaption("原声、配音和混音会自动保存，最新加入的声音在前。")
                }
            }
            .navigationTitle("AI 重新配音").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.topBarTrailing) { ThemeToggleButton() } }
            .sheet(isPresented:$showComputerConnection) { AIConnectionView(ai:coordinator.aiVoice) }
        }
    }
}
