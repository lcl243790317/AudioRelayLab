import SwiftUI

struct VoiceAIView: View {
    @ObservedObject var coordinator: ExperimentCoordinator
    @ObservedObject var ai: AIConversionController
    @ObservedObject var voice: RawVoiceRecorder
    @ObservedObject var volumes: MixVolumeSettings
    let showConnection: () -> Void
    @State private var showLibrary = false
    @State private var useAppliedRange = false
    @State private var share: ShareItem?
    @State private var backgroundID: UUID?
    @State private var mixing = false
    @State private var mixStatus = ""
    init(coordinator: ExperimentCoordinator, showConnection: @escaping () -> Void) {
        self.coordinator = coordinator; ai = coordinator.aiVoice; voice = coordinator.rawRecorder; volumes = coordinator.mixVolumes
        self.showConnection = showConnection
    }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            PaperCard("目标音色") {
                if ai.voices.isEmpty {
                    PaperCaption("先连接同一网络的电脑，再选择真实参考音色。")
                    Button("连接我的电脑") { showConnection() }.buttonStyle(PaperButtonStyle(primary:true))
                } else {
                    StablePicker(title:"音色",selection:$ai.selectedVoice,choices:ai.voices.map { .init(id:$0.id,title:$0.name) }).disabled(ai.busy || voice.isActive)
                    DisclosureGroup("高级转换设置") {
                    StablePicker(title:"表达与转换方式",selection:$ai.mode,choices:ai.availableModes.map { .init(id:$0,title:$0.title) }).disabled(ai.busy || voice.isActive)
                    PaperCaption(ai.mode.explanation)

                        Toggle("自定义参数",isOn:$ai.customSettings).disabled(ai.busy || voice.isActive)
                        if ai.customSettings {
                            Text("生成步数 \(Int(ai.diffusionSteps))").font(.subheadline)
                            Slider(value:$ai.diffusionSteps,in:20...80,step:1)
                            if ai.mode.isV2 {
                                Text("咬字清晰度 \(Int(ai.clarity*100))%").font(.subheadline)
                                Slider(value:$ai.clarity,in:0...1,step:0.05)
                                Text("目标音色相似度 \(Int(ai.similarity*100))%").font(.subheadline)
                                Slider(value:$ai.similarity,in:0...1,step:0.05)
                            }
                            if ai.mode == .preserveProsody {
                                Text(String(format:"目标音高微调 %+.1f 半音",ai.pitchShift)).font(.subheadline)
                                Slider(value:$ai.pitchShift,in:-6...6,step:0.5)
                            }
                        }
                        PaperCaption("关闭自定义即采用电脑已调校参数。切换模型首次生成会重新加载，步数越高等待越久。")
                    }.disabled(ai.busy || voice.isActive)
                    DisclosureGroup("音色来源与电脑连接") {
                        if let selected = ai.voices.first(where:{$0.id == ai.selectedVoice}) {
                            PaperCaption(selected.referenceOrigin)
                        }
                        Button("查看连接设置") { showConnection() }.disabled(ai.busy)
                    }
                }
                PaperCaption("建议先测试自然说话；要精确保留口气可选严格保留语调。自然度取决于原声与参考音色。")
            }
            PaperCard("一段纯人声") {
                Text(ai.input?.libraryName ?? "尚未录制或选择人声").font(.headline).lineLimit(2)
                if voice.isActive {
                    ProgressView("正在录原声",value:Double(min(1,max(0,voice.inputLevel))))
                    PaperCaption(voice.status)
                    Button("停止并保留原声") { voice.stop() }.buttonStyle(PaperButtonStyle(primary:true))
                } else {
                    HStack {
                        Button("录制原声") {
                            ai.selectInput(nil)
                            useAppliedRange = false
                            KeyboardDismiss.perform(); voice.start(.computerConversion)
                        }.disabled(coordinator.controlsLocked || ai.connecting)
                        Button("从音频库选择") { KeyboardDismiss.perform(); showLibrary = true }
                            .disabled(coordinator.controlsLocked || ai.connecting || coordinator.library.isEmpty)
                    }
                }
                PaperCaption("每段 0.3–60 秒；录满 60 秒自动保存。请在安静环境正常说话。")
                if useAppliedRange && ai.input?.id == coordinator.audio?.id {
                    PaperCaption("转换范围沿用音频页已应用的起点、终点和限制时长。")
                }
                DisclosureGroup("使用音频页的区间") {
                    Button("使用当前音频及已应用区间") {
                        ai.selectInput(coordinator.audio); useAppliedRange = true
                    }.disabled(coordinator.controlsLocked || ai.connecting || coordinator.audio == nil)
                    PaperCaption("从库直接选择默认转换全段；长音频可先在音频页截取至 60 秒内。")
                }
                Button("生成 AI 声音") {
                    KeyboardDismiss.perform()
                    let selected = useAppliedRange && ai.input?.id == coordinator.audio?.id
                    ai.convert(start:selected ? coordinator.applied.startOffset : 0,
                               limit:selected ? coordinator.applied.sourceLimit(duration:coordinator.audio?.duration ?? 0,requested:coordinator.requestedDuration) : nil)
                }.buttonStyle(PaperButtonStyle(primary:true))
                    .disabled(coordinator.controlsLocked || ai.connecting || ai.input == nil || ai.voices.isEmpty)
                if ai.busy {
                    ProgressView(ai.status)
                    Button("取消生成") { ai.cancel() }
                } else { PaperCaption(ai.status) }
                if let error = ai.errorMessage { Text(error).font(.callout).foregroundStyle(.orange) }
                if let error = voice.errorMessage { Text(error).font(.callout).foregroundStyle(.orange) }
                if let result = ai.result {
                    Divider()
                    Text(result.libraryName).font(.headline)
                    HStack {
                        Button("回听") { coordinator.audition(result) }
                        Button("用于延迟播放") { coordinator.selectLocal(result) }
                    }.disabled(coordinator.controlsLocked)
                    Button("分享成品") {
                        if let url = try? AudioFileManager.url(for:result) { share = ShareItem(url:url) }
                    }.disabled(coordinator.controlsLocked)
                    Button("停止回听") { coordinator.preview.stop() }
                    DisclosureGroup("加入背景音乐并保存") {
                        StablePicker(title:"背景音乐",selection:$backgroundID,
                            choices:[.init(id:nil,title:"请选择音乐")] + coordinator.library.filter { $0.id != result.id }.map { .init(id:Optional($0.id),title:$0.fileName) }).disabled(mixing || coordinator.controlsLocked)
                        volume("人声",value:$volumes.voice)
                        volume("音乐",value:$volumes.music)
                        PaperCaption("使用完整 AI 人声；背景音乐从头以原速加入。音乐默认 4%。")
                        Button(mixing ? "正在保存混音…" : "保存混合音频") { mix(result) }
                            .disabled(mixing || coordinator.controlsLocked || backgroundID == nil)
                        if !mixStatus.isEmpty { PaperCaption(mixStatus) }
                    }
                }
            }
        }
        .keyboardDone()
        .sheet(isPresented:$showLibrary) {
            NavigationStack {
                AudioLibraryPickerView(coordinator:coordinator) { asset in
                    ai.selectInput(asset); useAppliedRange = false; showLibrary = false
                }
            }
        }
        .sheet(item:$share) { ShareSheet(url:$0.url) }
    }
    private func volume(_ title:String,value:Binding<Float>) -> some View {
        VStack(alignment:.leading) {
            Text("\(title) \(percent(value.wrappedValue))").font(.subheadline)
            Slider(value:Binding(get:{ bounded(value.wrappedValue) },set:{ value.wrappedValue = Float($0) }),in:0...1)
        }
    }
    private func mix(_ result:AudioAsset) {
        guard let music = coordinator.library.first(where:{$0.id == backgroundID}) else { return }
        do { try coordinator.beginMixing() }
        catch { mixStatus = userFacingAudioError(error); return }
        mixing = true; coordinator.preview.stop()
        let volumes = self.volumes.parameters
        Task {
            defer { mixing = false; coordinator.endMixing() }
            do {
                let voiceURL = try AudioFileManager.url(for:result), musicURL = try AudioFileManager.url(for:music)
                let settings = music.id == coordinator.audio?.id ? coordinator.applied : AudioPlaybackSettings()
                _ = try await Task.detached { try RecordedVoiceMixer.mix(voiceURL:voiceURL,musicURL:musicURL,settings:settings,volumes:volumes,voiceAsset:result,musicAsset:music) }.value
                coordinator.refreshLibrary(); mixStatus = "已保存，可在录音库回听或应用。"
            } catch { mixStatus = userFacingAudioError(error) }
        }
    }
    private func bounded(_ value:Float) -> Double { value.isFinite ? Double(min(1,max(0,value))) : 0 }
    private func percent(_ value:Float) -> String { "\(Int(bounded(value)*100))%" }
}

