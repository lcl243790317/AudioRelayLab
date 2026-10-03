import SwiftUI

struct VoiceLabView: View {
    @ObservedObject var coordinator: ExperimentCoordinator
    @ObservedObject var voice: VoiceProcessingEngine
    @ObservedObject var ai: AIConversionController
    @State private var processor = ProcessInfo.processInfo.arguments.contains("voice-local-snapshot") ? 1 : 0
    @State private var mixer = false
    @State private var showConnection = false
    @State private var musicSeek:Double = 0
    @State private var musicRate:Float = 1
    @State private var calibration = ""
    @State private var calibrating = false
    @State private var backgroundID:UUID?
    @State private var mixing = false
    @State private var mixStatus = ""
    init(coordinator:ExperimentCoordinator) {
        self.coordinator = coordinator; voice = coordinator.voiceLab; ai = coordinator.aiVoice
    }
    var body: some View {
        NavigationStack {
            PaperScreen {
                PaperHeader(title:"声音工坊",subtitle:"让声音，也有自己的模样。",symbol:"mic")
                Picker("处理方式",selection:$processor) {
                    Text("电脑 AI").tag(0)
                    Text("手机实时").tag(1)
                }.pickerStyle(.segmented).disabled(voice.isActive || ai.busy)
                if processor == 0 { aiSection } else { localSection }
                PaperCard {
                    NavigationLink("录音与已生成的声音") { VoiceRecordLibraryView(coordinator:coordinator) }
                }
            }.navigationTitle("变声").navigationBarTitleDisplayMode(.inline)
                .buttonStyle(PaperButtonStyle())
                .sheet(isPresented:$showConnection) { AIConnectionView(ai:ai) }
        }
    }
    private var aiSection: some View {
        Group {
            PaperCard("目标音色") {
                if ai.voices.isEmpty {
                    PaperCaption("先连接同一网络的电脑，再选择真实参考音色。")
                    Button("连接我的电脑") { showConnection = true }.buttonStyle(PaperButtonStyle(primary:true))
                } else {
                    Picker("音色",selection:$ai.selectedVoice) {
                        ForEach(ai.voices) { Text($0.name).tag($0.id) }
                    }.disabled(ai.busy || voice.isActive)
                    DisclosureGroup("音色来源与电脑连接") {
                        if let selected = ai.voices.first(where:{$0.id == ai.selectedVoice}) {
                            PaperCaption(selected.referenceOrigin)
                        }
                        Button("查看连接设置") { showConnection = true }.disabled(ai.busy)
                    }
                }
                PaperCaption("保留原话、停顿和语调走势，转换为参考音色；自然度取决于两段录音。")
            }
            PaperCard("一段纯人声") {
                Text(ai.input?.fileName ?? "尚未录制或选择人声").font(.headline).lineLimit(2)
                if voice.isActive {
                    ProgressView("正在录原声",value:Double(min(1,max(0,voice.inputLevel))))
                    PaperCaption(voice.status)
                    Button("停止并保留原声") { voice.stop() }.buttonStyle(PaperButtonStyle(primary:true))
                } else {
                    HStack {
                        Button("录制原声") {
                            ai.selectInput(nil)
                            voice.start(.rawRecording)
                        }.disabled(coordinator.controlsLocked || ai.connecting)
                        Button("使用当前音频") { ai.selectInput(coordinator.audio) }
                            .disabled(coordinator.controlsLocked || ai.connecting || coordinator.audio == nil)
                    }
                }
                PaperCaption("每段 0.3–25 秒；录制到 24 秒会自动保存。请在安静环境正常说话。")
                if ai.input?.id == coordinator.audio?.id {
                    PaperCaption("转换范围沿用音频页已应用的起点和限制时长。")
                }
                Button("生成 AI 声音") {
                    let selected = ai.input?.id == coordinator.audio?.id
                    ai.convert(start:selected ? coordinator.applied.startOffset : 0,
                               limit:selected ? coordinator.requestedDuration : nil)
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
                    Text(result.fileName).font(.headline)
                    HStack {
                        Button("回听") { coordinator.selectLocal(result); coordinator.audition() }
                        Button("应用到音频页") { coordinator.selectLocal(result) }
                    }.disabled(coordinator.controlsLocked)
                    Button("停止回听") { coordinator.preview.stop() }
                    DisclosureGroup("加入背景音乐并保存") {
                        Picker("背景音乐",selection:$backgroundID) {
                            Text("请选择音乐").tag(Optional<UUID>.none)
                            ForEach(coordinator.library.filter { $0.id != result.id }) { asset in
                                Text(asset.fileName).tag(Optional(asset.id))
                            }
                        }.disabled(mixing || coordinator.controlsLocked)
                        volume("人声",value:$voice.voiceVolume)
                        volume("音乐",value:$voice.musicVolume)
                        PaperCaption("使用完整 AI 人声；背景音乐从头以原速加入。音乐默认 4%。")
                        Button(mixing ? "正在保存混音…" : "保存混合音频") { mix(result) }
                            .disabled(mixing || coordinator.controlsLocked || backgroundID == nil)
                        if !mixStatus.isEmpty { PaperCaption(mixStatus) }
                    }
                }
            }
        }
    }
    private var localSection: some View {
        Group {
            PaperCard("实时音色") {
                Picker("预设",selection:$voice.preset) {
                    ForEach(VoicePreset.all) { Text($0.name).tag($0) }
                    if !VoicePreset.all.contains(voice.preset) { Text(voice.preset.name+" · 已调校").tag(voice.preset) }
                }.onChange(of:voice.preset) { _,_ in voice.updateParameters() }
                Slider(value:Binding(get:{ bounded(voice.strength) },set:{ voice.strength = Float($0); voice.updateParameters() }),in:0...1)
                PaperCaption("效果强度 \(percent(voice.strength)) · 手机即时处理，音色会保留部分原声特征。")
                DisclosureGroup("按原声校准与微调") {
                    Button(calibrating ? "正在测量原声…" : "根据已有原声校准音高") { calibrate() }
                        .disabled(calibrating || coordinator.controlsLocked || (ai.input == nil && coordinator.audio == nil))
                    PaperCaption(calibration.isEmpty ? "使用上方录制的原声或音频页纯人声测量；女声目标按原声基频计算，不固定升高同一幅度。" : calibration)
                    Text(String(format:"音高 %+.1f 半音",voice.preset.pitch)).font(.subheadline)
                    Slider(value:$voice.preset.pitch,in:-12...12,step:0.5)
                    Text(String(format:"共振峰 %+.1f 半音",voice.preset.formant)).font(.subheadline)
                    Slider(value:$voice.preset.formant,in:-8...8,step:0.2)
                }
                DisclosureGroup("均衡 · 厚度与清晰度") {
                    presetSlider("低切",value:$voice.preset.highpass,range:20...500,step:5,unit:"Hz")
                    presetSlider("低中频 · 厚度",value:$voice.preset.lowmid,range:-12...12,step:0.5,unit:"dB")
                    presetSlider("存在感 · 清晰度",value:$voice.preset.presence,range:-12...12,step:0.5,unit:"dB")
                    presetSlider("空气感 · 明亮度",value:$voice.preset.air,range:-12...12,step:0.5,unit:"dB")
                }
                DisclosureGroup("动态 · 效果与输出") {
                    presetSlider("压缩强度",value:$voice.preset.compression,range:0...1,step:0.01,unit:"%")
                    presetSlider("齿音抑制",value:$voice.preset.deesser,range:0...1,step:0.01,unit:"%")
                    presetSlider("变声混合比例",value:$voice.preset.wet,range:0...1,step:0.01,unit:"%")
                    presetSlider("机器人效果",value:$voice.preset.robot,range:0...1,step:0.01,unit:"%")
                    presetSlider("音色输出增益",value:$voice.preset.outputGain,range:0...2,step:0.01,unit:"倍")
                    PaperCaption("调节即时生效；总输出仍有削波保护。混合比例为 0% 时保留原声，效果强度为 0% 时关闭调音。")
                }
                Button("恢复当前预设参数") {
                    voice.preset = VoicePreset.all.first(where:{$0.id == voice.preset.id}) ?? VoicePreset.all[0]
                    voice.strength = 1; voice.updateParameters()
                    calibration = "已恢复预设参数。"
                }
                Toggle("加入背景音乐",isOn:$mixer).disabled(voice.isActive)
                if mixer {
                    Text(coordinator.audio?.fileName ?? "请先在音频页选择音乐").font(.subheadline)
                    PaperCaption("沿用已应用的起点 \(AudioPlaybackSettings.time(coordinator.applied.startOffset)) · \(String(format:"%gx",coordinator.applied.playbackRate))")
                }
            }
            PaperCard("试听与录制") {
                Text(voice.isActive ? "麦克风已开启" : "准备就绪").font(.headline)
                if voice.isActive {
                    ProgressView("麦克风",value:Double(min(1,max(0,voice.inputLevel))))
                    ProgressView("输出",value:Double(min(1,max(0,voice.outputLevel))))
                    Button(voice.isRecording ? "停止并保存" : "停止试听") { voice.stop(); coordinator.refreshLibrary() }
                        .buttonStyle(PaperButtonStyle(primary:true))
                } else {
                    HStack {
                        Button("实时试听") { voice.start(mixer ? .mixedMonitor : .monitor,music:coordinator.audio,settings:coordinator.applied) }
                        Button("录制声音") { voice.start(mixer ? .mixedRecording : .voiceRecording,music:coordinator.audio,settings:coordinator.applied) }
                            .buttonStyle(PaperButtonStyle(primary:true))
                    }.disabled(coordinator.controlsLocked || (mixer && coordinator.audio == nil))
                }
                PaperCaption(voice.status)
                if let error = voice.errorMessage { Text(error).font(.callout).foregroundStyle(.orange) }
                DisclosureGroup("音量、监听与混音设置") {
                    volume("人声",value:$voice.voiceVolume)
                    if mixer { volume("音乐",value:$voice.musicVolume) }
                    volume("总输出",value:$voice.masterVolume)
                    Toggle("允许扬声器监听",isOn:$voice.allowSpeakerMonitoring).disabled(voice.isActive)
                    Toggle("后台继续当前试听或录音",isOn:$voice.continuesInBackground).disabled(voice.isActive)
                    PaperCaption("实时试听建议使用耳机。录音默认关闭现场监听。")
                    if voice.isRecording { Button("丢弃这次录音",role:.destructive) { voice.stop(saveRecording:false) } }
                    if voice.state == .running && voice.isMixed {
                        Slider(value:$musicSeek,in:0...max(0.001,coordinator.audio?.duration ?? 0.001))
                        Picker("音乐速度",selection:$musicRate) {
                            ForEach(AudioPlaybackSettings.rates,id:\.self) { Text(String(format:"%gx",$0)).tag($0) }
                        }
                        Button("应用音乐起点与速度") {
                            voice.seekMusic(.init(startOffset:musicSeek,playbackRate:musicRate,volume:voice.musicVolume))
                        }
                    }
                }
            }
        }
    }
    private func presetSlider(_ title:String,value:Binding<Float>,range:ClosedRange<Float>,step:Float,unit:String) -> some View {
        let number = unit == "%" ? String(format:"%.0f%%",value.wrappedValue*100) : String(format:"%+.1f %@",value.wrappedValue,unit)
        return VStack(alignment:.leading,spacing:6) {
            HStack { Text(title); Spacer(); Text(number).monospacedDigit().foregroundStyle(PaperTheme.accent) }
                .font(.subheadline)
            Slider(value:value,in:range,step:step) { Text(title) }.accessibilityValue(number)
        }
    }
    private func volume(_ title:String,value:Binding<Float>) -> some View {
        VStack(alignment:.leading) {
            Text("\(title) \(percent(value.wrappedValue))").font(.subheadline)
            Slider(value:Binding(get:{ bounded(value.wrappedValue) },set:{ value.wrappedValue = Float($0); voice.updateParameters() }),in:0...1)
        }
    }
    private func calibrate() {
        guard let asset = ai.input ?? coordinator.audio, let url = try? AudioFileManager.url(for:asset) else { return }
        calibrating = true
        Task {
            defer { calibrating = false }
            do {
                let pitch = try await Task.detached { try VoiceCalibration.measure(url:url) }.value
                let target:Double = ["female":210,"mature":185,"girl":240,"loli":270,"sweet":225][voice.preset.id]
                    ?? min(400,max(65,pitch*pow(2,Double(voice.preset.pitch)/12)))
                voice.preset.pitch = try VoiceCalibration.pitchShift(source:pitch,target:target)
                voice.strength = 1; voice.updateParameters()
                calibration = String(format:"原声约 %.0f Hz → 目标 %.0f Hz；已应用 %+.1f 半音。",pitch,target,voice.preset.pitch)
            } catch { calibration = userFacingAudioError(error) }
        }
    }
    private func mix(_ result:AudioAsset) {
        guard let music = coordinator.library.first(where:{$0.id == backgroundID}) else { return }
        mixing = true; coordinator.preview.stop()
        let volumes = AudioMixParameters(voice:voice.voiceVolume,music:voice.musicVolume,master:voice.masterVolume)
        Task {
            defer { mixing = false }
            do {
                let voiceURL = try AudioFileManager.url(for:result), musicURL = try AudioFileManager.url(for:music)
                _ = try await Task.detached { try RecordedVoiceMixer.mix(voiceURL:voiceURL,musicURL:musicURL,settings:.init(),volumes:volumes) }.value
                coordinator.refreshLibrary(); mixStatus = "已保存，可在录音库回听或应用。"
            } catch { mixStatus = userFacingAudioError(error) }
        }
    }
    private func bounded(_ value:Float) -> Double { value.isFinite ? Double(min(1,max(0,value))) : 0 }
    private func percent(_ value:Float) -> String { "\(Int(bounded(value)*100))%" }
}

