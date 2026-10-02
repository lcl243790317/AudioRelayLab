import AVFAudio

@MainActor final class AVAudioPlayerPlaybackEngine: NSObject, PlaybackEngineProtocol, AVAudioPlayerDelegate {
    let kind: PlaybackEngineKind = .audioPlayer
    private(set) var state: PlaybackState = .idle
    var onStateChange: ((PlaybackState) -> Void)?
    private let logger: DiagnosticsLogger
    private var player: AVAudioPlayer?
    private var scheduleInfo: PlaybackSchedule?
    private var targetDeviceTime: TimeInterval?
    private var userStopped = false
    private var observed = false
    private var previousTime: TimeInterval = 0
    var volume: Float = 0.5 { didSet { player?.volume = min(1, max(0, volume)) } }

    init(logger: DiagnosticsLogger) { self.logger = logger }
    var diagnosticState: String {
        "引擎=AVAudioPlayer，状态=\(state.title)，isPlaying=\(player?.isPlaying ?? false)，currentTime=\(player?.currentTime ?? 0)，deviceCurrentTime=\(player?.deviceCurrentTime ?? 0)，目标设备时间=\(targetDeviceTime.map(String.init(describing:)) ?? "无")"
    }
    private func setState(_ value: PlaybackState) {
        guard state != value else { return }
        state = value
        logger.log("播放器状态", diagnosticState)
        onStateChange?(value)
    }
    func prepare(url: URL, voiceOptimized: Bool) throws {
        userStopped = false
        observed = false
        scheduleInfo = nil
        targetDeviceTime = nil
        previousTime = 0
        let newPlayer = try AVAudioPlayer(contentsOf: url)
        newPlayer.delegate = self
        newPlayer.volume = volume
        guard newPlayer.prepareToPlay() else { throw LabError.message("音频播放器准备失败") }
        player = newPlayer
        logger.log("播放器准备", "prepareToPlay 成功；时长=\(newPlayer.duration)s；deviceCurrentTime=\(newPlayer.deviceCurrentTime)；语音优化未用于此路径。")
        setState(.prepared)
    }
    func schedule(delay: TimeInterval, requestedTime: Date) throws -> PlaybackSchedule {
        guard let player, state == .prepared else { throw LabError.message("播放器尚未准备") }
        let callTime = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        let deviceTime = player.deviceCurrentTime
        let target = deviceTime + delay
        targetDeviceTime = target
        logger.log("调度调用", "请求时间=\(requestedTime)；调用时间=\(callTime)；deviceCurrentTime=\(deviceTime)；延迟=\(delay)s；目标设备时间=\(target)")
        let accepted = player.play(atTime: target)
        let result = PlaybackSchedule(requestedTime: requestedTime, scheduleCallTime: callTime,
            requestedDelay: delay, targetUptime: uptime + delay, audioClock: "AVAudioPlayer.deviceCurrentTime",
            scheduledAudioTime: String(format: "%.9f", target), accepted: accepted)
        scheduleInfo = result
        logger.log("调度返回", "play(atTime:) 返回=\(accepted)；isPlaying=\(player.isPlaying)。提前返回的 isPlaying 不能确认实际发声。无法直接确认实际扬声器起始时间。")
        guard accepted else { setState(.failed); throw LabError.message("系统拒绝了未来时间播放请求") }
        setState(.waiting)
        return result
    }
    func observe() {
        guard let player, state == .waiting || state == .playing else { return }
        let current = player.currentTime
        if !observed, player.isPlaying, player.deviceCurrentTime >= (targetDeviceTime ?? .infinity), current > previousTime + 0.001 {
            observed = true
            logger.log("可观察播放开始", "首次在前台采样观察到 isPlaying=true 且 currentTime 推进至 \(current)s；deviceCurrentTime=\(player.deviceCurrentTime)。采样可能晚于发声；无法直接确认实际扬声器起始时间。")
            setState(.playing)
        }
        previousTime = current
    }
    func stop() {
        userStopped = true
        player?.stop()
        logger.log("主动停止", diagnosticState)
        setState(.stopped)
    }
    func interruptionBegan() {
        guard state.canInterrupt else { return }
        logger.log("中断前播放器", diagnosticState)
        player?.pause()
        setState(.interrupted)
    }
    func resumeIfPossible() throws -> Bool {
        guard !userStopped, state == .interrupted, let player, player.currentTime < player.duration else { return false }
        let deviceTime = player.deviceCurrentTime
        // 若原目标仍在未来，保留目标；否则明确记录恢复为新的立即播放尝试。
        let result: Bool
        if let targetDeviceTime, targetDeviceTime > deviceTime {
            result = player.play(atTime: targetDeviceTime)
            if result { setState(.waiting) }
        } else {
            result = player.play()
            targetDeviceTime = deviceTime
            observed = false
            previousTime = player.currentTime
            if result { setState(.waiting) }
        }
        logger.log("播放器恢复", "恢复返回=\(result)；\(diagnosticState)。恢复是新的播放尝试，不代表原调度连续执行。")
        if !result { setState(.failed) }
        return result
    }
    func mediaServicesLost() {
        userStopped = true
        player = nil
        setState(.failed)
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self, weak player] in
            guard let self, let player, self.player === player, !self.userStopped else { return }
            self.logger.log("播放完成回调", "AVAudioPlayer successfully=\(flag)；currentTime=\(player.currentTime)。回调不能证明微信录入成功。")
            self.setState(flag ? .completed : .failed)
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let details = error.map(diagnosticError) ?? "系统未提供具体错误"
        Task { @MainActor [weak self, weak player] in
            guard let self, let player, self.player === player else { return }
            self.logger.log("解码失败", details)
            self.setState(.failed)
        }
    }
}
