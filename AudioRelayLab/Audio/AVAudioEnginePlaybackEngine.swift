import AVFAudio
import Darwin

@MainActor final class AVAudioEnginePlaybackEngine: PlaybackEngineProtocol {
    let kind: PlaybackEngineKind = .audioEngine
    private(set) var state: PlaybackState = .idle
    var onStateChange: ((PlaybackState) -> Void)?
    var volume: Float = 0.5 { didSet { if volume.isFinite { node?.volume = min(1, max(0, volume)) } } }
    private let logger: DiagnosticsLogger
    private let validateEnvironment: () throws -> Void
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var eq: AVAudioUnitEQ?
    private var file: AVAudioFile?
    private var processedURL: URL?
    private var configurationObserver: NSObjectProtocol?
    private var generation = UUID()
    private var graphGeneration = UUID()
    private var targetHostTime: UInt64?
    private var startFrame: AVAudioFramePosition = 0
    private var resumeFrame: AVAudioFramePosition = 0
    private var endFrame: AVAudioFramePosition = 0
    private var observed = false
    private var voiceOptimized = false
    private var requestedDuration: TimeInterval?

    init(logger: DiagnosticsLogger, validateEnvironment: @escaping () throws -> Void) {
        self.logger = logger
        self.validateEnvironment = validateEnvironment
    }
    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        if let processedURL { try? FileManager.default.removeItem(at: processedURL) }
    }
    var diagnosticState: String {
        let timeline = currentTimeline()
        return "引擎=AVAudioEngine，状态=\(state.title)，isRunning=\(engine?.isRunning ?? false)，node.isPlaying=\(node?.isPlaying ?? false)，实际播放器音量=\(node?.volume ?? volume)，playerSampleTime=\(timeline?.sampleTime ?? -1)，恢复帧=\(resumeFrame)，结束帧=\(endFrame)，目标hostTime=\(targetHostTime ?? 0)"
    }
    private func currentTimeline() -> AVAudioTime? {
        guard let engine, engine.isRunning, let node, let render = node.lastRenderTime,
            render.isHostTimeValid else { return nil }
        return node.playerTime(forNodeTime: render)
    }
    private func setState(_ value: PlaybackState) {
        guard state != value else { return }
        state = value
        logger.log("引擎状态", diagnosticState)
        onStateChange?(value)
    }
    func prepare(url: URL, voiceOptimized: Bool, requestedDuration: TimeInterval?) async throws {
        teardown()
        self.voiceOptimized = voiceOptimized
        self.requestedDuration = requestedDuration
        observed = false
        startFrame = 0
        resumeFrame = 0
        setState(.preparing)
        do {
            try validateEnvironment()
            let playbackURL: URL
            if voiceOptimized {
                let work = Task.detached(priority: .userInitiated) { try AudioProcessor.optimizedCopy(of: url) }
                playbackURL = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
                processedURL = playbackURL
                logger.log("语音优化", "已创建独立单声道副本；原文件未修改。")
            } else { playbackURL = url }
            try Task.checkCancellation()
            try validateEnvironment()
            let newFile = try AVAudioFile(forReading: playbackURL)
            try AudioRuntimeValidation.validate(newFile.processingFormat)
            guard newFile.length > 0 else { throw LabError.invalidFormat }
            let frames: AVAudioFramePosition
            if let requestedDuration {
                guard requestedDuration.isFinite, (0.1...600).contains(requestedDuration) else { throw LabError.invalidFormat }
                frames = min(newFile.length, AVAudioFramePosition((requestedDuration * newFile.processingFormat.sampleRate).rounded(.down)))
            } else { frames = newFile.length }
            guard frames > 0, frames <= AVAudioFramePosition(UInt32.max), volume.isFinite, (0...1).contains(volume) else {
                throw LabError.message("音频时长或音量超出安全调度范围")
            }
            endFrame = frames
            file = newFile
            try buildGraph()
            logger.log("引擎准备", "格式采样率=\(newFile.processingFormat.sampleRate)，声道=\(newFile.processingFormat.channelCount)，调度帧数=\(frames)；\(diagnosticState)")
            setState(.prepared)
        } catch {
            teardown()
            throw error
        }
    }
    private func buildGraph() throws {
        try validateEnvironment()
        guard let file else { throw LabError.invalidFormat }
        try AudioRuntimeValidation.validate(file.processingFormat)
        // 仅在会话激活及硬件路由验证之后创建 Engine；本应用不访问 inputNode。
        let newEngine = AVAudioEngine()
        let newNode = AVAudioPlayerNode()
        try AudioRuntimeValidation.validate(newEngine.outputNode.inputFormat(forBus: 0))
        try validateEnvironment()
        newEngine.attach(newNode)
        engine = newEngine
        node = newNode
        if voiceOptimized {
            let newEQ = AVAudioUnitEQ(numberOfBands: 2)
            AudioProcessor.configure(eq: newEQ, sampleRate: file.processingFormat.sampleRate)
            newEngine.attach(newEQ)
            newEngine.connect(newNode, to: newEQ, format: file.processingFormat)
            newEngine.connect(newEQ, to: newEngine.mainMixerNode, format: file.processingFormat)
            eq = newEQ
        } else {
            newEngine.connect(newNode, to: newEngine.mainMixerNode, format: file.processingFormat)
        }
        newNode.volume = volume
        let graphToken = UUID()
        graphGeneration = graphToken
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: newEngine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.graphGeneration == graphToken else { return }
                self.configurationChanged()
            }
        }
        try validateEnvironment()
        try AudioRuntimeValidation.validate(newEngine.outputNode.inputFormat(forBus: 0))
        newEngine.prepare()
        try newEngine.start()
        guard newEngine.isRunning else { throw LabError.audioUnavailable }
    }
    func schedule(delay: TimeInterval, requestedTime: Date) throws -> PlaybackSchedule {
        guard state == .prepared, engine?.isRunning == true,
            delay.isFinite, (0.1...60).contains(delay) else { throw LabError.audioUnavailable }
        try validateEnvironment()
        let callTime = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        let now = mach_absolute_time()
        let addition = now.addingReportingOverflow(AVAudioTime.hostTime(forSeconds: delay))
        guard !addition.overflow else { throw LabError.message("播放目标时间超出范围") }
        targetHostTime = addition.partialValue
        logger.log("调度调用", "当前hostTime=\(now)，延迟=\(delay)s，目标hostTime=\(addition.partialValue)")
        try enqueue(from: 0, at: addition.partialValue)
        setState(.waiting)
        logger.log("调度返回", "scheduleSegment + play(at:) 已调用；此 API 无 Bool 返回值；\(diagnosticState)。无法直接确认扬声器起始时间。")
        return PlaybackSchedule(requestedTime: requestedTime, scheduleCallTime: callTime,
            requestedDelay: delay, targetUptime: uptime + delay, audioClock: "mach_absolute_time / AVAudioTime.hostTime",
            scheduledAudioTime: String(addition.partialValue), accepted: true, requestedDuration: requestedDuration)
    }
    private func enqueue(from frame: AVAudioFramePosition, at hostTime: UInt64) throws {
        try validateEnvironment()
        guard let file, let engine, let node, engine.isRunning,
            frame >= 0, frame < endFrame, endFrame <= file.length else { throw LabError.invalidFormat }
        try AudioRuntimeValidation.validate(engine.outputNode.inputFormat(forBus: 0))
        generation = UUID()
        let token = generation
        startFrame = frame
        observed = false
        node.scheduleSegment(file, startingFrame: frame, frameCount: AVAudioFrameCount(endFrame - frame),
            at: nil, completionCallbackType: .dataPlayedBack) { [weak self] callbackType in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token,
                    self.state == .waiting || self.state == .playing else { return }
                self.logger.log("播放完成回调", "AVAudioPlayerNode dataPlayedBack，类型=\(callbackType.rawValue)；不代表微信收录。")
                self.teardown()
                self.setState(.completed)
            }
        }
        node.prepare(withFrameCount: AVAudioFrameCount(min(endFrame - frame, 8192)))
        node.play(at: AVAudioTime(hostTime: hostTime))
    }
    func observe() {
        guard state == .waiting || state == .playing else { return }
        guard engine?.isRunning == true else {
            logger.log("引擎错误", "观察到 Engine 已停止，安全结束本次实验。")
            teardown()
            setState(.failed)
            return
        }
        if let time = currentTimeline(), time.isSampleTimeValid, time.sampleRate.isFinite, time.sampleRate > 0 {
            resumeFrame = min(endFrame, startFrame + max(0, time.sampleTime))
            if !observed, node?.isPlaying == true, mach_absolute_time() >= (targetHostTime ?? UInt64.max), time.sampleTime > 0 {
                observed = true
                logger.log("可观察播放开始", "sampleTime=\(time.sampleTime)，sampleRate=\(time.sampleRate)；采样可能晚于实际发声。")
                setState(.playing)
            }
        }
    }
    func interruptionBegan() {
        guard state.canInterrupt else { return }
        if let time = currentTimeline(), time.isSampleTimeValid { resumeFrame = min(endFrame, startFrame + max(0, time.sampleTime)) }
        releaseGraph()
        logger.log("引擎中断", "旧图与队列已释放；最近可观察恢复位置=\(resumeFrame)帧。")
        setState(.interrupted)
    }
    func resumeIfPossible() throws -> Bool {
        guard state == .interrupted, file != nil, resumeFrame < endFrame else { return false }
        try validateEnvironment()
        try buildGraph()
        let target = mach_absolute_time().addingReportingOverflow(AVAudioTime.hostTime(forSeconds: 0.05))
        guard !target.overflow else { throw LabError.invalidFormat }
        let hostTime = max(targetHostTime ?? target.partialValue, target.partialValue)
        targetHostTime = hostTime
        try enqueue(from: resumeFrame, at: hostTime)
        logger.log("引擎恢复", "新图从最近可观察帧 \(resumeFrame) 重新调度；不代表原调度连续执行。")
        setState(.waiting)
        return true
    }
    func stop() {
        teardown()
        logger.log("主动停止", "Engine 已取消，旧回调已失效。")
        setState(.cancelled)
    }
    func teardown() {
        releaseGraph()
        file = nil
        if let processedURL {
            do { try FileManager.default.removeItem(at: processedURL) }
            catch { logger.log("临时音频清理失败", diagnosticError(error)) }
        }
        processedURL = nil
        targetHostTime = nil
    }
    private func releaseGraph(stopHardware: Bool = true) {
        generation = UUID()
        graphGeneration = UUID()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        if stopHardware {
            node?.stop()
            engine?.stop()
        }
        node = nil
        eq = nil
        engine = nil
    }
    func mediaServicesLost() {
        releaseGraph(stopHardware: false)
        file = nil
        if let processedURL { try? FileManager.default.removeItem(at: processedURL) }
        processedURL = nil
        setState(.failed)
    }
    private func configurationChanged() {
        logger.log("引擎配置变化", "当前硬件配置已改变；不复用旧图。")
        logger.log("音频会话快照", AudioSessionSnapshot().summary)
        if state.canInterrupt || state == .interrupted {
            teardown()
            setState(.failed)
        }
    }
}
