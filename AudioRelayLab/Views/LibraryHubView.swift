import SwiftUI

struct LibraryHubView:View {
    @ObservedObject var coordinator:ExperimentCoordinator
    var body:some View {
        NavigationStack { LocalAudioLibraryView(coordinator:coordinator,showsScope:true) }
    }
}

struct VoiceRecordLibraryView: View {
    @ObservedObject var coordinator:ExperimentCoordinator
    var body: some View { LocalAudioLibraryView(coordinator:coordinator,recordingsOnly:true) }
}

struct LocalAudioLibraryView: View {
    @ObservedObject var coordinator:ExperimentCoordinator
    var recordingsOnly = false
    var showsScope = false
    @State private var scopeRecordings = false
    @State private var selecting = false
    @State private var selectedIDs:Set<UUID> = []
    @State private var pendingDeletion:[AudioAsset] = []
    @State private var confirmingDeletion = false
    @State private var deletionSummary:String?
    @State private var deletionDetails:[String] = []
    private var isRecordings:Bool { showsScope ? scopeRecordings : recordingsOnly }
    private var eligibleIDs:Set<UUID> { Set(assets.filter { $0.source != .bundled }.map(\.id)) }

    @State private var share:ShareItem?
    @State private var previewOwner = UUID()
    private var assets:[AudioAsset] {
        isRecordings ? coordinator.library.filter { [.voiceLabRecording,.mixedRecording,.aiConverted].contains($0.source) } : coordinator.library
    }
    private var locked: Bool { coordinator.controlsLocked || coordinator.aiVoice.connecting }
    var body: some View {
        List {
            if showsScope {
                Picker("音频库分类",selection:$scopeRecordings) {
                    Text("本地音频").tag(false); Text("录音与 AI").tag(true)
                }.pickerStyle(.segmented).accessibilityIdentifier("library.scope")
                    .listRowBackground(PaperTheme.background)
            }
            if let deletionSummary { Text(deletionSummary).font(.callout).accessibilityIdentifier("library.delete.summary") }
            ForEach(Array(deletionDetails.enumerated()),id:\.offset) { _,detail in Text(detail).font(.callout) }
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
                        HStack(spacing:12) {
                            if selecting {
                                Button {
                                    if selectedIDs.contains(asset.id) { selectedIDs.remove(asset.id) } else { selectedIDs.insert(asset.id) }
                                } label: { Image(systemName:selectedIDs.contains(asset.id) ? "checkmark.circle.fill" : "circle").font(.title3) }
                                    .buttonStyle(PaperButtonStyle(compact:true)).disabled(asset.source == .bundled || locked)
                                    .accessibilityLabel("选择 " + asset.libraryName)
                                    .accessibilityValue(selectedIDs.contains(asset.id) ? "已选择" : "未选择")
                                    .accessibilityIdentifier("library.select.\(asset.id.uuidString)")
                            }
                            Text(asset.libraryName).font(.headline).lineLimit(3)
                        }
                        PaperCaption("\(AudioPlaybackSettings.time(asset.duration)) · \(asset.formatDescription)")
                        if !selecting { HStack {
                            Button("回听") { coordinator.audition(asset,owner:previewOwner) }
                            Button("使用") { coordinator.selectLocal(asset) }
                            Button("分享") {
                                coordinator.preview.stop(owner:previewOwner)
                                if let url = try? AudioFileManager.url(for:asset) { share = ShareItem(url:url) }
                            }
                        }.buttonStyle(PaperButtonStyle(compact:true)).disabled(locked) }
                        if let conversion = asset.aiConversion {
                            PaperCaption("\(conversion.voiceName) · \(conversion.modeTitle)")
                        }
                        if let revoice = asset.revoice {
                            PaperCaption("AI 重新配音 · \(revoice.generationMode == "custom" ? "自定义" : "固定预设")")
                            DisclosureGroup("配音详情") {
                                Text(revoice.synthesisText).font(.callout).textSelection(.enabled)
                                PaperCaption("声线：\(revoice.voiceName ?? revoice.voiceID)\nSpeaker：\(revoice.speakerID ?? "固定参考")")
                                if let reference = revoice.fixedReferenceID { PaperCaption("参考身份：\(reference)") }
                                Text("Instruction：\((revoice.instruction ?? "").isEmpty ? "自然表达" : (revoice.instruction ?? ""))")
                                    .font(.callout).textSelection(.enabled)
                            }
                        }
                        if let source = asset.mixSource {
                            DisclosureGroup("混音来源") {
                                PaperCaption("人声：\(source.voiceAssetID.uuidString)\n音乐：\(source.musicAssetID.uuidString)")
                                PaperCaption("人声音量 \(source.volumes.voice) · 音乐音量 \(source.volumes.music) · 总音量 \(source.volumes.master)")
                            }
                        }
                    }.padding(.vertical,8)
                        .swipeActions(edge:.trailing,allowsFullSwipe:false) {
                            if asset.source != .bundled && !locked && !selecting {
                                Button("删除",systemImage:"trash",role:.destructive) { pendingDeletion = [asset]; confirmingDeletion = true }
                                    .buttonStyle(.automatic)
                            }
                        }
                        .listRowBackground(PaperTheme.paper)
                }
            } footer: {
                Text("最新加入的声音在前。可选择多项删除，也可向左划动删除单项。内置测试音始终保留；删除音频不会清空实验历史。")
            }
            if let error = coordinator.errorMessage,error != deletionSummary { Text(error).foregroundStyle(.orange) }
        }.paperList()
            .onAppear { coordinator.refreshLibrary() }
            .onDisappear { coordinator.preview.stop(owner:previewOwner) }
            .navigationTitle(showsScope ? "音频库" : (isRecordings ? "录音与 AI 声音" : "本地音频库"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.topBarLeading) {
                    Button(selecting ? "取消选择" : "选择") {
                        coordinator.preview.stop(owner:previewOwner); selecting.toggle(); selectedIDs = []
                    }.disabled(locked || eligibleIDs.isEmpty).accessibilityIdentifier("library.selection")
                }
                ToolbarItem(placement:.topBarTrailing) {
                    if selecting {
                        Button(selectedIDs == eligibleIDs ? "取消全选" : "全选") { selectedIDs = selectedIDs == eligibleIDs ? [] : eligibleIDs }
                            .disabled(locked).accessibilityIdentifier("library.selectAll")
                    } else { LibraryPreviewStopButton(preview:coordinator.preview) }
                }
                ToolbarItem(placement:.topBarTrailing) { AppToolsMenu(coordinator:coordinator) }
                ToolbarItem(placement:.topBarTrailing) { ThemeToggleButton() }
            }
            .onChange(of:scopeRecordings) { _,_ in
                coordinator.preview.stop(owner:previewOwner); selectedIDs = []; selecting = false
            }
            .onChange(of:coordinator.library.map(\.id)) { _,_ in selectedIDs.formIntersection(eligibleIDs) }
            .safeAreaInset(edge:.bottom) {
                if selecting {
                    Button("删除所选（\(selectedIDs.count)）",role:.destructive) {
                        pendingDeletion = assets.filter { selectedIDs.contains($0.id) }; confirmingDeletion = true
                    }.buttonStyle(PaperButtonStyle()).disabled(locked || selectedIDs.isEmpty)
                        .accessibilityIdentifier("library.delete.selected")
                        .padding(16).background(PaperTheme.paper)
                }
            }
            .sheet(isPresented:$confirmingDeletion) {
                NavigationStack {
                    List {
                        Section {
                            Text("将永久删除 \(pendingDeletion.count) 项音频及其附属文件，无法撤销。实验历史会保留。")
                        }
                        ForEach(pendingDeletion) { asset in Text(asset.libraryName).font(.body) }
                    }.paperList().navigationTitle("确认删除")
                        .toolbar {
                            ToolbarItem(placement:.cancellationAction) { Button("取消") { confirmingDeletion = false } }
                            ToolbarItem(placement:.confirmationAction) {
                                Button("删除 \(pendingDeletion.count) 项",role:.destructive) {
                                    let result = coordinator.deleteAudio(ids:Set(pendingDeletion.map(\.id)))
                                    deletionSummary = result.summary; selectedIDs = Set(result.failures.keys).intersection(eligibleIDs)
                                    deletionDetails = pendingDeletion.compactMap { asset in result.failures[asset.id].map { asset.libraryName+"："+$0 } } + result.cleanupWarnings
                                    selecting = !selectedIDs.isEmpty; confirmingDeletion = false
                                }.disabled(locked).accessibilityIdentifier("library.delete.confirm")
                            }
                        }
                }
            }
            .sheet(item:$share) { ShareSheet(url:$0.url) }
    }
}

private struct LibraryPreviewStopButton: View {
    @ObservedObject var preview:PreviewPlaybackController
    var body: some View {
        Button("停止回听") { preview.stop() }
            .disabled(!preview.isActive)
            .accessibilityIdentifier("library.preview.stop")
            .accessibilityValue(preview.state == .playing ? "正在回听" : "未在回听")
    }
}
