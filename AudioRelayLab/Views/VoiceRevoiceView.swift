import SwiftUI
import UniformTypeIdentifiers

struct VoiceRevoiceView: View {
    @ObservedObject var coordinator:ExperimentCoordinator
    @ObservedObject var ai:RevoiceController
    @ObservedObject var voice:RawVoiceRecorder
    @State private var showConnection = false
    @State private var showLibrary = false
    init(coordinator:ExperimentCoordinator) {
        self.coordinator = coordinator; ai = coordinator.revoice; voice = coordinator.rawRecorder
    }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Picker("配音方式",selection:$ai.kind) {
                Text("预设声线").tag(RevoiceController.Kind.preset)
                Text("自定义配音").tag(RevoiceController.Kind.custom)
            }.pickerStyle(.segmented).disabled(ai.busy || ai.hasPendingJob || voice.isActive)
            PaperCard(ai.kind == .preset ? "选择声线" : "自己设置声线与表达") {
                if ai.kind == .preset {
                    if !ai.voices.isEmpty {
                        StablePicker(title:"声线",selection:$ai.selectedPreset,
                            choices:ai.voices.map { .init(id:$0.id,title:$0.displayName) }).disabled(ai.busy || ai.hasPendingJob || voice.isActive)
                    }
                    PaperCaption("沿用已试听认可的固定声线。录完自动识别并配音，文字可以修改后重新生成。")
                } else {
                    StablePicker(title:"Speaker",selection:$ai.selectedSpeaker,
                        choices:(ai.speakers.isEmpty ? RevoiceSpeaker.all : ai.speakers).map { .init(id:$0.id,title:$0.displayName) }).disabled(ai.busy || ai.hasPendingJob || voice.isActive)
                    Text("Instruction · 表达指令").font(.subheadline)
                    TextField("例如：自然放松，语速稍慢，带一点慵懒",text:$ai.instruction,axis:.vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(2...5).disabled(ai.busy || ai.hasPendingJob || voice.isActive)
                    PaperCaption("\(ai.instruction.unicodeScalars.count)/500 字符 · 留空采用 speaker 的自然表达。")
                    PaperCaption("语音输入后先校对文字，再点击生成。可以自由改变表达指令，不改动前面的预设。")
                }
                DisclosureGroup(ai.configured ? "云端连接设置" : "首次使用：连接云端") {
                    Button(ai.configured ? "导入或更换连接配置" : "导入云端连接配置") { showConnection = true }
                        .disabled(ai.busy || ai.hasPendingJob || voice.isActive)
                    if ai.configured { Button("重新连接") { ai.connect() }.disabled(ai.busy || ai.hasPendingJob || voice.isActive) }
                    PaperCaption("电脑关机后仍可配音。录音在手机识别，云端只接收文字和声线参数。")
                }
                if !ai.configured { Button("设置云端连接") { showConnection = true }.buttonStyle(PaperButtonStyle(primary:true)) }
            }
            PaperCard("要说的话") {
                TextEditor(text:$ai.text).frame(minHeight:100,maxHeight:180).accessibilityIdentifier("revoice.text")
                    .scrollContentBackground(.hidden).padding(8)
                    .background(Color.secondary.opacity(0.06),in:RoundedRectangle(cornerRadius:10))
                    .disabled(ai.busy || ai.hasPendingJob || voice.isActive)
                PaperCaption("\(ai.text.unicodeScalars.count)/1,000 字符 · 保留原话，不自动润色。")
                if let input = ai.input {
                    Text(input.libraryName).font(.caption).lineLimit(2)
                    Button("重新识别这段录音") { ai.recognize() }.disabled(coordinator.controlsLocked)
                }
                if voice.isActive {
                    ProgressView(voice.status,value:Double(min(1,max(0,voice.inputLevel))))
                    Button("停止录音") { voice.stop() }.disabled(voice.state == .saving).buttonStyle(PaperButtonStyle(primary:true))
                } else {
                    HStack {
                        Button("语音输入") {
                            KeyboardDismiss.perform(); ai.selectInput(nil); voice.start(.revoice)
                        }.disabled(coordinator.controlsLocked)
                        Button("从库选择录音") { KeyboardDismiss.perform(); showLibrary = true }.disabled(coordinator.controlsLocked || coordinator.library.isEmpty)
                    }
                }
                PaperCaption("录音 0.3–60 秒；满 60 秒自动停止。成品由目标声线决定节奏，最长 180 秒。")
                if !voice.isActive {
                    Button(generateTitle) { KeyboardDismiss.perform(); ai.generate() }.buttonStyle(PaperButtonStyle(primary:true))
                        .disabled(coordinator.controlsLocked || (!ai.configured && !ai.text.isEmpty) || (ai.text.isEmpty && ai.input == nil))
                }
                if ai.busy {
                    ProgressView(ai.status)
                    Button("停止等待") { ai.cancel() }
                    PaperCaption("已提交的云端任务可能继续完成；停止等待后不会保存迟到的成品。")
                } else {
                    PaperCaption(ai.status)
                    if ai.hasPendingJob {
                        Button("取回未完成配音") { KeyboardDismiss.perform(); ai.resumePending() }
                        Button("停止等待") { ai.cancel() }
                    }
                }
                if let error = ai.errorMessage { Text(error).font(.callout).foregroundStyle(.orange) }
                if let error = voice.errorMessage { Text(error).font(.callout).foregroundStyle(.orange) }
            }
            if let result = ai.result { RevoiceResultTools(coordinator:coordinator,result:result) }
        }
        .keyboardDone()
        .sheet(isPresented:$showConnection) { CloudConnectionView(ai:ai) }
        .sheet(isPresented:$showLibrary) {
            NavigationStack {
                AudioLibraryPickerView(coordinator:coordinator) { asset in ai.selectInput(asset); showLibrary = false }
            }
        }
        .task { if ai.configured && ai.voices.isEmpty && !ai.busy { ai.connect() } }
    }
    private var generateTitle:String {
        if ai.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && ai.input != nil {
            return ai.kind == .preset ? "识别并生成配音" : "识别录音文字"
        }
        return "生成配音"
    }
}

