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
    private var owner: UUID?
    private var deadline: TimeInterval?
    private var ownsSession = false
    private var preparation: Task<Void, Never>?
    private var processedURL: URL?
    private var sourceTimeOffset: Double = 0
    private var startInPlayer: Double = 0
    init(session: AudioSessionManager, logger: DiagnosticsLogger) { self.session = session; self.logger = logger }
    deinit { timer?.invalidate(); preparation?.cancel(); if let processedURL { try? FileManager.default.removeItem(at:processedURL) } }
    var isActive: Bool { state == .preparing || state == .playing }
    func isOwned(by owner: UUID) -> Bool { self.owner == owner && isActive }
    func hasContext(owner:UUID) -> Bool { self.owner == owner }
    var preparedDuration: Double? { player.map { $0.duration-startInPlayer } }
    func play(asset: AudioAsset, settings: AudioPlaybackSettings, fiveSeconds: Bool, owner: UUID? = nil) {
        stop()
        self.owner = owner
        errorMessage = nil
        let currentToken = UUID(); token = currentToken
        state = .preparing
        preparation = Task { [weak self] in
          guard let self else { return }
          var temporary: URL?
          do {
            _ = try settings.validated(duration: asset.duration)
            let original = try AudioFileManager.url(for:asset)
            let playbackURL: URL
            if settings.endPosition(duration:asset.duration) < asset.duration {
                let work = Task.detached(priority:.userInitiated) { try AudioProcessor.rangeCopy(of:original,settings:settings) }
                let cropped = try await withTaskCancellationHandler(operation:{ try await work.value },onCancel:{ work.cancel() })
                temporary = cropped; playbackURL = cropped
            } else { playbackURL = original }
            try Task.checkCancellation()
            guard self.token == currentToken, self.state == .preparing else { throw CancellationError() }
            try session.beginManualAttempt()
            try session.configure(profile: .mixingPlayback, speakerOverride: false)
            ownsSession = true
            guard token == currentToken, state == .preparing else { throw CancellationError() }
            let next = try AVAudioPlayer(contentsOf:playbackURL)
            next.enableRate = true; next.rate = settings.playbackRate; next.volume = settings.volume
            sourceTimeOffset = temporary == nil ? 0 : settings.startOffset
            startInPlayer = temporary == nil ? settings.startOffset : 0
            next.currentTime = startInPlayer; next.delegate = self
            player = next
            processedURL = temporary; temporary = nil
            try session.validateForPlayback()
            guard next.prepareToPlay(), next.play() else { throw LabError.audioUnavailable }
            currentTime = sourceTimeOffset+next.currentTime
            deadline = fiveSeconds ? ProcessInfo.processInfo.systemUptime + 5 : nil
            state = .playing
            logger.log("试听开始", "asset=\(asset.id)，起点=\(settings.startOffset)s，终点=\(settings.endPosition(duration:asset.duration))s，rate=\(settings.playbackRate)，previewVolume=\(settings.volume)，5秒=\(fiveSeconds)")
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.token == currentToken else { return }
                    if let player = self.player { self.currentTime = self.sourceTimeOffset+player.currentTime }
                    if let deadline = self.deadline, ProcessInfo.processInfo.systemUptime >= deadline {
                        let finished = self.currentTime
                        self.stop()
                        self.currentTime = finished
                    }
                }
            }
          } catch {
            if let temporary { try? FileManager.default.removeItem(at:temporary) }
            guard self.token == currentToken else { return }
            if error is CancellationError { self.stop(); return }
            stop(); state = .failed; errorMessage = userFacingAudioError(error)
            logger.log("试听失败", diagnosticError(error))
          }
        }
    }
    /// A screen only stops the preview it started. A late disappearance must not
    /// cancel playback that a different screen has already taken over.
    func stop(owner: UUID) {
        guard self.owner == owner else { return }
        stop()
    }
    func stop() {
        token = UUID(); timer?.invalidate(); timer = nil
        preparation?.cancel(); preparation = nil
        player?.delegate = nil; player?.stop(); player = nil; deadline = nil
        if let processedURL { try? FileManager.default.removeItem(at:processedURL) }; processedURL = nil
        if ownsSession { ownsSession = false; session.deactivate(); logger.log("试听停止", "已释放试听播放器和会话。") }
        state = .idle
        currentTime = 0; errorMessage = nil
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
            let finished = self.sourceTimeOffset+player.duration
            self.stop(); self.currentTime = finished
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