struct AIConnectionView: View {
    @FocusState private var focusedInput:String?
    @ObservedObject var ai:AIConversionController
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            PaperScreen {
                PaperHeader(title:"连接电脑",subtitle:"手机录音，电脑生成。",symbol:"desktopcomputer")
                PaperCard("一次设置") {
                    PaperCaption("电脑运行 server/run.ps1，在 server/CONNECTION-ZH.txt 中复制地址与连接密钥。手机与电脑需在同一网络。")
                    TextField("http://192.168.1.8:7867",text:$ai.address).focused($focusedInput,equals:"address")
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder).disabled(ai.connecting || ai.busy)
                        .submitLabel(.done).onSubmit { focusedInput = nil; KeyboardDismiss.perform() }
                    SecureField("连接密钥",text:$ai.key).focused($focusedInput,equals:"key").textFieldStyle(.roundedBorder).disabled(ai.connecting || ai.busy)
                        .submitLabel(.done).onSubmit { focusedInput = nil; KeyboardDismiss.perform() }
                    Button("连接并读取音色") { focusedInput = nil; KeyboardDismiss.perform(); ai.connect() }.buttonStyle(PaperButtonStyle(primary:true))
                        .disabled(ai.connecting || ai.busy)
                    if ai.connecting { ProgressView("正在连接…") }
                    PaperCaption(ai.status)
                    if let warning = ai.connectionWarning { Text(warning).font(.caption).foregroundStyle(.orange) }
                    if let error = ai.errorMessage { Text(error).foregroundStyle(.orange) }
                }
                PaperCaption("只有点击“生成 AI 声音”才发送所选录音到此电脑。音色参考和生成结果保留在你的设备。")
            }.keyboardDone { focusedInput = nil }.navigationTitle("电脑 AI").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("完成") { dismiss() } }
        }
    }
}
