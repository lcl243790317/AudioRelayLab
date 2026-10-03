import SwiftUI

struct LibraryHubView: View {
    @ObservedObject var coordinator:ExperimentCoordinator
    var body: some View {
        NavigationStack {
            PaperScreen {
                PaperHeader(title:"声音手记",subtitle:"保存声音，也保存每次尝试。",symbol:"folder")
                PaperCard {
                    NavigationLink { VoiceRecordLibraryView(coordinator:coordinator) } label: {
                        Label("录音与 AI 声音",systemImage:"waveform")
                    }
                    Divider()
                    NavigationLink { HistoryView(coordinator:coordinator) } label: {
                        Label("实验历史",systemImage:"clock")
                    }
                    Divider()
                    NavigationLink { DiagnosticsView(coordinator:coordinator) } label: {
                        Label("诊断与日志",systemImage:"doc.text")
                    }
                }
                PaperCaption("AudioRelayLab · 1.3.0\n手机实时处理与电脑 AI 转换，可在同一套播放实验中回听。")
            }.navigationTitle("资料").navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct VoiceRecordLibraryView: View {
    @ObservedObject var coordinator:ExperimentCoordinator
    @ObservedObject var voice:VoiceProcessingEngine
    @State private var share:ShareItem?
    init(coordinator:ExperimentCoordinator) { self.coordinator = coordinator; voice = coordinator.voiceLab }
    private var assets:[AudioAsset] {
        coordinator.library.filter { [AudioSource.voiceLabRecording,.mixedRecording,.aiConverted].contains($0.source) }
    }
    var body: some View {
        PaperScreen {
            if assets.isEmpty { PaperCard { Text("录制或生成声音后，会保存在这里。") } }
            ForEach(assets) { asset in
                PaperCard {
                    Text(asset.fileName).font(.headline).lineLimit(2)
                    PaperCaption("\(AudioPlaybackSettings.time(asset.duration)) · \(asset.formatDescription)")
                    HStack {
                        Button("回听") { coordinator.selectLocal(asset); coordinator.audition() }
                        Button("应用到音频页") { coordinator.selectLocal(asset) }
                    }.disabled(coordinator.controlsLocked)
                    DisclosureGroup("分享与管理") {
                        Button("分享音频") {
                            if let url = try? AudioFileManager.url(for:asset) { share = ShareItem(url:url) }
                        }
                        if let conversion = asset.aiConversion {
                            PaperCaption("\(conversion.engine) · \(conversion.voiceName)\n\(conversion.referenceOrigin)")
                        }
                        Button("删除",role:.destructive) {
                            coordinator.preview.stop()
                            if coordinator.audio?.id == asset.id { coordinator.useTestAudio() }
                            if let record = voice.recordings.first(where:{$0.asset.id == asset.id}) { voice.delete(record) }
                            else { try? AudioFileManager.removeAudio(asset) }
                            coordinator.refreshLibrary()
                        }.disabled(coordinator.controlsLocked)
                    }
                }
            }
            Button("停止回听") { coordinator.preview.stop() }
        }.navigationTitle("录音与 AI 声音").navigationBarTitleDisplayMode(.inline)
            .buttonStyle(PaperButtonStyle())
            .sheet(item:$share) { ShareSheet(url:$0.url) }
    }
}
