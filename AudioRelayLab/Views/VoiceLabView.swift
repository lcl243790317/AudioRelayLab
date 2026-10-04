import SwiftUI

private enum WorkshopMode:String,Hashable { case revoice, mix }
private enum WorkshopSheet:String,Identifiable { case cloud, computer; var id:String { rawValue } }

struct VoiceLabView: View {
    @ObservedObject var coordinator: ExperimentCoordinator
    @State private var mode:WorkshopMode = ProcessInfo.processInfo.arguments.contains("mix-snapshot") ? .mix : .revoice
    @State private var sheet:WorkshopSheet?
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        NavigationStack {
            PaperScreen {
                if typeSize.isAccessibilitySize {
                    StablePicker(title:"工坊功能",selection:$mode,choices:[.init(id:.revoice,title:"配音"),.init(id:.mix,title:"混音")])
                } else {
                    Picker("工坊功能",selection:$mode) { Text("配音").tag(WorkshopMode.revoice); Text("混音").tag(WorkshopMode.mix) }
                        .pickerStyle(.segmented).accessibilityIdentifier("workshop.mode")
                }
                if mode == .revoice {
                    VoiceRevoiceView(coordinator:coordinator) { asset in
                        coordinator.voiceMix.voiceID = asset.id; mode = .mix
                    }
                } else { VoiceMixView(coordinator:coordinator) }
                NavigationLink("录音与已生成的声音") { VoiceRecordLibraryView(coordinator:coordinator) }
                    .font(.subheadline)
            }
            .navigationTitle("声音工坊").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.topBarTrailing) {
                    Menu {
                        Button("云端连接设置") { KeyboardDismiss.perform(); sheet = .cloud }
                            .disabled(coordinator.revoice.busy || coordinator.revoice.hasPendingJob || coordinator.rawRecorder.isActive)
                        Button("重新连接云端") { coordinator.revoice.connect() }
                            .disabled(!coordinator.revoice.configured || coordinator.revoice.connecting || coordinator.rawRecorder.isActive)
                        NavigationLink("高级：电脑变声") {
                            PaperScreen {
                                VoiceAIView(coordinator:coordinator) { KeyboardDismiss.perform(); sheet = .computer }
                            }.navigationTitle("电脑变声").navigationBarTitleDisplayMode(.inline)
                        }
                    } label: { Label("工具",systemImage:"ellipsis.circle") }
                    .accessibilityIdentifier("workshop.tools")
                }
                ToolbarItem(placement:.topBarTrailing) { ThemeToggleButton() }
            }
            .sheet(item:$sheet) { destination in
                switch destination {
                case .cloud: CloudConnectionView(ai:coordinator.revoice)
                case .computer: AIConnectionView(ai:coordinator.aiVoice)
                }
            }
        }
    }
}