struct AIConnectionView: View {
    @ObservedObject var ai:AIConversionController
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            PaperScreen {
                PaperHeader(title:"连接电脑",subtitle:"手机录音，电脑生成。",symbol:"desktopcomputer")
                PaperCard("一次设置") {
                    PaperCaption("电脑运行 server/run.ps1，在 server/CONNECTION-ZH.txt 中复制地址与连接密钥。手机与电脑需在同一网络。")
                    TextField("http://192.168.1.8:7867",text:$ai.address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder).disabled(ai.connecting || ai.busy)
                    SecureField("连接密钥",text:$ai.key).textFieldStyle(.roundedBorder).disabled(ai.connecting || ai.busy)
                    Button("连接并读取音色") { ai.connect() }.buttonStyle(PaperButtonStyle(primary:true))
                        .disabled(ai.connecting || ai.busy)
                    if ai.connecting { ProgressView("正在连接…") }
                    PaperCaption(ai.status)
                    if let warning = ai.connectionWarning { Text(warning).font(.caption).foregroundStyle(.orange) }
                    if let error = ai.errorMessage { Text(error).foregroundStyle(.orange) }
                }
                PaperCaption("只有点击“生成 AI 声音”才发送所选录音到此电脑。音色参考和生成结果保留在你的设备。")
            }.navigationTitle("电脑 AI").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("完成") { dismiss() } }
        }
    }
}
