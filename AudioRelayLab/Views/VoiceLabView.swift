import SwiftUI

struct VoiceLabView: View {
    @ObservedObject var coordinator: ExperimentCoordinator
    @ObservedObject var voice: VoiceProcessingEngine
    @ObservedObject var session: AudioSessionManager
    let mixer: Bool
    @State private var shareItem: ShareItem?
    @State private var musicSeek: Double = 0
    @State private var musicRate: Float = 1
    init(coordinator: ExperimentCoordinator, mixer: Bool) {
        self.coordinator = coordinator; self.mixer = mixer
        voice = coordinator.voiceLab; session = coordinator.session
    }
    var body: some View {
        NavigationStack {
            Form {
                Section(mixer ? "处理后人声 + 音乐" : "麦克风与自然变声") {
                    LabeledContent("状态", value: voice.state.rawValue)
                    LabeledContent("工作模式", value: voice.modeLabel)
                    Text(voice.status).font(.caption.monospaced())
                    ProgressView("Input Level", value: Double(min(1, max(0, voice.inputLevel))))
                    ProgressView("DSP Output Level", value: Double(min(1, max(0, voice.outputLevel))))
                    Text(session.snapshot.currentRoute.summary).font(.caption)
                    if let error = voice.errorMessage { Text(error).foregroundStyle(.orange) }
                    if voice.state == .preparing { ProgressView("正在请求权限与准备音频图…") }
                }
                Section("音色") {
                    Picker("Preset", selection: $voice.preset) {
                        ForEach(VoicePreset.all) { Text($0.name).tag($0) }
                    }.onChange(of: voice.preset) { _, _ in voice.updateParameters() }
                    Slider(value: Binding(get: { bounded(voice.strength) }, set: { voice.strength = Float($0); voice.updateParameters() }), in: 0...1)
                    Text("效果强度 \(percent(voice.strength))")
                    Text("预设是可调校的 DSP 起点，效果取决于原声、耳机与环境。独立调整 pitch 和 formant，不能保证变成指定年龄或性别。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if mixer {
                    Section("背景音乐") {
                        Text(coordinator.audio?.fileName ?? "请先在 Audio 页选择音乐")
                        LabeledContent("起点", value: AudioPlaybackSettings.time(coordinator.applied.startOffset))
                        LabeledContent("速度", value: String(format: "%gx", coordinator.applied.playbackRate))
                        if voice.state == .running, voice.isMixed {
                            LabeledContent("音乐播放进度", value: AudioPlaybackSettings.time(voice.musicPosition))
                            Slider(value:$musicSeek,in:0...max(0.001,coordinator.audio?.duration ?? 0.001))
                            LabeledContent("音乐 seek 位置",value:AudioPlaybackSettings.time(musicSeek))
                            Picker("音乐倍速",selection:$musicRate) {
                                ForEach(AudioPlaybackSettings.rates,id:\.self) { Text(String(format:"%gx",$0)).tag($0) }
                            }
                            Button("应用音乐起点 / 倍速") {
                                voice.seekMusic(.init(startOffset:musicSeek,playbackRate:musicRate,volume:voice.musicVolume))
                            }
                        }
                        Text("启动时沿用 Audio 页已应用的起点和倍速。Mixer 运行时可独立 seek，不改变正式 Experiment 设置。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("独立音量") {
                    volume("Voice", value: $voice.voiceVolume)
                    if mixer { volume("Music", value: $voice.musicVolume) }
                    volume("Master", value: $voice.masterVolume)
                    Text("0%～100%；不改变系统音量。保存的 CAF 为单声道 PCM，混音录制会合并左右声道。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("试听 / 录制") {
                    Toggle("允许扬声器监听", isOn: $voice.allowSpeakerMonitoring).disabled(voice.isActive)
                    Toggle("允许后台继续当前 Voice / Mixer", isOn: $voice.continuesInBackground).disabled(voice.isActive)
                    Text("默认需耳机才能实时监听。扬声器与麦克风同时运行可能反馈；启用时从低 Master 音量开始。录音默认关闭现场监听。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(mixer ? "开始人声 + 音乐输出" : "开始实时试听") {
                        voice.start(mixer ? .mixedMonitor : .monitor, music: coordinator.audio, settings: coordinator.applied)
                    }.disabled(voice.isActive || (mixer && coordinator.audio == nil))
                    Button(mixer ? "● 录制混合结果" : "● 开始录制处理后人声") {
                        voice.start(mixer ? .mixedRecording : .voiceRecording, music: coordinator.audio, settings: coordinator.applied)
                    }.disabled(voice.isActive || (mixer && coordinator.audio == nil))
                    Button(voice.isRecording ? "■ 停止并保存录音" : "■ 停止", role: .destructive) { voice.stop(); coordinator.refreshLibrary() }
                        .disabled(!voice.isActive)
                    if voice.isRecording { Button("取消并丢弃这次录音", role: .destructive) { voice.stop(saveRecording: false) } }
                    Text("后台继续仅用于你主动开启的真实输入、输出或录音；系统可能因其他 App 录音而中断。中断、路由或媒体服务变化时安全停止，需手动重启。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("已保存的录音") {
                    if voice.recordings.isEmpty { Text("暂无录音") }
                    ForEach(voice.recordings) { record in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(record.asset.fileName).font(.headline)
                            Text("\(AudioPlaybackSettings.time(record.asset.duration)) · \(record.asset.formatDescription) · \(Int(record.asset.sampleRate)) Hz · \(record.asset.channelCount)ch · \(ByteCountFormatter.string(fromByteCount: record.asset.byteCount, countStyle: .file))")
                                .font(.caption)
                            HStack {
                                Button("▶ 试听") { coordinator.selectLocal(record.asset); coordinator.audition() }.buttonStyle(.bordered)
                                Button("■ 停止") { coordinator.preview.stop() }.buttonStyle(.bordered)
                            }
                            HStack {
                                Button("应用到主音频") { coordinator.selectLocal(record.asset) }.buttonStyle(.bordered)
                                Button("分享") {
                                    if let url = try? AudioFileManager.url(for: record.asset) { shareItem = ShareItem(url: url) }
                                }.buttonStyle(.bordered)
                                Button("删除", role: .destructive) {
                                    coordinator.preview.stop()
                                    if coordinator.audio?.id == record.asset.id { coordinator.useTestAudio() }
                                    voice.delete(record); coordinator.refreshLibrary()
                                }.buttonStyle(.bordered)
                            }
                        }.disabled(voice.isActive || coordinator.isRunning || coordinator.isImporting)
                    }
                }
            }.navigationTitle(mixer ? "Mixer" : "Voice Lab")
                .sheet(item: $shareItem) { item in ShareSheet(url: item.url) }
        }
    }
    private func volume(_ title: String, value: Binding<Float>) -> some View {
        VStack(alignment: .leading) {
            Text("\(title) \(percent(value.wrappedValue))")
            Slider(value: Binding(get: { bounded(value.wrappedValue) }, set: { value.wrappedValue = Float($0); voice.updateParameters() }), in: 0...1)
        }
    }
    private func bounded(_ value:Float) -> Double { value.isFinite ? Double(min(1,max(0,value))) : 0 }
    private func percent(_ value:Float) -> String { value.isFinite ? "\(Int(bounded(value)*100))%" : "不可用" }
}
