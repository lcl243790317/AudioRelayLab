import AVFAudio
import SwiftUI
import UIKit

@MainActor final class ExperimentCoordinator: ObservableObject {
    let logger: DiagnosticsLogger
    let session: AudioSessionManager
    let store: ExperimentStore
    @Published private(set) var audio: AudioFileMetadata?
    @Published var engineKind: PlaybackEngineKind = .audioPlayer
    @Published var profile: AudioSessionProfile = .mixingPlayback
    @Published var delay: Double = 5
    @Published var volume: Double = 0.5
    @Published var requestedDuration: Double?
    @Published var speakerOverride = false
    @Published var voiceOptimized = false
    @Published private(set) var state: PlaybackState = .idle
    @Published private(set) var currentExperiment: Experiment?
    @Published private(set) var remaining: Double = 0
    @Published private(set) var diagnosticState = "尚未创建播放器"
    @Published private(set) var isImporting = false
    @Published var errorMessage: String?
    @Published private(set) var technicalDetails: String?
    private var machine = ExperimentStateMachine()
    private var engine: (any PlaybackEngineProtocol)?
    private var prepareTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var timer: Timer?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var logBoundary = 0
    private var scenePhase: ScenePhase = .active

    init() {
        let logger = DiagnosticsLogger()
        self.logger = logger
        session = AudioSessionManager(logger: logger)
        store = ExperimentStore(logger: logger)
        logger.log("生命周期", "App 启动；设备=\(DeviceInfo.current().modelIdentifier)；iOS=\(DeviceInfo.current().systemVersion)")
        session.onEvent = { [weak self] event in self?.handle(event) }
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willEnterForegroundNotification] {
            lifecycleObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let background = note.name == UIApplication.didEnterBackgroundNotification
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.logger.log("生命周期", background ? "UIApplication：进入后台" : "UIApplication：进入前台")
                    self.capture(background ? "background" : "foreground")
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
        prepareTask?.cancel()
        importTask?.cancel()
        timer?.invalidate()
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
    }
    var isRunning: Bool { machine.isActive }
    var busy: Bool { isImporting || state == .preparing }
    var controlsLocked: Bool { isImporting || machine.isActive }