struct CloudConnectionView:View {
    @ObservedObject var ai:RevoiceController
    @Environment(\.dismiss) private var dismiss
    @State private var configuration = ""
    @State private var importFile = false
    @State private var fileError:String?
    var body:some View {
        NavigationStack {
            PaperScreen {
                PaperHeader(title:"连接云端",subtitle:"一次设置，随时重新配音。",symbol:"cloud")
                PaperCard("导入连接配置") {
                    PaperCaption("导入电脑上的 modal-client.json，或复制其中的完整 JSON。配置包含你的私有密钥，请只保存在自己的设备上。")
                    Button("从文件导入") { KeyboardDismiss.perform(); importFile = true }.disabled(ai.busy)
                    SecureField("粘贴完整连接 JSON",text:$configuration)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder).disabled(ai.busy)
                        .submitLabel(.done).onSubmit { KeyboardDismiss.perform() }
                    Button("保存并连接") {
                        KeyboardDismiss.perform(); ai.configure(Data(configuration.utf8)); configuration = ""; fileError = nil
                    }.buttonStyle(PaperButtonStyle(primary:true)).disabled(ai.busy || configuration.isEmpty)
                    if ai.connecting { ProgressView("正在连接云端…") }
                    PaperCaption(ai.status)
                    if let warning = ai.connectionWarning { Text(warning).font(.caption).foregroundStyle(.orange) }
                    if let error = ai.errorMessage ?? fileError { Text(error).font(.callout).foregroundStyle(.orange) }
                    PaperCaption("连接配置保存在本机钥匙串。重新签名、重装或更换密钥后，可以再次导入。")
                }
            }.keyboardDone().navigationTitle("云端连接").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("完成") { configuration = ""; dismiss() } }
        }
        .sheet(isPresented:$importFile) {
            JSONDocumentPicker(onSelection: { url in
                defer { JSONImportFile.removePickerCopy(url); importFile = false }
                do { ai.configure(try JSONImportFile.read(url,maximumBytes:8192)); fileError = nil }
                catch { fileError = "无法读取有效的连接 JSON（最大 8 KiB），请下载到手机后重新导入" }
            }, onCancel: { importFile = false })
        }
        .onDisappear { configuration = "" }
    }
}

