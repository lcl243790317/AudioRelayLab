import AVFAudio

@MainActor final class AVAudioPlayerPlaybackEngine: NSObject, PlaybackEngineProtocol, AVAudioPlayerDelegate {
    let kind: PlaybackEngineKind = .audioPlayer
    private(set) var state: PlaybackState = .idle
    var onStateChange: ((PlaybackState) -> Void)?
    private let logger: DiagnosticsLogger
    private let validateEnvironment: () throws -> Void
    private var player: AVAudioPlayer?
    private var targetDeviceTime: TimeInterval?
    private var processedURL: URL?
    private var requestedDuration: TimeInterval?
    private var observed = false
    private var previousTime: TimeInterval = 0
    private var startOffset: TimeInterval = 0
    private var playbackRate: Float = 1
    var nativeRate: Float? { player?.rate }
    var nativePlaybackTime: TimeInterval? { player?.currentTime }
    var volume: Float = 0.5 { didSet { if volume.isFinite { player?.volume = min(1, max(0, volume)) } } }

    init(logger: DiagnosticsLogger, validateEnvironment: @escaping () throws -> Void) {
        self.logger = logger
        self.validateEnvironment = validateEnvironment
    }
    deinit { if let processedURL { try? FileManager.default.removeItem(at: processedURL) } }
    var diagnosticState: String {
        "引擎=AVAudioPlayer，状态=\(state.title)，isPlaying=\(player?.isPlaying ?? false)，currentTime=\(player?.currentTime ?? 0)，deviceCurrentTime=\(player?.deviceCurrentTime ?? 0)，实际播放器音量=\(player?.volume ?? volume)，目标设备时间=\(targetDeviceTime.map(String.init(describing:)) ?? "无")"
    }
    private func setState(_ value: PlaybackState) {
        guard state != value else { return }
        state = value
        logger.log("播放器状态", diagnosticState)
        onStateChange?(value)
    }
    func prepare(url: URL, voiceOptimized: Bool, requestedDuration: TimeInterval?, startOffset: TimeInterval = 0, playbackRate: Float = 1) async throws {
        teardown()
        observed = false
        previousTime = 0
        self.requestedDuration = requestedDuration
        self.startOffset = startOffset
        self.playbackRate = playbackRate
        setState(.preparing)
        do {
            try validateEnvironment()
            guard volume.isFinite, (0...1).contains(volume) else { throw LabError.message("播放器音量不合法") }
            if let requestedDuration {
                guard requestedDuration.isFinite, (0.1...600).contains(requestedDuration) else { throw LabError.invalidFormat }
            }
            let source = try AVAudioFile(forReading: url)
            try AudioRuntimeValidation.validate(source.processingFormat)
            guard source.length > 0 else { throw LabError.invalidFormat }
            let totalDuration = Double(source.length) / source.processingFormat.sampleRate
            _ = try AudioPlaybackSettings(startOffset: startOffset, playbackRate: playbackRate, volume: volume).validated(duration: totalDuration)
            let playbackURL: URL
            let cropped = requestedDuration.map { $0 < totalDuration - startOffset } ?? false
            if playbackRate != 1 {
                logger.log("倍速准备", "先渲染源起点/倍速；未来等待用 1x 设备时钟，不缩放延迟")
                let work = Task.detached(priority: .userInitiated) {
                    try RateAdjustedAudio.copy(of:url,startOffset:startOffset,rate:playbackRate,duration:requestedDuration)
                }
                playbackURL = try await withTaskCancellationHandler(operation: { try await work.value },onCancel:{ work.cancel() })
                processedURL = playbackURL
            } else if let requestedDuration, cropped {
                let work = Task.detached(priority: .userInitiated) { try AudioProcessor.trimmedCopy(of: url, duration: requestedDuration, startOffset: startOffset) }
                playbackURL = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
                processedURL = playbackURL
            } else { playbackURL = url }
            try Task.checkCancellation()
            try validateEnvironment()
            let newPlayer = try AVAudioPlayer(contentsOf: playbackURL)
            newPlayer.delegate = self
            newPlayer.volume = volume
            newPlayer.enableRate = false
            newPlayer.rate = 1
            newPlayer.currentTime = cropped || playbackRate != 1 ? 0 : startOffset
            previousTime = newPlayer.currentTime
            player = newPlayer
            guard newPlayer.prepareToPlay(), newPlayer.duration.isFinite, newPlayer.duration > 0 else { throw LabError.audioUnavailable }
            logger.log("播放器准备", "prepareToPlay 成功；源起点=\(startOffset)s；源倍速=\(playbackRate)，实际 player.rate=\(newPlayer.rate)；currentTime=\(newPlayer.currentTime)；实际时长=\(newPlayer.duration)s；实际播放器音量=\(newPlayer.volume)。")
            setState(.prepared)
        } catch {
            teardown()
            throw error
        }
    }
    func schedule(delay: TimeInterval, requestedTime: Date) throws -> PlaybackSchedule {
        guard let player, state == .prepared, delay.isFinite, (0.1...60).contains(delay) else { throw LabError.audioUnavailable }
        try validateEnvironment()
        let callTime = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        let deviceTime = player.deviceCurrentTime
        let target = deviceTime + delay
        guard deviceTime.isFinite, target.isFinite else { throw LabError.invalidFormat }
        targetDeviceTime = target
        logger.log("调度调用", "deviceCurrentTime=\(deviceTime)，延迟=\(delay)s，目标设备时间=\(target)")
        let accepted = player.play(atTime: target)
        logger.log("调度返回", "play(atTime:) 返回=\(accepted)；提前的 isPlaying 不能证明发声；\(diagnosticState)")
        guard accepted else { throw LabError.audioUnavailable }
        setState(.waiting)
        return PlaybackSchedule(requestedTime: requestedTime, scheduleCallTime: callTime,
            requestedDelay: delay, targetUptime: uptime + delay, audioClock: "AVAudioPlayer.deviceCurrentTime",
            scheduledAudioTime: String(format: "%.9f", target), accepted: accepted, requestedDuration: requestedDuration, startOffset: startOffset, playbackRate: playbackRate)
    }
    func observe() {
        guard let player, state == .waiting || state == .playing else { return }
        let current = player.currentTime
        if !observed, player.isPlaying, player.deviceCurrentTime >= (targetDeviceTime ?? .infinity), current > previousTime + 0.001 {
            observed = true
            logger.log("可观察播放开始", "currentTime=\(current)s，deviceCurrentTime=\(player.deviceCurrentTime)；前台采样不能确定声学起始时间。")
            setState(.playing)
        }
        previousTime = current
    }
    func stop() {
        teardown()
        logger.log("主动停止", "AVAudioPlayer 已取消，delegate 已解绑。")
        setState(.cancelled)
    }
    func interruptionBegan() {
        guard state.canInterrupt else { return }
        logger.log("中断前播放器", diagnosticState)
        player?.pause()
        setState(.interrupted)
    }
    func resumeIfPossible() throws -> Bool {
        guard state == .interrupted, let player, player.currentTime < player.duration else { return false }
        try validateEnvironment()
        let deviceTime = player.deviceCurrentTime
        guard deviceTime.isFinite else { throw LabError.invalidFormat }
        let accepted: Bool
        if let targetDeviceTime, targetDeviceTime > deviceTime { accepted = player.play(atTime: targetDeviceTime) }
        else {
            accepted = player.play()
            targetDeviceTime = deviceTime
        }
        guard accepted else { throw LabError.audioUnavailable }
        observed = false
        previousTime = player.currentTime
        logger.log("播放器恢复", "恢复调用返回=true；这是新的播放尝试，不代表原调度连续执行；\(diagnosticState)")
        setState(.waiting)
        return true
    }
    func teardown() {
        player?.delegate = nil
        player?.stop()
        player = nil
        targetDeviceTime = nil
        if let processedURL {
            do { try FileManager.default.removeItem(at: processedURL) }
            catch { logger.log("临时音频清理失败", diagnosticError(error)) }
        }
        processedURL = nil
    }
    func mediaServicesLost() {
        player?.delegate = nil
        player = nil
        if let processedURL { try? FileManager.default.removeItem(at: processedURL) }
        processedURL = nil
        setState(.failed)
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self, weak player] in
            guard let self, let player, self.player === player,
                self.state == .waiting || self.state == .playing else { return }
            self.logger.log("播放完成回调", "AVAudioPlayer successfully=\(flag)；不能证明微信录入。")
            self.teardown()
            self.setState(flag ? .completed : .failed)
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let details = error.map(diagnosticError) ?? "系统未提供具体错误"
        Task { @MainActor [weak self, weak player] in
            guard let self, let player, self.player === player,
                self.state == .waiting || self.state == .playing || self.state == .prepared else { return }
            self.logger.log("解码失败", details)
            self.teardown()
            self.setState(.failed)
        }
    }
}
