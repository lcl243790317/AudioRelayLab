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
                if processor == 0 { VoiceAIView(coordinator:coordinator, showConnection: { showConnection = true }) } else { localSection }
                PaperCard {
                    NavigationLink("录音与已生成的声音") { VoiceRecordLibraryView(coordinator:coordinator) }
                }
            }.navigationTitle("变声").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.topBarTrailing) { ThemeToggleButton() } }
                .buttonStyle(PaperButtonStyle())
                .sheet(isPresented:$showConnection) { AIConnectionView(ai:ai) }
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
                DisclosureGroup("高级调音") { localAdvancedParameters }
                Toggle("加入背景音乐",isOn:$mixer).disabled(voice.isActive)
                if mixer {
                    Text(coordinator.audio?.fileName ?? "请先在音频页选择音乐").font(.subheadline)
                    PaperCaption("沿用已应用区间 \(AudioPlaybackSettings.time(coordinator.applied.startOffset)) → \(AudioPlaybackSettings.time(coordinator.applied.endPosition(duration:coordinator.audio?.duration ?? 0))) · \(String(format:"%gx",coordinator.applied.playbackRate))")
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
                        Slider(value:$musicSeek,in:0...max(0.001,coordinator.applied.endPosition(duration:coordinator.audio?.duration ?? 0.001)-0.001))
                        Picker("音乐速度",selection:$musicRate) {
                            ForEach(AudioPlaybackSettings.rates,id:\.self) { Text(String(format:"%gx",$0)).tag($0) }
                        }
                        Button("应用音乐起点与速度") {
                            voice.seekMusic(.init(startOffset:musicSeek,playbackRate:musicRate,volume:voice.musicVolume,endOffset:coordinator.applied.endOffset))
                        }
                    }
                }
            }
        }
    }
    private var localAdvancedParameters: some View {
        VStack(alignment:.leading,spacing:12) {
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
                DisclosureGroup("咬字 · 共振峰细节") {
                    presetSlider("辅音保护",value:$voice.preset.consonantProtection,range:0...1,step:0.01,unit:"%")
                    presetSlider("清晰度中心频率",value:$voice.preset.presenceHz,range:800...6000,step:50,unit:"Hz")
                    presetSlider("清晰度带宽 Q",value:$voice.preset.presenceQ,range:0.3...3,step:0.05,unit:"Q")
                    presetSlider("齿音检测频率",value:$voice.preset.deesserHz,range:3000...10000,step:100,unit:"Hz")
                    presetSlider("共振峰分析基频",value:$voice.preset.formantBaseHz,range:0...400,step:5,unit:"Hz")
                    PaperCaption("辅音保护减少 s、sh、t 等声音的涂抹感。分析基频为 0 时自动检测，也可填入校准测得的原声基频。")
                }
                DisclosureGroup("麦克风 · 噪声与压缩细节") {
                    presetSlider("输入增益",value:$voice.preset.inputGainDB,range:-18...18,step:0.5,unit:"dB")
                    presetSlider("噪声门阈值",value:$voice.preset.gateThresholdDB,range:-80 ... -20,step:1,unit:"dB")
                    presetSlider("噪声门衰减",value:$voice.preset.gateDepth,range:0...1,step:0.01,unit:"%")
                    presetSlider("压缩阈值",value:$voice.preset.compressorThresholdDB,range:-40...0,step:1,unit:"dB")
                    presetSlider("压缩比",value:$voice.preset.compressorRatio,range:1...10,step:0.1,unit:":1")
                    presetSlider("压缩启动",value:$voice.preset.attackMS,range:1...80,step:1,unit:"ms")
                    presetSlider("压缩释放",value:$voice.preset.releaseMS,range:20...500,step:5,unit:"ms")
                    PaperCaption("轻声被吞掉时先降低噪声门阈值或衰减；音量忽大忽小时再调压缩。女声先校准音高，避免一次升得过高。")
                }
                Button("恢复当前预设参数") {
                    voice.preset = VoicePreset.all.first(where:{$0.id == voice.preset.id}) ?? VoicePreset.all[0]
                    voice.strength = 1; voice.updateParameters()
                    calibration = "已恢复预设参数。"
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
                voice.preset.formantBaseHz = Float(min(400,max(0,pitch)))
                voice.strength = 1; voice.updateParameters()
                calibration = String(format:"原声约 %.0f Hz → 目标 %.0f Hz；已应用 %+.1f 半音。",pitch,target,voice.preset.pitch)
            } catch { calibration = userFacingAudioError(error) }
        }
    }

    private func bounded(_ value:Float) -> Double { value.isFinite ? Double(min(1,max(0,value))) : 0 }
    private func percent(_ value:Float) -> String { "\(Int(bounded(value)*100))%" }
}
