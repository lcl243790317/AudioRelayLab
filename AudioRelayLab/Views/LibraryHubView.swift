import SwiftUI

struct LibraryHubView: View {
    @ObservedObject var coordinator:ExperimentCoordinator
    private var version: String { Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "" }
    var body: some View {
        NavigationStack {
            PaperScreen {
                PaperHeader(title:"声音手记",subtitle:"保存声音，也保存每次尝试。",symbol:"folder")
                PaperCard {
                    NavigationLink { LocalAudioLibraryView(coordinator:coordinator) } label: {
                        Label("本地音频库",systemImage:"music.note.list")
                    }
                    Divider()
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
                PaperCaption("AudioRelayLab · \(version)\nAI 重新配音、手机实时处理与电脑变声，可以在同一套播放实验中回听。")
            }.navigationTitle("资料").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.topBarTrailing) { ThemeToggleButton() } }
        }
    }
}

struct VoiceRecordLibraryView: View {
    @ObservedObject var coordinator:ExperimentCoordinator
    var body: some View { LocalAudioLibraryView(coordinator:coordinator,recordingsOnly:true) }
}

struct LocalAudioLibraryView: View {
    @ObservedObject var coordinator:ExperimentCoordinator
    var recordingsOnly = false
    @State private var share:ShareItem?
    private var assets:[AudioAsset] {
        recordingsOnly ? coordinator.library.filter { [.voiceLabRecording,.mixedRecording,.aiConverted].contains($0.source) } : coordinator.library
    }
    private var locked: Bool { coordinator.controlsLocked || coordinator.aiVoice.connecting }
    var body: some View {
        List {
            Section {
                if assets.isEmpty { Text("录制、生成或导入声音后，会保存在这里。") }
                ForEach(assets) { asset in
                    VStack(alignment:.leading,spacing:12) {
                        HStack {
                            Text(asset.sourceTitle).font(.caption).foregroundStyle(PaperTheme.accent)
                            Spacer()
                            if coordinator.audio?.id == asset.id {
                                Label("当前",systemImage:"checkmark.circle.fill").font(.caption).foregroundStyle(PaperTheme.accent)
                            }
                        }
                        Text(asset.libraryName).font(.headline).lineLimit(3)
                        PaperCaption("\(AudioPlaybackSettings.time(asset.duration)) · \(asset.formatDescription)")
                        HStack {
                            Button("回听") { coordinator.audition(asset) }
                            Button("使用") { coordinator.selectLocal(asset) }
                            Button("分享") { if let url = try? AudioFileManager.url(for:asset) { share = ShareItem(url:url) } }
                        }.disabled(locked)
                        if let conversion = asset.aiConversion {
                            PaperCaption("\(conversion.voiceName) · \(conversion.modeTitle)")
                        }
                        if let revoice = asset.revoice {
                            PaperCaption("AI 重新配音 · \(revoice.generationMode == "custom" ? "自定义" : "固定预设")")
                            DisclosureGroup("配音文字") { Text(revoice.synthesisText).font(.callout).textSelection(.enabled) }
                        }
                    }.padding(.vertical,8)
                        .swipeActions(edge:.trailing,allowsFullSwipe:false) {
                            if asset.source != .bundled && !locked {
                                Button("删除",systemImage:"trash",role:.destructive) { coordinator.deleteAudio(asset) }
                                    .buttonStyle(.automatic)
                            }
                        }
                        .listRowBackground(PaperTheme.paper)
                }
            } footer: {
                Text("最新加入的声音在前。向左划动一行可删除。内置测试音始终保留；删除音频不会清空实验历史。")
            }
            if let error = coordinator.errorMessage { Text(error).foregroundStyle(.orange) }
        }.paperList()
            .buttonStyle(.borderless)
            .onAppear { coordinator.refreshLibrary() }
            .navigationTitle(recordingsOnly ? "录音与 AI 声音" : "本地音频库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("停止回听") { coordinator.preview.stop() } }
            .sheet(item:$share) { ShareSheet(url:$0.url) }
    }
}
