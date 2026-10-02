import AVFAudio
import Darwin

@MainActor final class AVAudioEnginePlaybackEngine: PlaybackEngineProtocol {
    let kind: PlaybackEngineKind = .audioEngine
    private(set) var state: PlaybackState = .idle
    var onStateChange: ((PlaybackState) -> Void)?
    var volume: Float = 0.5 { didSet { node.volume = min(1, max(0, volume)) } }
    private let logger: DiagnosticsLogger
    private var engine = AVAudioEngine()
    private var node = AVAudioPlayerNode()
    private var eq: AVAudioUnitEQ?
    private var file: AVAudioFile?
    private var processedURL: URL?
    private var configurationObserver: NSObjectProtocol?
    private var generation = UUID()
    private var userStopped = false
    private var targetHostTime: UInt64?
    private var startFrame: AVAudioFramePosition = 0
    private var resumeFrame: AVAudioFramePosition = 0
    private var observed = false
    private var previousSampleTime: AVAudioFramePosition = 0

    init(logger: DiagnosticsLogger) { self.logger = logger }
    deinit { if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) } }
    var diagnosticState: String {
        let render = node.lastRenderTime
        let timeline = render.flatMap { node.playerTime(forNodeTime: $0) }
        return "引擎=AVAudioEngine，状态=\(state.title)，isRunning=\(engine.isRunning)，node.isPlaying=\(node.isPlaying)，renderHostTime=\(render?.hostTime ?? 0)，playerSampleTime=\(timeline?.sampleTime ?? -1)，起始帧=\(startFrame)，恢复帧=\(resumeFrame)，目标hostTime=\(targetHostTime ?? 0)"
    }
    private func setState(_ value: PlaybackState) {
        guard state != value else { return }
        state = value
        logger.log("引擎状态", diagnosticState)
        onStateChange?(value)
    }
    func prepare(url: URL, voiceOptimized: Bool) throws {
        generation = UUID()
        node.stop()
        engine.stop()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        file = nil
        if let processedURL { try? FileManager.default.removeItem(at: processedURL) }
        processedURL = nil
        engine = AVAudioEngine()
        node = AVAudioPlayerNode()
        userStopped = false
        observed = false
        startFrame = 0
        resumeFrame = 0
        targetHostTime = nil
        let playbackURL: URL
        if voiceOptimized {
            playbackURL = try AudioProcessor.optimizedCopy(of: url)
            processedURL = playbackURL
            logger.log("语音优化", "已创建独立单声道副本；只衰减归一化、轻量动态压缩、幅值保护；引擎使用 120 Hz 高通、最高 7.5 kHz 低通和 -2 dB 余量。原文件未修改。")
        } else { playbackURL = url }
        let newFile = try AVAudioFile(forReading: playbackURL)
        guard newFile.length > 0, newFile.length <= AVAudioFramePosition(UInt32.max) else {
            throw LabError.message("音频长度超出单次调度范围")
        }
        file = newFile
        engine.attach(node)
        if voiceOptimized {
            let newEQ = AVAudioUnitEQ(numberOfBands: 2)
            AudioProcessor.configure(eq: newEQ, sampleRate: newFile.processingFormat.sampleRate)
            engine.attach(newEQ)
            engine.connect(node, to: newEQ, format: newFile.processingFormat)
            engine.connect(newEQ, to: engine.mainMixerNode, format: newFile.processingFormat)
            eq = newEQ
        } else {
            eq = nil
            engine.connect(node, to: engine.mainMixerNode, format: newFile.processingFormat)
        }
        node.volume = volume
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.configurationChanged() }
        }
        engine.prepare()
        try engine.start()
        logger.log("引擎准备", "prepare + start 完成；格式=\(newFile.processingFormat)；帧数=\(newFile.length)；\(diagnosticState)")
        setState(.prepared)
    }
    func schedule(delay: TimeInterval, requestedTime: Date) throws -> PlaybackSchedule {
        guard state == .prepared, engine.isRunning else { throw LabError.message("音频引擎尚未启动") }
        let callTime = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        let nowHostTime = mach_absolute_time()
        let hostTime = nowHostTime + AVAudioTime.hostTime(forSeconds: delay)
        targetHostTime = hostTime
        logger.log("调度调用", "请求时间=\(requestedTime)；调用时间=\(callTime)；当前hostTime=\(nowHostTime)；延迟=\(delay)s；目标hostTime=\(hostTime)")
        try enqueue(from: 0, at: hostTime)
        setState(.waiting)
        logger.log("调度返回", "scheduleSegment 已入队，play(at: AVAudioTime(hostTime:)) 已调用；此 API 无 Bool 返回值。node.isPlaying=\(node.isPlaying)。无法直接确认实际扬声器起始时间。")
        return PlaybackSchedule(requestedTime: requestedTime, scheduleCallTime: callTime,
            requestedDelay: delay, targetUptime: uptime + delay, audioClock: "mach_absolute_time / AVAudioTime.hostTime",
            scheduledAudioTime: String(hostTime), accepted: true)
    }
    private func enqueue(from frame: AVAudioFramePosition, at hostTime: UInt64) throws {
        guard let file, frame < file.length else { throw LabError.message("没有可以继续播放的音频帧") }
        generation = UUID()
        let token = generation
        startFrame = frame
        previousSampleTime = 0
        observed = false
        // 数据从播放器时间线的第 0 帧排队；play(at:) 决定未来 host 时间启动。
        node.scheduleSegment(file, startingFrame: frame, frameCount: AVAudioFrameCount(file.length - frame),
            at: nil, completionCallbackType: .dataPlayedBack) { [weak self] callbackType in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, !self.userStopped,
                    self.state == .waiting || self.state == .playing else { return }
                self.logger.log("播放完成回调", "AVAudioPlayerNode dataPlayedBack，类型=\(callbackType.rawValue)。这是音频系统完成通知，不能证明扬声器发声或微信录入。")
                self.setState(.completed)
                self.node.stop()
                self.engine.stop()
            }
        }
        node.prepare(withFrameCount: AVAudioFrameCount(min(file.length - frame, 8192)))
        node.play(at: AVAudioTime(hostTime: hostTime))
    }
    func observe() {
        guard state == .waiting || state == .playing else { return }
        guard engine.isRunning else {
            logger.log("引擎停止观察", diagnosticState)
            interruptionBegan()
            return
        }
        if let render = node.lastRenderTime, let time = node.playerTime(forNodeTime: render), time.isSampleTimeValid {
            resumeFrame = startFrame + max(0, time.sampleTime)
            if !observed, node.isPlaying, mach_absolute_time() >= (targetHostTime ?? UInt64.max),
                time.sampleTime > previousSampleTime, time.sampleTime > 0 {
                observed = true
                logger.log("可观察播放开始", "首次采样观察到播放器时间线推进：sampleTime=\(time.sampleTime)，sampleRate=\(time.sampleRate)，renderHostTime=\(render.hostTime)。采样可能晚于发声；无法直接确认实际扬声器起始时间。")
                setState(.playing)
            }
            previousSampleTime = time.sampleTime
        }
    }
    func interruptionBegan() {
        guard state.canInterrupt else { return }
        if let render = node.lastRenderTime, let time = node.playerTime(forNodeTime: render), time.isSampleTimeValid {
            resumeFrame = startFrame + max(0, time.sampleTime)
        }
        generation = UUID() // stop 也可能触发 completion；旧回调不能标记自然完成。
        node.stop()
        engine.pause()
        logger.log("引擎中断", "已撤销旧队列；保存可观察位置 \(resumeFrame) 帧。后续恢复会创建新的调度。")
        setState(.interrupted)
    }
    func resumeIfPossible() throws -> Bool {
        guard !userStopped, state == .interrupted, let file, resumeFrame < file.length else { return false }
        if !engine.isRunning { engine.prepare(); try engine.start() }
        let earliest = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05)
        let hostTime = max(targetHostTime ?? earliest, earliest)
        targetHostTime = hostTime
        try enqueue(from: resumeFrame, at: hostTime)
        logger.log("引擎恢复", "已从第 \(resumeFrame) 帧重新调度至 hostTime=\(hostTime)。这是恢复尝试，不代表原调度连续执行。")
        setState(.waiting)
        return true
    }
    func stop() {
        userStopped = true
        generation = UUID()
        node.stop()
        engine.stop()
        logger.log("主动停止", diagnosticState)
        setState(.stopped)
    }
    func mediaServicesLost() {
        userStopped = true
        generation = UUID()
        // 系统已撤销这些对象，释放并在下一次 prepare 时重建完整图。
        setState(.failed)
    }
    private func configurationChanged() {
        logger.log("引擎配置变化", diagnosticState)
        logger.log("音频会话快照", AudioSessionSnapshot().summary)
        if !engine.isRunning, state.canInterrupt { interruptionBegan() }
    }
}
