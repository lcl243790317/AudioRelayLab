import AVFAudio
import SwiftUI

@MainActor final class ExperimentCoordinator: ObservableObject {
    let logger: DiagnosticsLogger
    let session: AudioSessionManager
    let store: ExperimentStore
    @Published private(set) var audio: AudioFileMetadata?
    @Published var engineKind: PlaybackEngineKind = .audioPlayer
    @Published var profile: AudioSessionProfile = .mixingPlayback
    @Published var delay: Double = 3
    @Published var volume: Double = 0.5 {
        didSet {
            engine?.volume = Float(volume)
            if currentExperiment != nil, isRunning {
                logger.log("播放音量调整", "App 播放器音量=\(volume)；系统音量未修改。")
            }
        }
    }
    @Published var speakerOverride = false
    @Published var voiceOptimized = false
    @Published private(set) var state: PlaybackState = .idle
    @Published private(set) var currentExperiment: Experiment?
    @Published private(set) var remaining: Double = 0
    @Published private(set) var diagnosticState = "尚未创建播放器"
    @Published private(set) var busy = false
    @Published var errorMessage: String?
    private var engine: (any PlaybackEngineProtocol)?
    private var timer: Timer?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var logBoundary = 0
    private var userStopped = false
    private var attempt = UUID()
    private var sceneIsActive = true
    private var hasEnteredBackground = false
    private var mediaAvailable = true

