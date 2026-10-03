import AVFAudio
import Combine

enum AudioSessionEvent {
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case routeChanged
    case mediaLost
    case mediaReset
    case silenceHint
    case environmentUnavailable
}

@MainActor final class AudioSessionManager: ObservableObject {
    @Published private(set) var snapshot = AudioSessionSnapshot()
    @Published private(set) var interruptionMessage: String?
    @Published private(set) var availabilityMessage = "未激活音频会话"
    var onEvent: ((AudioSessionEvent) -> Void)?
    private(set) var lastRouteChangeReason: UInt = 0
    private let session = AVAudioSession.sharedInstance()
    private let logger: DiagnosticsLogger
    private var observers: [NSObjectProtocol] = []
    private let environment = AudioEnvironmentGuard()
    private var ownsActivation = false
    private var interrupted = false
    private var mediaAvailable = true
    private var configuredProfile: AudioSessionProfile?
    private var operationGeneration = UUID()

    init(logger: DiagnosticsLogger) {
        self.logger = logger
        environment.onChange = { [weak self] in
            guard let self else { return }
            if self.environment.hasActiveCall {
                self.availabilityMessage = "系统可见的通话正在进行，暂时无法开始实验"
                self.logger.log("音频环境", "公开通话状态显示存在未结束通话；不记录号码、通话标识或具体 App。")
                self.onEvent?(.environmentUnavailable)
            } else {
                self.availabilityMessage = self.ownsActivation ? "音频会话已激活" : "可稍后重新准备实验"
                self.logger.log("音频环境", "系统可见的通话已结束；需用户重新准备，不自动启动。")
            }
        }
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
            AVAudioSession.mediaServicesWereLostNotification, AVAudioSession.mediaServicesWereResetNotification,
            AVAudioSession.silenceSecondaryAudioHintNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: .main) { [weak self] note in
                // .main 保证通知在主队列；同步处理避免旧通知排队到下一次实验。
                MainActor.assumeIsolated { self?.receive(note) }
            })
        }
        capture("App 启动")
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func configure(profile: AudioSessionProfile, speakerOverride: Bool) throws {
        interruptionMessage = nil
        guard profile.isSelectable else { throw LabError.message("此配置仅用于旧历史，不能开始新实验") }
        do { try ensureCanActivate() }
        catch { availabilityMessage = userFacingAudioError(error); logger.log("激活前置拒绝", diagnosticError(error)); throw error }
        let operation = UUID()
        operationGeneration = operation
        capture("setCategory 前")
        do {
            try session.setCategory(profile.category, mode: .default, options: profile.options)
            try validateOperation(operation)
            logger.log("音频会话", "setCategory 成功；配置=\(profile.rawValue) \(profile.title)")
            capture("setCategory 后")
            capture("setActive 前")
            availabilityMessage = "正在请求音频会话"
            logger.log("音频会话", "请求 setActive(true)")
            try session.setActive(true)
            ownsActivation = true
            configuredProfile = profile
            try validateOperation(operation)
            logger.log("音频会话", "setActive(true) 成功")
            capture("setActive 后")
            if profile.usesInput {
                do {
                    try session.overrideOutputAudioPort(speakerOverride ? .speaker : .none)
                    try validateOperation(operation)
                    logger.log("扬声器覆盖", "overrideOutputAudioPort(\(speakerOverride ? "speaker" : "none")) 成功")
                } catch {
                    logger.log("扬声器覆盖失败", diagnosticError(error))
                    throw error
                }
                capture("扬声器覆盖后")
            }
            try validateForPlayback()
            availabilityMessage = "音频会话已激活；是否发声仍需实际观察"
        } catch {
            availabilityMessage = userFacingAudioError(error)
            logger.log("会话配置失败", diagnosticError(error))
            capture("配置失败后")
            deactivate()
            throw error
        }
    }
    func reactivate() throws {
        try ensureCanActivate()
        let operation = UUID()
        operationGeneration = operation
        capture("恢复 setActive 前")
        do {
            logger.log("音频会话", "恢复请求 setActive(true)")
            try session.setActive(true)
            ownsActivation = true
            try validateOperation(operation)
            try validateForPlayback()
            availabilityMessage = "音频会话恢复激活成功"
            capture("恢复 setActive 后")
        }
        catch {
            logger.log("会话恢复失败", diagnosticError(error))
            deactivate()
            availabilityMessage = userFacingAudioError(error)
            throw error
        }
    }
    func deactivate() {
        operationGeneration = UUID()
        guard ownsActivation else { return }
        // 先释放本地所有权，防止 setActive(false) 同步通知再次进入清理。
        ownsActivation = false
        configuredProfile = nil
        capture("停用 setActive 前")
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            logger.log("音频会话", "setActive(false, notifyOthersOnDeactivation) 成功")
        } catch { logger.log("停用会话失败", diagnosticError(error)) }
        if !environment.hasActiveCall { availabilityMessage = "未激活；可重新准备实验" }
        capture("停用 setActive 后")
    }
    func ensureCanActivate() throws {
        guard mediaAvailable, !interrupted else { throw LabError.audioUnavailable }
        try environment.ensureNoKnownCall()
    }
    func beginManualAttempt() throws {
        guard mediaAvailable else { throw LabError.audioUnavailable }
        try environment.ensureNoKnownCall()
        // 系统不保证每个 began 都有 ended。用户明确重试时由 setActive 重新裁决。
        if interrupted {
            operationGeneration = UUID()
            interrupted = false
            interruptionMessage = nil
            logger.log("手动重试", "用户重新准备，清除旧中断缓存；仍需系统批准激活，不自动恢复。")
        }
    }
    private func validateOperation(_ operation: UUID) throws {
        guard operationGeneration == operation else { throw LabError.audioUnavailable }
        try ensureCanActivate()
    }
    func validateForPlayback() throws {
        try ensureCanActivate()
        guard ownsActivation, !interrupted, session.sampleRate.isFinite,
            (8_000...384_000).contains(session.sampleRate), session.outputNumberOfChannels > 0,
            !session.currentRoute.outputs.isEmpty, session.ioBufferDuration.isFinite,
            session.ioBufferDuration > 0 else { throw LabError.invalidFormat }
        if configuredProfile?.usesInput == true {
            guard session.isInputAvailable, session.inputNumberOfChannels > 0,
                !session.currentRoute.inputs.isEmpty else { throw LabError.invalidFormat }
        }
    }
    @discardableResult func capture(_ reason: String) -> AudioSessionSnapshot {
        snapshot = AudioSessionSnapshot(session: session)
        logger.log("音频会话快照", "节点=\(reason)\n\(snapshot.summary)")
        return snapshot
    }
    var microphoneInjectionDiagnostic: String {
        "本轮正式功能以 iOS 18.1.1 能力为界；不查询或启用麦克风注入。Voice Lab 只使用本 App 麦克风输入。"
    }
    private func receive(_ notification: Notification) {
        switch notification.name {
        case AVAudioSession.interruptionNotification:
            let typeValue = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue ?? UInt.max
            let optionsValue = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
            logger.log("音频中断", "type=\(typeValue)，options=\(optionsValue)，shouldResume=\(shouldResume)；通知前缓存路由：\(snapshot.currentRoute.summary)")
            capture("interruption")
            if typeValue == AVAudioSession.InterruptionType.began.rawValue {
                operationGeneration = UUID()
                interrupted = true
                interruptionMessage = "音频会话被系统或其他高优先级音频中断"
                availabilityMessage = "音频会话已被中断"
                onEvent?(.interruptionBegan)
            } else if typeValue == AVAudioSession.InterruptionType.ended.rawValue {
                interrupted = false
                interruptionMessage = shouldResume ? "中断已结束，系统允许尝试恢复" : "中断已结束，系统未建议恢复"
                onEvent?(.interruptionEnded(shouldResume: shouldResume))
            } else { logger.log("音频中断", "收到未知中断类型，不执行自动恢复。") }
        case AVAudioSession.routeChangeNotification:
            let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue ?? 0
            lastRouteChangeReason = reason
            let previous = notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
            logger.log("路由变化", "原因=\(reason)（\(routeReason(reason))）\n先前路由：\(previous.map { AudioRouteSnapshot($0).summary } ?? "系统未提供")\n当前路由：\(AudioRouteSnapshot(session.currentRoute).summary)")
            capture("route change")
            onEvent?(.routeChanged)
        case AVAudioSession.mediaServicesWereLostNotification:
            operationGeneration = UUID()
            mediaAvailable = false
            ownsActivation = false
            availabilityMessage = "系统音频服务暂时不可用"
            logger.log("媒体服务", "媒体服务已丢失；本次播放对象不可继续使用。")
            capture("media services lost")
            onEvent?(.mediaLost)
        case AVAudioSession.mediaServicesWereResetNotification:
            operationGeneration = UUID()
            mediaAvailable = true
            ownsActivation = false
            interrupted = false
            configuredProfile = nil
            availabilityMessage = "系统音频服务已重置，请重新准备"
            logger.log("媒体服务", "媒体服务已重置；下一次准备将重建音频对象，本次实验不会自动重新开始。")
            capture("media services reset")
            onEvent?(.mediaReset)
        case AVAudioSession.silenceSecondaryAudioHintNotification:
            let type = (notification.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? NSNumber)?.uintValue
            logger.log("次级音频提示", "类型=\(type.map(String.init) ?? "未知")")
            capture("silence hint")
            onEvent?(.silenceHint)
        default: break
        }
    }
    private func routeReason(_ value: UInt) -> String {
        switch AVAudioSession.RouteChangeReason(rawValue: value) {
        case .newDeviceAvailable: return "新设备接入"
        case .oldDeviceUnavailable: return "旧设备离开"
        case .categoryChange: return "类别改变"
        case .override: return "输出覆盖"
        case .wakeFromSleep: return "从休眠唤醒"
        case .noSuitableRouteForCategory: return "无适合此类别的路由"
        case .routeConfigurationChange: return "路由配置改变"
        default: return "未知"
        }
    }
}