struct RevoiceResultTools:View {
    @ObservedObject var coordinator:ExperimentCoordinator
    @ObservedObject var volumes:MixVolumeSettings
    let result:AudioAsset
    @State private var share:ShareItem?
    @State private var backgroundID:UUID?
    @State private var mixing = false
    @State private var mixStatus = ""
    init(coordinator:ExperimentCoordinator,result:AudioAsset) {
        self.coordinator = coordinator; self.result = result; volumes = coordinator.mixVolumes
    }
    var body:some View {
        PaperCard("配音成品") {
            Text(result.libraryName).font(.headline)
            if let metadata = result.revoice { PaperCaption("配音计算 \(String(format:"%.1f",metadata.generationSeconds)) 秒 · 成品 \(AudioPlaybackSettings.time(result.duration))") }
            HStack {
                Button("回听") { coordinator.audition(result) }
                Button("用于延迟播放") { coordinator.selectLocal(result) }
            }.disabled(coordinator.controlsLocked)
            HStack {
                Button("分享成品") { if let url = try? AudioFileManager.url(for:result) { share = ShareItem(url:url) } }
                    .disabled(coordinator.controlsLocked)
                Button("停止回听") { coordinator.preview.stop() }
            }
            DisclosureGroup("加入背景音乐并保存") {
                StablePicker(title:"背景音乐",selection:$backgroundID,
                    choices:[.init(id:nil,title:"请选择音乐")] + coordinator.library.filter { $0.id != result.id }.map { .init(id:Optional($0.id),title:$0.fileName) }).disabled(coordinator.controlsLocked)
                volume("人声",value:$volumes.voice)
                volume("音乐",value:$volumes.music)
                PaperCaption("使用完整成品时长；音乐默认 4%。")
                Button(mixing ? "保存中…" : "保存混合音频") { mix() }
                    .disabled(coordinator.controlsLocked || backgroundID == nil || mixing)
                if !mixStatus.isEmpty { PaperCaption(mixStatus) }
            }
        }.sheet(item:$share) { ShareSheet(url:$0.url) }
    }
    private func volume(_ label:String,value:Binding<Float>) -> some View {
        VStack(alignment:.leading) {
            Text("\(label) \(Int(boundedVolume(value.wrappedValue)*100))%").font(.subheadline)
            Slider(value:Binding(get:{Double(boundedVolume(value.wrappedValue))},set:{value.wrappedValue = boundedVolume(Float($0))}),in:0...1)
                .disabled(coordinator.controlsLocked)
        }
    }
    private func boundedVolume(_ value:Float) -> Float { value.isFinite ? min(1,max(0,value)) : 0 }
    private func mix() {
        guard let music = coordinator.library.first(where:{$0.id == backgroundID}) else { return }
        do { try coordinator.beginMixing() } catch { mixStatus = userFacingAudioError(error); return }
        mixing = true; coordinator.preview.stop()
        let volumes = self.volumes.parameters
        let settings = music.id == coordinator.audio?.id ? coordinator.applied : AudioPlaybackSettings()
        Task {
            defer { mixing = false; coordinator.endMixing() }
            do {
                let voiceURL = try AudioFileManager.url(for:result), musicURL = try AudioFileManager.url(for:music)
                _ = try await Task.detached { try RecordedVoiceMixer.mix(voiceURL:voiceURL,musicURL:musicURL,settings:settings,volumes:volumes,voiceAsset:result,musicAsset:music) }.value
                coordinator.refreshLibrary(); mixStatus = "已保存，可以在录音库回听。"
            } catch { mixStatus = userFacingAudioError(error) }
        }
    }
}
