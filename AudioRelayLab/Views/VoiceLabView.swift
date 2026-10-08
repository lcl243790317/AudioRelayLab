import SwiftUI

private enum WorkshopMode:String,Hashable { case revoice, mix }

struct VoiceLabView:View {
    @ObservedObject var coordinator:ExperimentCoordinator
    @State private var mode:WorkshopMode = ProcessInfo.processInfo.arguments.contains("mix-snapshot") ? .mix : .revoice
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var revoicePreviewOwner = UUID()
    @State private var mixPreviewOwner = UUID()
    var body:some View {
        NavigationStack {
            VStack(spacing:0) {
                Group {
                    if typeSize.isAccessibilitySize {
                    StablePicker(title:"工坊功能",selection:$mode,choices:[.init(id:.revoice,title:"配音"),.init(id:.mix,title:"混音")],beforeOpen:stopPreview)
                    } else {
                        Picker("工坊功能",selection:$mode) { Text("配音").tag(WorkshopMode.revoice); Text("混音").tag(WorkshopMode.mix) }
                            .pickerStyle(.segmented).accessibilityIdentifier("workshop.mode")
                    }
                }.padding(.horizontal,20).padding(.vertical,12)
                if mode == .revoice {
                    VoiceRevoiceView(coordinator:coordinator,previewOwner:revoicePreviewOwner) { asset in coordinator.voiceMix.voiceID = asset.id; mode = .mix }
                } else { PaperScreen { VoiceMixView(coordinator:coordinator,previewOwner:mixPreviewOwner) } }
            }.background(PaperTheme.background).foregroundStyle(PaperTheme.ink)
                .navigationTitle("声音工坊").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.topBarTrailing) { AppToolsMenu(coordinator:coordinator,beforePresentation:stopPreview) }
                    ToolbarItem(placement:.topBarTrailing) { ThemeToggleButton() }
                }
        }
        .onChange(of:mode) { previous,_ in
            coordinator.preview.stop(owner:previous == .revoice ? revoicePreviewOwner : mixPreviewOwner)
        }
        .onDisappear { stopPreview() }
    }
    private func stopPreview() { coordinator.preview.stop(owner:mode == .revoice ? revoicePreviewOwner : mixPreviewOwner) }
}
