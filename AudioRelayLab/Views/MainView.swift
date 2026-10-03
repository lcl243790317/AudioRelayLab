import AVFAudio
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @ObservedObject var coordinator: ExperimentCoordinator
    @ObservedObject var session: AudioSessionManager
    @ObservedObject var voice: VoiceProcessingEngine
    @State private var importing = false
    @State private var showResult = false
    @State private var showTechnicalDetails = false
    @State private var customDelay = false

    init(coordinator: ExperimentCoordinator) {
        self.coordinator = coordinator
        session = coordinator.session
        voice = coordinator.voiceLab
    }

    var body: some View {
        NavigationStack {
            PaperScreen {
                PaperHeader(title:"音频接力",subtitle:"选一段声音，留一点时间。")
                audioSection
                PaperCard("播放与试听") { AudioEditorView(coordinator:coordinator) }
                experimentSection
                if coordinator.errorMessage != nil || coordinator.state == .failed {
                    failureSection
                }
                PaperCard {
                    DisclosureGroup("高级实验设置") { settingsSection; sessionSection }
                }
            }
            .navigationTitle("AudioRelayLab")
            .buttonStyle(PaperButtonStyle())
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $importing) {
                AudioDocumentPicker(onSelection: { url in
                    // Acquire the scope and hand off the copied URL before dismissing the picker.
                    coordinator.importAudio(url)
                    importing = false
                }, onCancel: {
                    coordinator.logger.log("文件选择", "用户取消选择，当前音频保留")
                    importing = false
                })
            }
            .sheet(isPresented: $showResult) {
                if let experiment = coordinator.currentExperiment {
                    ExperimentResultView(experiment: experiment) { result, notes in
                        coordinator.saveResult(result: result, notes: notes)
                    }
                }
            }
            .sheet(isPresented: $showTechnicalDetails) {
                NavigationStack {
                    ScrollView {
                        Text(coordinator.technicalDetails ?? "本次操作没有额外技术错误，请查看诊断日志。")
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .navigationTitle("技术详情")
                    .toolbar { Button("完成") { showTechnicalDetails = false } }
                }
            }
            .onChange(of: customDelay) { _, enabled in
                if !enabled { coordinator.delay = 5 }
            }
            .onChange(of: coordinator.engineKind) { _, value in
                if value == .audioPlayer { coordinator.voiceOptimized = false }
            }
        }
    }

    private var sessionSection: some View {
        VStack(alignment:.leading,spacing:12) {
            LabeledContent("Audio Session", value: session.availabilityMessage)
            LabeledContent("当前配置", value: "\(coordinator.profile.rawValue) · \(coordinator.profile.title)")
            LabeledContent("实验状态", value: coordinator.state.title)
            LabeledContent("当前输入", value: ports(session.snapshot.currentRoute.inputs))
            LabeledContent("当前输出", value: ports(session.snapshot.currentRoute.outputs))
            LabeledContent("系统输出音量（只读）", value: percentage(Double(session.snapshot.outputVolume)))
            if coordinator.profile == .bluetooth {
                let hfp = (session.snapshot.currentRoute.inputs + session.snapshot.currentRoute.outputs)
                    .contains { $0.portType == AVAudioSession.Port.bluetoothHFP.rawValue }
                Label(hfp ? "蓝牙 HFP 允许；当前实际路由包含 HFP。" : "蓝牙 HFP 允许；当前实际路由未使用 HFP。",
                      systemImage: hfp ? "headphones" : "speaker.wave.2")
                    .font(.caption)
                Text("实际路由：\(ports(session.snapshot.currentRoute.inputs)) / \(ports(session.snapshot.currentRoute.outputs))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let warning = session.interruptionMessage {
                Label(warning, systemImage: "waveform.slash").foregroundStyle(.orange)
            }
            Button("刷新音频环境") { session.capture("用户刷新首页"); coordinator.refresh() }
            Text("通话或其他高优先级音频会话可能使实验不可用。系统通话状态与音频诊断不能可靠识别具体 App。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var audioSection: some View {
        PaperCard("我的音频") {
            if let audio = coordinator.audio {
                HStack(spacing:16) {
                    Image(systemName:"music.note").font(.title).frame(width:58,height:58).background(PaperTheme.background)
                    VStack(alignment:.leading,spacing:6) {
                        Text(audio.fileName).font(.headline).lineLimit(2)
                        PaperCaption(AudioPlaybackSettings.time(audio.duration)+" · "+audio.formatDescription)
                    }
                }
                DisclosureGroup("文件详情") {
                LabeledContent("时长", value: String(format: "%.2f 秒", audio.duration))
                LabeledContent("格式 / 来源", value: "\(audio.formatDescription) / \(audio.source.rawValue)")
                LabeledContent("采样率", value: String(format: "%.0f Hz", audio.sampleRate))
                LabeledContent("声道", value: String(audio.channelCount))
                LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: audio.byteCount, countStyle: .file))
                }
            } else {
                Text("尚未选择音频")
            }
            HStack {
                Button("导入音频") { importing = true }.buttonStyle(PaperButtonStyle(primary:true))
                Button("使用测试音频") { coordinator.useTestAudio() }
            }.disabled(coordinator.controlsLocked)
            PaperCaption("支持 WAV、MP3、M4A、AAC、AIFF、AIFC、CAF、FLAC；其他类型在文件选择器中显示为灰色。")
            if coordinator.isImporting {
                ProgressView("正在读取文件提供器并复制音频…")
                Button("取消导入") { coordinator.cancelImport() }
            }
            if !coordinator.library.isEmpty {
                DisclosureGroup("本地音频库（\(coordinator.library.count)）") {
                    ForEach(coordinator.library) { asset in
                        Button(asset.fileName) { coordinator.selectLocal(asset) }.disabled(coordinator.isRunning || voice.isActive)
                    }
                }
            }
        }
    }

    private var settingsSection: some View {
        VStack(alignment:.leading,spacing:14) {
            Picker("音频配置", selection: $coordinator.profile) {
                ForEach(AudioSessionProfile.selectableCases) { profile in
                    Text("\(profile.rawValue) · \(profile.title)").tag(profile)
                }
            }
            Text(coordinator.profile.shortDescription).font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("A / C / D / E 配置说明") {
                ForEach(AudioSessionProfile.selectableCases) { profile in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(profile.rawValue) · \(profile.title)").font(.subheadline.bold())
                        Text(profile.shortDescription).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Picker("播放引擎", selection: $coordinator.engineKind) {
                ForEach(PlaybackEngineKind.selectableCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("自定义延迟", isOn: $customDelay)
            if customDelay {
                TextField("延迟秒数（0.1～60）", value: $coordinator.delay, format: .number)
                    .keyboardType(.decimalPad)
            } else {
                Picker("延迟时间", selection: $coordinator.delay) {
                    ForEach([1.0, 2, 3, 4, 5, 7, 10], id: \.self) { Text("\(Int($0)) 秒").tag($0) }
                }
            }
            Toggle("限制播放时长", isOn: Binding(
                get: { coordinator.requestedDuration != nil },
                set: { coordinator.requestedDuration = $0 ? min(10, maximumDuration) : nil }
            )).disabled((coordinator.audio?.duration ?? 0) < 0.1)
            if coordinator.requestedDuration != nil {
                TextField("播放秒数（0.1～\(String(format: "%.1f", maximumDuration))）", value: durationBinding, format: .number)
                    .keyboardType(.decimalPad)
                if maximumDuration > 0.1 {
                    Slider(value: durationSliderBinding, in: 0.1...maximumDuration)
                        .accessibilityLabel("限制播放时长")
                }
            }
            Text(coordinator.requestedDuration == nil
                 ? "从已应用的起点播放剩余音频。限制时长按源音频秒数计算，倍速会改变实际播放时间。"
                 : "限制时长须不超过剩余源音频且最多 600 秒。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("强制使用内置扬声器", isOn: $coordinator.speakerOverride)
                .disabled(!coordinator.profile.usesInput)
            Text("扬声器覆盖仅用于 C / D。关闭覆盖后，实际输出仍由配置、连接设备和系统决定。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("语音优化播放", isOn: $coordinator.voiceOptimized)
                .disabled(coordinator.engineKind != .audioEngine)
            Text(coordinator.engineKind == .audioEngine
                 ? "使用单声道副本、保守动态处理和高低通滤波；保留原文件。"
                 : "AVAudioPlayer 使用原始音频；语音优化适用于 AVAudioEngine。")
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(coordinator.controlsLocked)
    }

    private var volumeSection: some View {
        VStack(alignment:.leading,spacing:8) {
            Slider(value: Binding(
                get: { coordinator.volume.isFinite ? min(1, max(0, coordinator.volume)) : 0 },
                set: { coordinator.volume = $0 }
            ), in: 0...1, step: 0.01)
                .accessibilityLabel("App 播放音量")
                .accessibilityValue(percentage(coordinator.volume))
            Text("\(percentage(coordinator.volume)) · 0%～100%")
            Text("仅控制 App 播放音量。")
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(coordinator.controlsLocked)
    }

    private var experimentSection: some View {
        PaperCard("延迟播放") {
            volumeSection
            Picker("等待时间",selection:$coordinator.delay) {
                ForEach([1.0,2,3,4,5,7,10],id:\.self) { Text("\(Int($0)) 秒").tag($0) }
            }.disabled(coordinator.controlsLocked)
            LabeledContent("已应用开始位置", value: AudioPlaybackSettings.time(coordinator.applied.startOffset))
            LabeledContent("已应用速度", value: String(format: "%gx", coordinator.applied.playbackRate))
            LabeledContent("正式音量 / 延迟", value: "\(percentage(coordinator.volume)) / \(coordinator.delay)s")
            Label(coordinator.state.title, systemImage: stateIcon).font(.headline)
            if coordinator.busy { ProgressView("正在准备或读取音频…") }
            if coordinator.state == .prepared {
                Text("音频已准备。点击“开始实验”后才计算延迟并提交未来播放请求。")
                    .font(.callout)
                Button("开始实验") { coordinator.startPrepared() }
                    .buttonStyle(PaperButtonStyle(primary:true))
            } else if coordinator.state == .waiting {
                Text(coordinator.remaining > 0 && coordinator.remaining.isFinite ? "\(Int(ceil(min(60, coordinator.remaining))))" : "等待状态观察")
                    .font(.system(size: coordinator.remaining > 0 ? 64 : 22, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity)
                Text("若测试微信语音消息，请切换到微信并在播放前按住录音。")
                    .font(.callout)
            } else if !coordinator.controlsLocked {
                Button(coordinator.state == .failed ? "稍后重试：重新准备" : "准备实验") { coordinator.prepare() }
                    .buttonStyle(PaperButtonStyle(primary:true))
                    .disabled(coordinator.audio == nil)
            }
            Button(coordinator.state == .preparing || coordinator.state == .prepared ? "取消准备" : "停止 / 取消实验", role: .destructive) {
                coordinator.stop()
            }
                .disabled(!coordinator.isRunning && !coordinator.busy)
            Button("填写并保存实验结果") { coordinator.checkpoint(); showResult = true }
                .disabled(coordinator.currentExperiment == nil || coordinator.controlsLocked)
            PaperCaption("倒计时按真实时间运行，不受播放倍速影响。")
        }
    }

    private var failureSection: some View {
        PaperCard("本次操作未完成") {
            Label(coordinator.errorMessage ?? "当前音频环境不允许开始实验。结束通话或其他高优先级音频后，可以重新准备。",
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Button("查看技术详情") { showTechnicalDetails = true }
            if coordinator.state != .failed {
                Button("收起提示") { coordinator.errorMessage = nil }
            }
        }
    }

    private var stateIcon: String {
        switch coordinator.state {
        case .preparing: return "hourglass"
        case .prepared: return "checkmark.circle"
        case .waiting: return "timer"
        case .playing: return "waveform"
        case .interrupted: return "waveform.slash"
        case .failed: return "exclamationmark.triangle"
        case .completed: return "checkmark.circle.fill"
        case .cancelled, .stopped: return "stop.circle"
        default: return "circle"
        }
    }

    private var maximumDuration: Double {
        let duration = (coordinator.audio?.duration ?? 600) - coordinator.applied.startOffset
        return duration.isFinite ? max(0.1, min(duration, 600)) : 600
    }

    private var durationBinding: Binding<Double> {
        Binding(get: { coordinator.requestedDuration ?? min(10, maximumDuration) },
                set: { coordinator.requestedDuration = $0 })
    }

    private var durationSliderBinding: Binding<Double> {
        Binding(get: {
            let value = coordinator.requestedDuration ?? min(10, maximumDuration)
            return value.isFinite ? min(maximumDuration, max(0.1, value)) : 0.1
        }, set: { coordinator.requestedDuration = $0 })
    }

    private func percentage(_ value: Double) -> String {
        guard value.isFinite else { return "不可用" }
        return "\(Int((min(1, max(0, value)) * 100).rounded()))%"
    }

    private func ports(_ values: [AudioPortSnapshot]) -> String {
        values.isEmpty ? "无当前路由" : values.map { "\($0.portName)（\($0.portType)）" }.joined(separator: " / ")
    }
}
