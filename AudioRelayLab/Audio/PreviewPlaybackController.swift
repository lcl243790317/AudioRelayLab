import AVFAudio
import Combine

@MainActor final class PreviewPlaybackController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    enum State { case idle, preparing, playing, failed }
    @Published private(set) var state: State = .idle
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var errorMessage: String?
    private let session: AudioSessionManager
    private let logger: DiagnosticsLogger
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var token = UUID()
    private var deadline: TimeInterval?
    private var ownsSession = false
    init(session: AudioSessionManager, logger: DiagnosticsLogger) { self.session = session; self.logger = logger }
    deinit { timer?.invalidate() }
    var isActive: Bool { state == .preparing || state == .playing }
    func play(asset: AudioAsset, settings: AudioPlaybackSettings, fiveSeconds: Bool) {
        stop()
        errorMessage = nil
        let currentToken = UUID(); token = currentToken
        state = .preparing
        do {
            _ = try settings.validated(duration: asset.duration)
            try session.beginManualAttempt()
            try session.configure(profile: .mixingPlayback, speakerOverride: false)
            ownsSession = true
            guard token == currentToken, state == .preparing else { throw CancellationError() }
            let next = try AVAudioPlayer(contentsOf: AudioFileManager.url(for: asset))
            next.enableRate = true; next.rate = settings.playbackRate; next.volume = settings.volume
            next.currentTime = settings.startOffset; next.delegate = self
            player = next
            try session.validateForPlayback()
            guard next.prepareToPlay(), next.play() else { throw LabError.audioUnavailable }
            currentTime = next.currentTime
            deadline = fiveSeconds ? ProcessInfo.processInfo.systemUptime + 5 : nil
            state = .playing
            logger.log("试听开始", "asset=\(asset.id)，起点=\(settings.startOffset)s，rate=\(settings.playbackRate)，previewVolume=\(settings.volume)，5秒=\(fiveSeconds)")
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.token == currentToken else { return }
                    self.currentTime = self.player?.currentTime ?? self.currentTime
                    if let deadline = self.deadline, ProcessInfo.processInfo.systemUptime >= deadline { self.stop() }
                }
            }
        } catch {
            stop(); state = .failed; errorMessage = userFacingAudioError(error)
            logger.log("试听失败", diagnosticError(error))
        }
    }
    func stop() {
        token = UUID(); timer?.invalidate(); timer = nil
        player?.delegate = nil; player?.stop(); player = nil; deadline = nil
        if ownsSession { ownsSession = false; session.deactivate(); logger.log("试听停止", "已释放试听播放器和会话。") }
        state = .idle
    }
    func reset() { stop(); currentTime = 0; errorMessage = nil }
    func handle(_ event: AudioSessionEvent) {
        guard isActive else { return }
        switch event {
        case .interruptionBegan, .mediaLost, .mediaReset, .environmentUnavailable, .routeChanged:
            stop(); errorMessage = "试听已因音频环境变化停止，请检查路由后重新试听。"
        default: break
        }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self, weak player] in
            guard let self, let player, self.player === player else { return }
            self.currentTime = player.duration; self.stop()
            if !flag { self.errorMessage = "试听没有正常完成，请查看诊断。" }
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let detail = error.map(diagnosticError) ?? "解码失败"
        Task { @MainActor [weak self, weak player] in
            guard let self, let player, self.player === player else { return }
            self.stop(); self.state = .failed; self.errorMessage = "试听解码失败"
            self.logger.log("试听解码失败", detail)
        }
    }
}
