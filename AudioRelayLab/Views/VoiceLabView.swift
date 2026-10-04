import SwiftUI

struct VoiceLabView: View {
    @ObservedObject var coordinator: ExperimentCoordinator
    @State private var showComputerConnection = false
    var body: some View {
        NavigationStack {
            PaperScreen {
                RevoiceWorkshopHeader()
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

private struct RevoiceWorkshopHeader:View {
    var body:some View {
        HStack(alignment:.center,spacing:12) {
            VStack(alignment:.leading,spacing:4) {
                Text("声音工坊").font(.system(.title2,design:.serif)).tracking(1)
                Text("文字交给另一种声线").font(.caption).foregroundStyle(PaperTheme.secondary)
            }
            Spacer(minLength:4)
            Image(systemName:"mic").font(.title3).foregroundStyle(PaperTheme.secondary)
                .frame(width:40,height:40).overlay(Circle().stroke(PaperTheme.line,lineWidth:1))
                .accessibilityHidden(true)
        }.padding(.vertical,4)
    }
}
