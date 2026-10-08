import AVFAudio
import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor final class ExperimentCoordinator: ObservableObject {
    let logger: DiagnosticsLogger
    let session: AudioSessionManager
    let store: ExperimentStore
    let preview: PreviewPlaybackController
    let rawRecorder: RawVoiceRecorder
    let mixVolumes = MixVolumeSettings()
    let voiceMix = VoiceMixController()
    let aiVoice: AIConversionController
    let revoice: RevoiceController
    let navigation = AppNavigation()
    private var aiObserver: AnyCancellable?
    private var revoiceObserver: AnyCancellable?
    @Published private(set) var audio: AudioFileMetadata?
    @Published var engineKind: PlaybackEngineKind = .audioPlayer
    @Published var profile: AudioSessionProfile = .mixingPlayback
    @Published var delay: Double = 5
    @Published var volume: Double = 0.5
    @Published var requestedDuration: Double?
    @Published var editing = AudioPlaybackSettings()
    @Published private(set) var applied = AudioPlaybackSettings()
    @Published private(set) var library: [AudioAsset] = []
    private var importGeneration = UUID()
    @Published var speakerOverride = false
    @Published var voiceOptimized = false
    @Published private(set) var state: PlaybackState = .idle
    @Published private(set) var currentExperiment: Experiment?
    @Published private(set) var remaining: Double = 0
    @Published private(set) var diagnosticState = "尚未创建播放器"
    @Published private(set) var isImporting = false
    @Published private(set) var isMixing = false
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

    init(historyDirectoryURL:URL? = nil,draftStore:RevoiceDraftStore? = .init()) {
        let logger = DiagnosticsLogger()
        self.logger = logger
        aiVoice = AIConversionController(logger: logger)
        let previewing = ProcessInfo.processInfo.arguments.contains { $0.hasSuffix("snapshot") }
        revoice = RevoiceController(logger:logger,backgroundTransfers:.shared,draftStore:previewing ? nil : draftStore)
        if ProcessInfo.processInfo.arguments.contains("voice-snapshot") || ProcessInfo.processInfo.arguments.contains("voice-custom-snapshot") {
            revoice.preparePreview(custom:ProcessInfo.processInfo.arguments.contains("voice-custom-snapshot"))
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("voice-recovery-snapshot") { revoice.preparePreviewRecovery() }
        #endif
        session = AudioSessionManager(logger: logger)
        preview = PreviewPlaybackController(session: session, logger: logger)
        rawRecorder = RawVoiceRecorder(session: session, logger: logger)
        store = ExperimentStore(logger: logger, directoryURL:historyDirectoryURL)
        logger.log("生命周期", "App 启动；设备=\(DeviceInfo.current().modelIdentifier)；iOS=\(DeviceInfo.current().systemVersion)")
        session.onEvent = { [weak self] event in self?.handle(event) }
        rawRecorder.beforeStart = { [weak self] in self?.stop(); self?.preview.stop() }
        rawRecorder.onSaved = { [weak self] asset, purpose in
            self?.refreshLibrary()
            if purpose == .computerConversion { self?.aiVoice.selectInput(asset) }
            if purpose == .revoice { self?.revoice.recorded(asset) }
        }
        aiVoice.beforeConvert = { [weak self] in self?.stop(); self?.preview.stop() }
        aiVoice.onResult = { [weak self] _ in self?.refreshLibrary() }
        aiObserver = aiVoice.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        revoice.beforeGenerate = { [weak self] in self?.stop(); self?.preview.stop() }
        revoice.onResult = { [weak self] _ in self?.refreshLibrary() }
        revoiceObserver = revoice.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
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
                if saved.source == .bundled {
                    let bundled = try AudioFileManager.loadBundledAudio()
                    audio = bundled
                    try rememberAudio(bundled)
                } else {
                let url = try AudioFileManager.url(for: saved)
                if FileManager.default.fileExists(atPath: url.path) {
                    var restored = try AudioFileManager.inspect(url: url, displayName: saved.fileName, id: saved.id, source: saved.source, presetName: saved.presetName)
                    restored.aiConversion = saved.aiConversion
                    restored.revoice = saved.revoice
                    restored.mixSource = saved.mixSource
                    restored.addedAt = saved.addedAt ?? restored.addedAt
                    audio = restored
                }
                }
            } catch { logger.log("音频恢复失败", diagnosticError(error)) }
        }
        if audio == nil { useTestAudio() }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("preview-lifecycle-test"),let fixture = try? PreviewInteractionFixture.make() {
            _ = selectLocal(fixture)
        }
        if ProcessInfo.processInfo.arguments.contains("mix-interaction-test") || ProcessInfo.processInfo.arguments.contains("mix-timing-snapshot") || ProcessInfo.processInfo.arguments.contains("library-interaction-test"),let source = try? AudioFileManager.loadBundledAudio(),
           let sourceURL = try? AudioFileManager.url(for:source),let folder = try? AudioFileManager.audioDirectory() {
            let id = UUID(uuidString:"16300000-0000-4000-8000-000000000013") ?? UUID()
            let target = folder.appendingPathComponent("混音测试原声.wav")
            if !FileManager.default.fileExists(atPath:target.path) { try? FileManager.default.copyItem(at:sourceURL,to:target) }
            if let fixture = try? AudioFileManager.inspect(url:target,displayName:"混音测试原声",id:id,source:.voiceLabRecording) {
                try? AudioFileManager.register(fixture)
            }
        }
        if ProcessInfo.processInfo.arguments.contains("library-interaction-test"),
           let source = try? AudioFileManager.loadBundledAudio(),let sourceURL = try? AudioFileManager.url(for:source),
           let folder = try? AudioFileManager.audioDirectory() {
            for (suffix,name,kind) in [(14,"批删测试原声",AudioSource.voiceLabRecording),(15,"批删测试音乐一",.imported),(16,"批删测试音乐二",.imported),
                                       (17,"批删测试配音一",.aiConverted),(18,"批删测试配音二",.aiConverted),(19,"批删测试混音",.mixedRecording)] {
                let id = UUID(uuidString:String(format:"16300000-0000-4000-8000-%012d",suffix)) ?? UUID()
                let target = folder.appendingPathComponent(name+".wav")
                if !FileManager.default.fileExists(atPath:target.path) { try? FileManager.default.copyItem(at:sourceURL,to:target) }
                if var fixture = try? AudioFileManager.inspect(url:target,displayName:name,id:id,source:kind) {
                    if kind == .aiConverted {
                        fixture.revoice = RevoiceMetadata(provider:"ui-fixture",generationMode:"custom",voiceID:"custom",speakerID:"Serena",
                            instruction:"自然表达",recognizedText:nil,synthesisText:"批删测试配音正文 \(suffix)",sourceAudioID:nil,
                            modelVariant:"custom",modelRevision:"ui-fixture",sha256:String(repeating:"0",count:64),generationSeconds:1,totalSeconds:1)
                    }
                    if kind == .mixedRecording {
                        fixture.mixSource = MixSourceMetadata(voiceAssetID:UUID(uuidString:"16300000-0000-4000-8000-000000000014") ?? UUID(),
                            musicAssetID:source.id,revoice:nil,settings:.init(),volumes:.init(),timing:.init(voiceStartDelay:2,musicTailDuration:3))
                    }
                    try? AudioFileManager.register(fixture)
                }
            }
        }
        #endif
        refreshLibrary()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("voice-recovery-empty-input-test"),
           let input = library.first(where:{$0.id == UUID(uuidString:"16300000-0000-4000-8000-000000000013")}) {
            revoice.selectInput(input); revoice.text = ""
        }
        if ProcessInfo.processInfo.arguments.contains("workshop-result-test") {
            revoice.preparePreview(custom:true)
            if let result = library.first(where:{$0.id == UUID(uuidString:"16300000-0000-4000-8000-000000000017")}) { revoice.preparePreviewResult(result) }
            if let result = library.first(where:{$0.id == UUID(uuidString:"16300000-0000-4000-8000-000000000019")}) { voiceMix.preparePreviewResult(result) }
            if ProcessInfo.processInfo.arguments.contains("workshop-missing-result-test"),let result = revoice.result,
               let url = try? AudioFileManager.url(for:result) { try? FileManager.default.removeItem(at:url) }
        }
        if ProcessInfo.processInfo.arguments.contains("mix-timing-snapshot") {
            voiceMix.voiceID = UUID(uuidString:"16300000-0000-4000-8000-000000000013")
            voiceMix.musicID = UUID(uuidString:"00000000-0000-4000-8000-000000000001")
            voiceMix.timing = .init(voiceStartDelay:2,musicTailDuration:3)
        }
        #endif
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
    var controlsLocked: Bool { isImporting || isMixing || machine.isActive || rawRecorder.isActive || aiVoice.busy || revoice.usesAudioResources }
    func beginMixing() throws {
        guard !controlsLocked else { throw LabError.audioUnavailable }
        isMixing = true
    }
    func endMixing() { isMixing = false }

    func importAudio(_ url: URL) {
        guard !machine.isActive, !rawRecorder.isActive, !aiVoice.busy, !revoice.usesAudioResources, !isMixing else { report(LabError.audioUnavailable, message: "请先结束当前实验、录音、识别或混音再选择音频。"); return }
        cancelImport()
        preview.reset()
        let lease = AudioAccessLease(url)
        let type = UTType(filenameExtension: url.pathExtension)?.identifier ?? "未知（由解码器裁决）"
        logger.log("音频导入请求", "原 URL=\(url.absoluteString)，文件=\(url.lastPathComponent)，UTType=\(type)，来源=imported")
        let token = UUID(); importGeneration = token
        isImporting = true
        importTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.importGeneration == token { self.isImporting = false; self.importTask = nil } }
            do {
                let work = Task.detached(priority: .userInitiated) { try AudioFileManager.importFile(lease: lease) }
                let metadata = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
                guard !Task.isCancelled, self.importGeneration == token else { try? AudioFileManager.removeAudio(metadata); return }
                try self.selectAudio(metadata)
                self.logger.log("音频导入", "validation=通过实际 PCM 解码，asset=\(metadata.id)，format=\(metadata.formatDescription)，destination=\(try AudioFileManager.url(for: metadata).absoluteString)，时长=\(metadata.duration)s，采样率=\(metadata.sampleRate)，声道=\(metadata.channelCount)，字节数=\(metadata.byteCount)；后续只使用本地副本。")
            } catch {
                guard self.importGeneration == token, !Task.isCancelled else { return }
                self.report(error, message: "无法读取这个音频文件：\(url.lastPathComponent)（\(url.pathExtension.uppercased())）。请先下载到本机或选择其他格式。")
            }
        }
    }
    func useTestAudio() {
        guard !machine.isActive, !rawRecorder.isActive, !aiVoice.busy, !revoice.usesAudioResources, !isMixing else { errorMessage = "请先结束当前实验、录音、识别或混音再选择测试音频"; return }
        cancelImport()
        do {
            let metadata = try AudioFileManager.loadBundledAudio()
            try selectAudio(metadata)
            logger.log("测试音频", "已选择 Bundle 测试音（资源缺失时本地生成）；11.7s、44100Hz、单声道 WAV，10ms 淡入淡出，0.28 峰值。")
        } catch { report(error, message: "测试音频生成失败，请检查存储空间。") }
    }
    func cancelImport() {
        importGeneration = UUID(); importTask?.cancel(); importTask = nil; isImporting = false
    }
    func refreshLibrary() {
        do { library = try AudioFileManager.listLocalAudio() }
        catch { logger.log("音频库读取失败", diagnosticError(error)) }
    }
    @discardableResult func deleteAudio(_ asset: AudioAsset) -> BatchAudioDeleteResult {
        deleteAudio(ids:[asset.id])
    }
    @discardableResult func deleteAudio(ids:Set<UUID>,remove:(AudioAsset)throws->Void = AudioFileManager.removeAudio) -> BatchAudioDeleteResult {
        var result = BatchAudioDeleteResult()
        guard !controlsLocked,!aiVoice.connecting else {
            result.failures = Dictionary(uniqueKeysWithValues:ids.map { ($0,"请先结束当前操作") }); return result
        }
        let current = Dictionary(uniqueKeysWithValues:library.map { ($0.id,$0) })
        preview.reset()
        for id in ids {
            guard let asset = current[id],asset.source != .bundled else {
                result.failures[id] = "音频已不存在或是受保护的内置音频"; continue
            }
            do { try remove(asset) }
            catch {
                // A sidecar failure after the audio was removed must still clear
                // references to that audio; successful deletions are never rolled back.
                guard let url = try? AudioFileManager.url(for:asset),
                      !FileManager.default.fileExists(atPath:url.path) else {
                    result.failures[id] = userFacingAudioError(error); continue
                }
                do {
                    let sidecar = url.appendingPathExtension("metadata.json")
                    if FileManager.default.fileExists(atPath:sidecar.path) { try FileManager.default.removeItem(at:sidecar) }
                } catch {
                    result.cleanupWarnings.append("\(asset.libraryName)：附属文件清理未完成")
                    logger.log("删除附属文件失败",diagnosticError(error))
                }
            }
            result.deletedIDs.insert(id)
            aiVoice.forgetAsset(asset.id)
            revoice.forgetAsset(asset.id)
            voiceMix.forgetAsset(asset.id)
            do { try rawRecorder.removeRecord(for:asset.id) }
            catch { result.cleanupWarnings.append("录音索引清理未完成"); logger.log("删除索引清理失败",diagnosticError(error)) }
            logger.log("音频删除", "asset=\(asset.id)，来源=\(asset.source.rawValue)；实验历史保留。")
        }
        if let selected = audio?.id,result.deletedIDs.contains(selected) { useTestAudio() }
        refreshLibrary()
        errorMessage = result.failures.isEmpty && result.cleanupWarnings.isEmpty ? nil : result.summary
        return result
    }
    func selectAudio(_ asset: AudioAsset) throws {
        guard !machine.isActive, !rawRecorder.isActive, !aiVoice.busy, !revoice.usesAudioResources, !isMixing else { throw LabError.message("请先结束正式播放、录音、识别或混音，再切换素材") }
        var checked = try AudioFileManager.inspect(url: AudioFileManager.url(for: asset), displayName: asset.fileName,
            id: asset.id, source: asset.source, presetName: asset.presetName)
        checked.aiConversion = asset.aiConversion
        checked.mixSource = asset.mixSource
        checked.revoice = asset.revoice
        checked.addedAt = asset.addedAt ?? checked.addedAt
        preview.reset()
        try rememberAudio(checked)
        checkpoint()
        machine = ExperimentStateMachine(); state = .idle; currentExperiment = nil; remaining = 0
        audio = checked; requestedDuration = nil; editing = AudioPlaybackSettings(); applied = editing; volume = Double(applied.volume)
        navigation.clearPlaybackNotice()
        errorMessage = nil; technicalDetails = nil
        logger.log("音频选择", "asset=\(checked.id)，文件=\(checked.fileName)，来源=\(checked.source.rawValue)，格式=\(checked.formatDescription)，时长=\(checked.duration)，采样率=\(checked.sampleRate)，声道=\(checked.channelCount)，字节=\(checked.byteCount)")
        refreshLibrary()
    }
    @discardableResult func selectLocal(_ asset: AudioAsset) -> Bool {
        guard !controlsLocked else { errorMessage = "请先结束正式播放、导入、录音、识别或混音，再切换素材"; return false }
        do { try selectAudio(asset); return true }
        catch { report(error, message: "本地音频无法读取，原选择已保留，请重新选择音频。"); return false }
    }
    func applyPlaybackSettings() {
        guard !controlsLocked, let audio else { return }
        do {
            applied = try editing.validated(duration: audio.duration)
            requestedDuration = nil
            logger.log("应用播放设置", "asset=\(audio.id)，起点=\(applied.startOffset)，终点=\(applied.endPosition(duration:audio.duration))，rate=\(applied.playbackRate)，试听音量=\(applied.volume)，App音量=\(volume)，剩余源时长=\(applied.remaining(duration: audio.duration))，预计时间=\(applied.estimatedDuration(duration: audio.duration))")
        } catch { report(error, message: userFacingAudioError(error)) }
    }
    func audition(fiveSeconds: Bool = false, owner: UUID? = nil) {
        guard !controlsLocked, let audio else { return }
        preview.play(asset: audio, settings: editing, fiveSeconds: fiveSeconds, owner:owner)
    }
    func audition(_ asset: AudioAsset, owner: UUID? = nil) {
        guard !controlsLocked, !aiVoice.connecting else { return }
        preview.play(asset: asset, settings: AudioPlaybackSettings(), fiveSeconds: false, owner: owner)
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
        preview.stop()
        currentExperiment = nil
        errorMessage = nil
        technicalDetails = nil
        do {
            guard let audio else { throw LabError.message("请先选择有效的音频文件") }
            try ExperimentParameters.validate(delay: delay, volume: volume, requestedDuration: requestedDuration, audioDuration: audio.duration,
                startOffset:applied.startOffset,playbackRate:applied.playbackRate,endOffset:applied.endOffset)
            guard profile.isSelectable, engineKind != .unknown else { throw LabError.message("旧版或未知配置不能用于新实验") }
            let token = try machine.begin()
            state = machine.state
            let settings = ExperimentSettings(engine: engineKind, profile: profile, delay: delay, volume: Float(volume),
                voiceOptimized: voiceOptimized && engineKind == .audioEngine,
                speakerOverride: speakerOverride && profile.usesInput, requestedDuration: requestedDuration, startOffset:applied.startOffset,playbackRate:applied.playbackRate,endOffset:applied.endOffset)
            let id = UUID()
            logBoundary = logger.nextSequence
            logger.setExperimentID(id)
            currentExperiment = Experiment(id: id, date: Date(), device: DeviceInfo.current(), audio: audio, settings: settings,
                schedule: nil, finalState: .preparing, result: .uncertain, resultReviewed: false, notes: "", finishedAt: nil, logs: [])
            logger.log("实验请求", "开始准备；引擎=\(settings.engine.rawValue)，配置=\(settings.profile.rawValue)，延迟=\(settings.delay)s，时长=\(settings.requestedDuration.map { String($0) } ?? "完整文件")，App音量=\(settings.volume)")
            logger.log("实验音频", "asset=\(audio.id)，来源=\(audio.source)，格式=\(audio.formatDescription)，总时长=\(audio.duration)，起点=\(settings.startOffset)，终点=\(settings.endOffset ?? audio.duration)，rate=\(settings.playbackRate)，剩余源时长=\(audio.duration-settings.startOffset)，预计播放时间=\(AudioPlaybackSettings(startOffset:settings.startOffset,playbackRate:settings.playbackRate,endOffset:settings.endOffset).estimatedDuration(duration:audio.duration,sourceLimit:settings.requestedDuration))")
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
                    try await newEngine.prepare(url: url, voiceOptimized: settings.voiceOptimized, requestedDuration: settings.requestedDuration,
                        startOffset:settings.startOffset,playbackRate:settings.playbackRate,endOffset:settings.endOffset)
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
        cancelImport()
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
    func clearHistory() throws {
        guard !machine.isActive else { throw LabError.message("请先结束当前实验再清空历史") }
        try store.clearAll()
        currentExperiment = nil
        logBoundary = logger.nextSequence
        logger.setExperimentID(nil)
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
        revoice.foregroundChanged(phase == .active)
        switch phase {
        case .active: logger.log("生命周期", "Scene active / foreground"); capture("foreground"); refresh()
        case .inactive: logger.log("生命周期", "Scene inactive")
        case .background:
            rawRecorder.stop()
            preview.stop()
            cancelImport()
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
        if let engine, diagnosticState != engine.diagnosticState { diagnosticState = engine.diagnosticState }
        let nextRemaining:Double
        if state == .waiting, let target = currentExperiment?.schedule?.targetUptime { nextRemaining = max(0, target - ProcessInfo.processInfo.systemUptime) }
        else { nextRemaining = 0 }
        if remaining != nextRemaining { remaining = nextRemaining }
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
        rawRecorder.handle(event)
        preview.handle(event)
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