    init() {
        let logger = DiagnosticsLogger()
        self.logger = logger
        session = AudioSessionManager(logger: logger)
        store = ExperimentStore(logger: logger)
        logger.log("生命周期", "App 启动；设备=\(DeviceInfo.current().modelIdentifier)；iOS=\(DeviceInfo.current().systemVersion)")
        session.onEvent = { [weak self] event in self?.handle(event) }
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willEnterForegroundNotification] {
            lifecycleObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let background = note.name == UIApplication.didEnterBackgroundNotification
                    self.logger.log("生命周期", background ? "UIApplication：进入后台" : "UIApplication：进入前台")
                    self.session.capture(background ? "background" : "foreground")
                    self.logEngineState()
                    self.checkpoint()
                    self.logger.flush()
                }
            })
        }
        if let data = UserDefaults.standard.data(forKey: "selectedAudio") {
            do {
                let saved = try JSONDecoder().decode(AudioFileMetadata.self, from: data)
                let url = try AudioFileManager.url(for: saved)
                if FileManager.default.fileExists(atPath: url.path) { audio = try AudioFileManager.inspect(url: url, displayName: saved.fileName) }
            } catch { logger.log("音频恢复失败", diagnosticError(error)) }
        }
        if audio == nil { useTestAudio() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }
    deinit {
        timer?.invalidate()
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
    }
    var isRunning: Bool { state == .prepared || state == .waiting || state == .playing || state == .interrupted }
    var controlsLocked: Bool { busy || isRunning }

    func importAudio(_ url: URL) {
        guard !controlsLocked else { return }
        busy = true
        Task {
            do {
                let metadata = try await Task.detached(priority: .userInitiated) { try AudioFileManager.importFile(from: url) }.value
                audio = metadata
                try rememberAudio(metadata)
                logger.log("音频导入", "已完成安全作用域访问、Sandbox 复制并释放访问；\(metadata.fileName)，\(metadata.duration)s，\(metadata.sampleRate) Hz，\(metadata.channelCount) 声道，\(metadata.byteCount) 字节")
            } catch { report(error, message: "音频导入失败，请选择可读取的 MP3、M4A、WAV 或 AAC 文件。") }
            busy = false
        }
    }
    func useTestAudio() {
        guard !controlsLocked else { return }
        do {
            let metadata = try AudioFileManager.generateTestAudio()
            audio = metadata
            try rememberAudio(metadata)
            logger.log("测试音频", "已生成 \(metadata.duration)s、\(metadata.sampleRate) Hz、\(metadata.channelCount) 声道的测试 WAV；含 10 ms 淡入淡出、0.28 峰值与静音间隔。")
        } catch { report(error, message: "测试音频生成失败，请检查设备存储空间。") }
    }
    private func rememberAudio(_ metadata: AudioFileMetadata) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(metadata), forKey: "selectedAudio")
    }
    func start() {
        guard !controlsLocked, let audio else { return }
        guard delay.isFinite, (0.1...60).contains(delay) else { errorMessage = "延迟必须在 0.1～60 秒之间。"; return }
        checkpoint()
        let settings = ExperimentSettings(engine: engineKind, profile: profile, delay: delay, volume: Float(volume),
            voiceOptimized: voiceOptimized && engineKind == .audioEngine, speakerOverride: speakerOverride && profile.usesInput)
        let token = UUID()
        attempt = token
        busy = true
        userStopped = false
        Task {
            defer { busy = false }
            if settings.profile.usesInput {
                let granted = await withCheckedContinuation { continuation in
                    AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
                }
                guard granted else { errorMessage = "此播放和录音配置需要麦克风权限，请在系统设置中允许，或改用播放模式。"; return }
            }
            guard attempt == token, !userStopped, sceneIsActive, mediaAvailable else {
                errorMessage = "准备已取消。请在前台重新开始实验。"
                return
            }
            engine?.onStateChange = nil
            engine?.stop()
            engine = nil
            let requested = Date()
            logBoundary = logger.nextSequence
            logger.log("实验请求", "实验开始；引擎=\(settings.engine.rawValue)，配置=\(settings.profile.rawValue)，延迟=\(settings.delay)s，音量=\(settings.volume)，优化=\(settings.voiceOptimized)，扬声器覆盖=\(settings.speakerOverride)")
            currentExperiment = Experiment(id: UUID(), date: requested, device: DeviceInfo.current(), audio: audio,
                settings: settings, schedule: nil, finalState: .idle, result: .uncertain, resultReviewed: false,
                notes: "", finishedAt: nil, logs: [])
            do {
                if settings.engine == .audioPlayer { engine = AVAudioPlayerPlaybackEngine(logger: logger) }
                else { engine = AVAudioEnginePlaybackEngine(logger: logger) }
                engine?.onStateChange = { [weak self] value in self?.engineStateChanged(value) }
                engine?.volume = settings.volume
                try session.configure(profile: settings.profile, speakerOverride: settings.speakerOverride)
                let url = try AudioFileManager.url(for: audio)
                try engine?.prepare(url: url, voiceOptimized: settings.voiceOptimized)
                session.capture("schedule 前")
                currentExperiment?.schedule = try engine?.schedule(delay: settings.delay, requestedTime: requested)
                session.capture("schedule 后")
                logEngineState()
                remaining = settings.delay
                checkpoint()
            } catch {
                engine?.onStateChange = nil
                engine?.stop()
                state = .failed
                currentExperiment?.finalState = .failed
                currentExperiment?.finishedAt = Date()
                report(error, message: (error as? LabError)?.errorDescription ?? "音频准备或调度失败，请查看诊断日志。")
                session.deactivate()
                checkpoint()
            }
        }
    }
    func stop() {
        userStopped = true
        attempt = UUID()
        engine?.stop()
        state = .stopped
        remaining = 0
        session.deactivate()
        checkpoint()
    }
    func saveResult(result: ExperimentResult, notes: String) {
        guard currentExperiment != nil else { return }
        currentExperiment?.result = result
        currentExperiment?.resultReviewed = true
        currentExperiment?.notes = notes
        logger.log("用户实验结果", "结果=\(result.title)；备注=\(notes)")
        session.capture("experiment finish / result save")
        checkpoint(reportFailure: true)
    }
    func sceneChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            sceneIsActive = true
            logger.log("生命周期", hasEnteredBackground ? "Scene active / foreground" : "Scene active")
            hasEnteredBackground = false
            session.capture("foreground")
            refresh()
        case .inactive:
            sceneIsActive = false
            logger.log("生命周期", "Scene inactive")
        case .background:
            sceneIsActive = false
            hasEnteredBackground = true
            logger.log("生命周期", "Scene background")
            session.capture("background")
        @unknown default:
            logger.log("生命周期", "未知 Scene 状态")
        }
        logEngineState()
        checkpoint()
        logger.flush()
    }
    func refresh() {
        // 仅观察和更新 UI；此定时器从不调用 play、schedule 或 resume。
        guard sceneIsActive else { return }
        engine?.observe()
        diagnosticState = engine?.diagnosticState ?? "尚未创建播放器"
        if state == .waiting, let target = currentExperiment?.schedule?.targetUptime {
            remaining = max(0, target - ProcessInfo.processInfo.systemUptime)
        } else { remaining = 0 }
    }
    func checkpoint(reportFailure: Bool = false) {
        guard var experiment = currentExperiment else { return }
        experiment.finalState = state
        experiment.logs = logger.entries(since: logBoundary)
        currentExperiment = experiment
        do { try store.save(experiment) }
        catch { if reportFailure { errorMessage = "实验保存失败，请导出日志。" } }
    }
    private func engineStateChanged(_ value: PlaybackState) {
        state = value
        diagnosticState = engine?.diagnosticState ?? "尚未创建播放器"
        if value == .completed || value == .failed || value == .stopped {
            currentExperiment?.finishedAt = Date()
            session.capture("experiment finish")
            if value == .completed { session.deactivate() }
        }
        checkpoint()
    }
    private func handle(_ event: AudioSessionEvent) {
        logEngineState()
        switch event {
        case .interruptionBegan: engine?.interruptionBegan()
        case .interruptionEnded(let shouldResume):
            guard shouldResume, !userStopped, engine?.state == .interrupted, mediaAvailable else {
                logger.log("恢复决策", "不恢复：系统未建议恢复、用户已停止、媒体服务不可用，或状态不允许。")
                checkpoint()
                return
            }
            do {
                try session.reactivate()
                let resumed = try engine?.resumeIfPossible() ?? false
                logger.log("恢复结果", "恢复调用结果=\(resumed)")
            } catch {
                logger.log("恢复失败", diagnosticError(error))
                errorMessage = "中断后的恢复尝试失败，请保存结果并查看日志。"
            }
        case .mediaLost:
            mediaAvailable = false
            engine?.mediaServicesLost()
        case .mediaReset:
            mediaAvailable = true
            engine?.mediaServicesLost()
            engine?.onStateChange = nil
            engine = nil
            diagnosticState = "媒体服务已重置，等待重新准备"
        case .routeChanged, .silenceHint: break
        }
        logEngineState()
        checkpoint()
    }
    private func logEngineState() {
        diagnosticState = engine?.diagnosticState ?? "尚未创建播放器"
        logger.log("播放状态快照", diagnosticState)
    }
    private func report(_ error: Error, message: String) {
        logger.log("操作失败", diagnosticError(error))
        errorMessage = message
    }
}