    func importAudio(_ url: URL) {
        guard !controlsLocked else { return }
        isImporting = true
        importTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isImporting = false; self.importTask = nil }
            do {
                let work = Task.detached(priority: .userInitiated) { try AudioFileManager.importFile(from: url) }
                let metadata = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
                try Task.checkCancellation()
                self.audio = metadata
                self.requestedDuration = nil
                try self.rememberAudio(metadata)
                self.logger.log("音频导入", "已复制至沙盒并释放安全作用域；时长=\(metadata.duration)s，采样率=\(metadata.sampleRate)，声道=\(metadata.channelCount)，字节数=\(metadata.byteCount)；不记录私人源路径或文件名。")
            } catch { self.report(error, message: "音频导入失败，请选择有效且可读取的音频文件。") }
        }
    }
    func useTestAudio() {
        guard !controlsLocked else { return }
        do {
            let metadata = try AudioFileManager.generateTestAudio()
            audio = metadata
            requestedDuration = nil
            try rememberAudio(metadata)
            logger.log("测试音频", "已生成 11.7s、44100Hz、单声道测试 WAV；10ms 淡入淡出，0.28 峰值。")
        } catch { report(error, message: "测试音频生成失败，请检查存储空间。") }
    }
    private func rememberAudio(_ metadata: AudioFileMetadata) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(metadata), forKey: "selectedAudio")
    }

    func prepare() { beginPreparation(scheduleImmediately: false) }
    func start() { beginPreparation(scheduleImmediately: true) }
    private func beginPreparation(scheduleImmediately: Bool) {
        guard !controlsLocked else {
            logger.log("启动拒绝", "当前实验或文件导入尚未结束，拒绝重复准备。")
            return
        }
        checkpoint()
        currentExperiment = nil
        errorMessage = nil
        technicalDetails = nil
        do {
            guard let audio else { throw LabError.message("请先选择有效的音频文件") }
            try ExperimentParameters.validate(delay: delay, volume: volume, requestedDuration: requestedDuration, audioDuration: audio.duration)
            guard profile.isSelectable, engineKind != .unknown else { throw LabError.message("旧版或未知配置不能用于新实验") }
            let token = try machine.begin()
            state = machine.state
            let settings = ExperimentSettings(engine: engineKind, profile: profile, delay: delay, volume: Float(volume),
                voiceOptimized: voiceOptimized && engineKind == .audioEngine,
                speakerOverride: speakerOverride && profile.usesInput, requestedDuration: requestedDuration)
            let id = UUID()
            logBoundary = logger.nextSequence
            logger.setExperimentID(id)
            currentExperiment = Experiment(id: id, date: Date(), device: DeviceInfo.current(), audio: audio, settings: settings,
                schedule: nil, finalState: .preparing, result: .uncertain, resultReviewed: false, notes: "", finishedAt: nil, logs: [])
            logger.log("实验请求", "开始准备；引擎=\(settings.engine.rawValue)，配置=\(settings.profile.rawValue)，延迟=\(settings.delay)s，时长=\(settings.requestedDuration.map { String($0) } ?? "完整文件")，App音量=\(settings.volume)")
            capture("prepare request")
            checkpoint()
            prepareTask = Task { [weak self] in
                guard let self else { return }
                var localEngine: (any PlaybackEngineProtocol)?
                defer { if self.machine.generation == token { self.prepareTask = nil } }
                do {
                    try Task.checkCancellation()
                    guard self.machine.generation == token, self.machine.state == .preparing,
                        self.scenePhase != .background else { throw CancellationError() }
                    try self.session.beginManualAttempt()
                    if settings.profile.usesInput {
                        let granted = await withCheckedContinuation { continuation in
                            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
                        }
                        guard granted else { throw LabError.message("此配置需要麦克风权限；请在系统设置允许，或改用 A / E。") }
                    }
                    try Task.checkCancellation()
                    guard self.machine.generation == token, self.machine.state == .preparing,
                        self.scenePhase != .background else { throw CancellationError() }
                    try self.session.configure(profile: settings.profile, speakerOverride: settings.speakerOverride)
                    try Task.checkCancellation()
                    guard self.machine.generation == token, self.machine.state == .preparing else { throw CancellationError() }
                    self.capture("session activated")
                    let validate: () throws -> Void = { [weak session = self.session] in
                        guard let session else { throw LabError.audioUnavailable }
                        try session.validateForPlayback()
                    }
                    let newEngine: any PlaybackEngineProtocol
                    switch settings.engine {
                    case .audioPlayer: newEngine = AVAudioPlayerPlaybackEngine(logger: self.logger, validateEnvironment: validate)
                    case .audioEngine: newEngine = AVAudioEnginePlaybackEngine(logger: self.logger, validateEnvironment: validate)
                    case .unknown: throw LabError.message("未知播放引擎不能用于新实验")
                    }
                    localEngine = newEngine
                    self.engine = newEngine
                    newEngine.volume = settings.volume
                    newEngine.onStateChange = { [weak self] value in self?.engineStateChanged(value, token: token) }
                    let url = try AudioFileManager.url(for: audio)
                    try await newEngine.prepare(url: url, voiceOptimized: settings.voiceOptimized, requestedDuration: settings.requestedDuration)
                    try Task.checkCancellation()
                    guard self.machine.generation == token, self.machine.state == .prepared else { throw CancellationError() }
                    try self.session.validateForPlayback()
                    self.capture("prepare complete")
                    self.checkpoint()
                    if scheduleImmediately, self.scenePhase == .active { self.startPrepared() }
                } catch {
                    localEngine?.onStateChange = nil
                    localEngine?.teardown()
                    guard self.machine.generation == token else { return }
                    guard self.machine.isActive else { self.session.deactivate(); return }
                    if error is CancellationError { self.stop() }
                    else { self.fail(error, token: token) }
                }
            }
        } catch {
            if let token = try? machine.begin() { fail(error, token: token) }
            else { report(error, message: userFacingAudioError(error)) }
        }
    }
    func startPrepared() {
        guard state == .prepared, let engine, let experiment = currentExperiment else { return }
        let token = machine.generation
        do {
            guard scenePhase == .active else { throw LabError.message("请回到前台后再开始实验") }
            try session.validateForPlayback()
            capture("schedule 前")
            currentExperiment?.schedule = try engine.schedule(delay: experiment.settings.delay, requestedTime: Date())
            remaining = experiment.settings.delay
            capture("schedule 后")
            logEngineState()
            checkpoint()
        } catch { fail(error, token: token) }
    }
    func stop() {
        guard machine.isActive else { return }
        prepareTask?.cancel()
        prepareTask = nil
        engine?.onStateChange = nil
        engine?.stop()
        engine?.teardown()
        engine = nil
        machine.cancel()
        state = machine.state
        remaining = 0
        finish()
    }
    private func fail(_ error: Error, token: UUID) {
        guard machine.generation == token, machine.isActive else { return }
        prepareTask?.cancel()
        prepareTask = nil
        engine?.onStateChange = nil
        engine?.teardown()
        engine = nil
        guard machine.transition(to: .failed, for: token) else { return }
        state = machine.state
        technicalDetails = diagnosticError(error)
        errorMessage = userFacingAudioError(error)
        currentExperiment?.errorDetails.append(diagnosticError(error))
        logger.log("实验错误", diagnosticError(error))
        remaining = 0
        finish()
    }
    private func finish() {
        currentExperiment?.finishedAt = Date()
        capture("experiment finish")
        session.deactivate()
        currentExperiment?.sessionSnapshots.append(session.capture("cleanup complete"))
        logger.log("实验结束", "最终状态=\(state.rawValue)")
        checkpoint()
        logger.flush()
        logger.setExperimentID(nil)
        diagnosticState = "本次实验已结束，播放对象已释放；可重新准备。"
    }
    private func engineStateChanged(_ value: PlaybackState, token: UUID) {
        guard token == machine.generation, machine.isActive else { return }
        if value == .preparing, machine.state == .preparing { return }
        if value == .failed { fail(LabError.message("当前播放路径已失效，实验已安全结束。请查看诊断后重新准备。"), token: token); return }
        guard machine.transition(to: value, for: token) else {
            logger.log("状态转换拒绝", "\(machine.state.rawValue) → \(value.rawValue)")
            return
        }
        state = machine.state
        diagnosticState = engine?.diagnosticState ?? "播放对象已释放"
        if value == .completed {
            engine?.onStateChange = nil
            engine?.teardown()
            engine = nil
            remaining = 0
            finish()
        } else { checkpoint() }
    }
    func saveResult(result: ExperimentResult, notes: String) {
        guard let id = currentExperiment?.id else { return }
        currentExperiment?.result = result
        currentExperiment?.resultReviewed = true
        currentExperiment?.notes = notes
        logger.log("用户实验结果", "结果=\(result.title)；备注已保存在实验记录，不复制到自动诊断。", explicitExperimentID: id)
        checkpoint(reportFailure: true)
    }
    func sceneChanged(_ phase: ScenePhase) {
        scenePhase = phase
        switch phase {
        case .active: logger.log("生命周期", "Scene active / foreground"); capture("foreground"); refresh()
        case .inactive: logger.log("生命周期", "Scene inactive")
        case .background:
            logger.log("生命周期", "Scene background")
            capture("background")
            if state == .preparing || state == .prepared {
                logger.log("准备取消", "尚未调度的实验进入后台，释放准备资源。")
                stop()
            }
        @unknown default: logger.log("生命周期", "未知 Scene 状态")
        }
        logEngineState()
        checkpoint()
        logger.flush()
    }
    func refresh() {
        guard scenePhase == .active else { return }
        // UI Timer 只观察，绝不调用 play / schedule / resume。
        engine?.observe()
        if let engine { diagnosticState = engine.diagnosticState }
        if state == .waiting, let target = currentExperiment?.schedule?.targetUptime { remaining = max(0, target - ProcessInfo.processInfo.systemUptime) }
        else { remaining = 0 }
    }
    func checkpoint(reportFailure: Bool = false) {
        guard var experiment = currentExperiment else { return }
        experiment.finalState = state
        experiment.logs = logger.entries(since: logBoundary).filter { $0.experimentID == experiment.id }
        currentExperiment = experiment
        do { try store.save(experiment) }
        catch { if reportFailure { errorMessage = "实验保存失败，请导出诊断日志。"; technicalDetails = diagnosticError(error) } }
    }
    private func capture(_ reason: String) {
        let snapshot = session.capture(reason)
        if machine.isActive || reason == "experiment finish" { currentExperiment?.sessionSnapshots.append(snapshot) }
    }
    private func handle(_ event: AudioSessionEvent) {
        let token = machine.generation
        logEngineState()
        switch event {
        case .interruptionBegan:
            capture("interruption began")
            if state == .preparing || state == .prepared { fail(LabError.audioUnavailable, token: token) }
            else if machine.isActive { engine?.interruptionBegan() }
        case .interruptionEnded(let shouldResume):
            capture("interruption ended")
            guard state == .interrupted else { break }
            guard shouldResume, machine.claimRecovery(for: token) else {
                logger.log("恢复决策", "不再恢复：系统未建议恢复或本实验已用完一次恢复预算。")
                fail(LabError.audioUnavailable, token: token)
                return
            }
            logger.log("恢复尝试", "第 1 次也是本实验唯一一次自动恢复尝试")
            do {
                try session.reactivate()
                guard try engine?.resumeIfPossible() == true else { throw LabError.audioUnavailable }
                capture("recovery complete")
                logger.log("恢复结果", "恢复调用成功；实际发声仍需观察。")
            } catch { logger.log("恢复失败", diagnosticError(error)); fail(error, token: token) }
        case .routeChanged:
            capture("route changed")
            if state == .prepared || state == .waiting || state == .playing {
                do { try session.validateForPlayback() }
                catch { fail(error, token: token) }
            }
        case .mediaLost, .mediaReset:
            engine?.onStateChange = nil
            engine?.mediaServicesLost()
            engine = nil
            if machine.isActive { fail(LabError.audioUnavailable, token: token) }
        case .environmentUnavailable:
            if machine.isActive { fail(LabError.audioUnavailable, token: token) }
        case .silenceHint: capture("silence hint")
        }
        checkpoint()
    }
    private func logEngineState() {
        if let engine { diagnosticState = engine.diagnosticState }
        logger.log("播放状态快照", diagnosticState)
    }
    private func report(_ error: Error, message: String) {
        logger.log("操作失败", diagnosticError(error))
        technicalDetails = diagnosticError(error)
        errorMessage = message
    }
}
