import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @ObservedObject var coordinator: ExperimentCoordinator
    @ObservedObject var session: AudioSessionManager
    @State private var importing = false
    @State private var showResult = false
    @State private var customDelay = false

    init(coordinator: ExperimentCoordinator) {
        self.coordinator = coordinator
        session = coordinator.session
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("当前音频") {
                    if let audio = coordinator.audio {
                        Text(audio.fileName).font(.headline)
                        LabeledContent("时长", value: String(format: "%.2f 秒", audio.duration))
                        LabeledContent("采样率", value: String(format: "%.0f Hz", audio.sampleRate))
                        LabeledContent("声道", value: String(audio.channelCount))
                        LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: audio.byteCount, countStyle: .file))
                    } else { Text("尚未选择音频") }
                    Button("导入音频") { importing = true }
                        .disabled(coordinator.controlsLocked)
                    Button("使用测试音频") { coordinator.useTestAudio() }
                        .disabled(coordinator.controlsLocked)
                }
                Section("实验设置") {
                    Picker("播放引擎", selection: $coordinator.engineKind) {
                        ForEach(PlaybackEngineKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("音频模式", selection: $coordinator.profile) {
                        ForEach(AudioSessionProfile.allCases) { Text("\($0.rawValue) · \($0.title)").tag($0) }
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
                    Toggle("强制使用内置扬声器", isOn: $coordinator.speakerOverride)
                        .disabled(!coordinator.profile.usesInput)
                    if !coordinator.profile.usesInput {
                        Text("扬声器覆盖仅用于播放和录音模式。").font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("语音优化播放", isOn: $coordinator.voiceOptimized)
                        .disabled(coordinator.engineKind != .audioEngine)
                    Text(coordinator.engineKind == .audioEngine
                         ? "优化使用单声道副本、保守动态处理和高低通滤波；原文件不变。"
                         : "语音优化适用于 AVAudioEngine。AVAudioPlayer 使用原始音频。")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(coordinator.controlsLocked)
                Section("播放音量") {
                    Slider(value: $coordinator.volume, in: 0...1)
                        .accessibilityLabel("播放音量")
                    Text("\(Int(coordinator.volume * 100))% · 只控制 App 播放器音量")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(coordinator.busy)
                if session.snapshot.currentRoute.usesExternalDevice {
                    Section {
                        Label("当前实验建议使用 iPhone 自带扬声器和麦克风。", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(session.snapshot.currentRoute.summary).font(.caption)
                    }
                }
                if let warning = session.interruptionMessage {
                    Section { Label(warning, systemImage: "waveform.slash").foregroundStyle(.orange) }
                }
                Section("播放实验") {
                    if coordinator.busy { ProgressView("正在准备音频…") }
                    Text(coordinator.state.title).font(.headline)
                    if coordinator.state == .waiting {
                        Text(coordinator.remaining > 0 ? "\(Int(ceil(coordinator.remaining)))" : "等待状态观察")
                            .font(.system(size: coordinator.remaining > 0 ? 64 : 22, weight: .bold, design: .rounded))
                            .frame(maxWidth: .infinity)
                        Text("请立即切换到微信").font(.headline)
                        Text("并在播放开始前按住微信语音消息按钮")
                    }
                    Text("倒计时仅作提示。后台调度、扬声器发声和微信收录结果需要真机确认。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("准备并开始") { coordinator.start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(coordinator.controlsLocked || coordinator.audio == nil)
                    Button("停止播放", role: .destructive) { coordinator.stop() }
                        .disabled(!coordinator.isRunning && !coordinator.busy)
                    Button("保存实验结果") { coordinator.checkpoint(); showResult = true }
                        .disabled(coordinator.currentExperiment == nil || coordinator.busy)
                }
                Section {
                    NavigationLink("查看诊断") { DiagnosticsView(coordinator: coordinator) }
                    NavigationLink("实验历史") { HistoryView(coordinator: coordinator) }
                }
            }
            .navigationTitle("音频接力实验室")
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls): if let url = urls.first { coordinator.importAudio(url) }
                case .failure(let error):
                    coordinator.logger.log("文件选择失败", diagnosticError(error))
                    coordinator.errorMessage = "音频文件选择失败，请重试。"
                }
            }
            .sheet(isPresented: $showResult) {
                if let experiment = coordinator.currentExperiment {
                    ExperimentResultView(experiment: experiment) { result, notes in coordinator.saveResult(result: result, notes: notes) }
                }
            }
            .alert("操作提示", isPresented: Binding(get: { coordinator.errorMessage != nil }, set: { if !$0 { coordinator.errorMessage = nil } })) {
                Button("好", role: .cancel) { coordinator.errorMessage = nil }
            } message: { Text(coordinator.errorMessage ?? "") }
            .onChange(of: customDelay) { _, enabled in if !enabled { coordinator.delay = 3 } }
            .onChange(of: coordinator.engineKind) { _, value in if value == .audioPlayer { coordinator.voiceOptimized = false } }
        }
    }
}
