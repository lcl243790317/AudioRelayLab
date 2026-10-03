import AVFAudio
import Combine

@MainActor final class VoiceProcessingEngine: ObservableObject {
    enum State: String { case idle, preparing, running, failed }
    enum Mode { case monitor, voiceRecording, mixedMonitor, mixedRecording }
    @Published private(set) var state: State = .idle
    @Published var preset = VoicePreset.all[0]
    @Published var strength: Float = 1
    @Published var voiceVolume: Float = 1
    @Published var musicVolume: Float = 0.04
    @Published var masterVolume: Float = 0.9
    @Published var allowSpeakerMonitoring = false
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var outputLevel: Float = 0
    @Published private(set) var status = "未启动麦克风"
    @Published private(set) var errorMessage: String?
    @Published private(set) var recordings: [VoiceLabRecord] = []
    private let session: AudioSessionManager
    private let logger: DiagnosticsLogger
    private var engine: AVAudioEngine?
    private var voiceMixer: AVAudioMixerNode?
    private var musicNode: AVAudioPlayerNode?
    private var musicPitch: AVAudioUnitTimePitch?
    private var musicFile: AVAudioFile?
    @Published private(set) var musicPosition: TimeInterval = 0
    private var monitorMixer: AVAudioMixerNode?
    private var context: VoiceDSPContext?
    private var writer: VoiceRecordingWriter?
    private var recordingTapNode: AVAudioNode?
    private var inputTapInstalled = false
    private var observer: NSObjectProtocol?
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var token = UUID()
    private var ownsSession = false
    private var mode: Mode = .monitor
    private var fixedMusicSettings: AudioPlaybackSettings?
    private var recordPreset: VoicePreset?
    private var startedAt: Date?
    private var recordURL: URL?
    private var parameterEvents: [VoiceParameterEvent] = []
    @Published private(set) var modeLabel = "未启动"
    var isMixed: Bool { mode == .mixedMonitor || mode == .mixedRecording }
    var beforeStart: (() -> Void)?
    var onSaved: ((AudioAsset) -> Void)?
    var isActive: Bool { state == .preparing || state == .running }
    var isRecording: Bool { writer != nil }

    init(session: AudioSessionManager, logger: DiagnosticsLogger) {
        self.session = session; self.logger = logger
        do {
            let url = try Self.recordsURL()
            if FileManager.default.fileExists(atPath: url.path) {
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                // Isolate a damaged record rather than discarding the full Voice Lab library.
                let objects = (try JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [Any] ?? []
                recordings = objects.compactMap { item in
                    guard let data = try? JSONSerialization.data(withJSONObject: item),
                        let record = try? decoder.decode(VoiceLabRecord.self, from: data) else { return nil }
                    return record
                }
            }
        } catch { logger.log("Voice Lab 历史读取失败", diagnosticError(error)) }
    }
    deinit { task?.cancel(); timer?.invalidate(); if let observer { NotificationCenter.default.removeObserver(observer) } }
    private static func recordsURL() throws -> URL { try AudioFileManager.audioDirectory().appendingPathComponent("voice-lab-records.json") }
    func start(_ mode: Mode, music: AudioAsset? = nil, settings: AudioPlaybackSettings? = nil) {
        guard !isActive else { return }
        beforeStart?()
        errorMessage = nil; self.mode = mode; state = .preparing
        modeLabel = String(describing: mode)
        let generation = UUID(); token = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.token == generation { self.task = nil } }
            do {
                try Task.checkCancellation()
                guard self.token == generation else { return }
                try self.session.beginManualAttempt()
                let granted = await withCheckedContinuation { continuation in
                    AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
                }
                try Task.checkCancellation()
                guard self.token == generation, self.state == .preparing else { return }
                guard granted else { throw LabError.message("Voice Lab 需要麦克风权限，请在系统设置允许") }
                try self.preset.validate()
                try self.session.configure(profile: .mixingSpeaker, speakerOverride: self.allowSpeakerMonitoring)
                self.ownsSession = true
                guard self.token == generation, self.state == .preparing else { self.cleanup(stopHardware: true); return }
                try self.build(mode: mode, music: music, settings: settings, generation: generation)
                self.state = .running
                self.logger.log("Voice Lab 开始", "mode=\(mode)，preset=\(self.preset.id)，strength=\(self.strength)，voice=\(self.voiceVolume)，music=\(self.musicVolume)，master=\(self.masterVolume)")
                self.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.token == generation else { return }
                        self.updateMeters()
                    }
                }
            } catch {
                guard self.token == generation else { return }
                self.abort(error)
            }
        }
    }
    private func build(mode: Mode, music: AudioAsset?, settings: AudioPlaybackSettings?, generation: UUID) throws {
        try session.validateForPlayback()
        let recording = mode == .voiceRecording || mode == .mixedRecording
        let mixed = mode == .mixedMonitor || mode == .mixedRecording
        let snapshot = session.capture("Voice Lab graph 前")
        let headphones = snapshot.currentRoute.outputs.contains {
            ![AVAudioSession.Port.builtInSpeaker.rawValue, AVAudioSession.Port.builtInReceiver.rawValue].contains($0.portType)
        }
        if !recording, !headphones, !allowSpeakerMonitoring {
            throw LabError.message("实时监听建议使用耳机。要用扬声器，请打开“允许扬声器监听”并降低音量。")
        }
        let next = AVAudioEngine()
        // Session route/input checks have completed before accessing inputNode.
        let input = next.inputNode
        let hardware = input.outputFormat(forBus: 0)
        try AudioRuntimeValidation.validate(hardware)
        guard hardware.commonFormat == .pcmFormatFloat32, !hardware.isInterleaved,
            let mono = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channels: 1) else { throw LabError.invalidFormat }
        try AudioRuntimeValidation.validate(next.outputNode.inputFormat(forBus: 0))
        let dsp = try VoiceDSPContext(sampleRate: hardware.sampleRate)
        try dsp.apply(preset, strength: strength)
        let source = AVAudioSourceNode(format: mono) { _, _, count, list -> OSStatus in
            VLRender(dsp.pointer, list, count); return noErr
        }
        let voice = AVAudioMixerNode(), monitor = AVAudioMixerNode()
        let limiter = try VoiceOutputLimiter.make()
        next.attach(source); next.attach(voice); next.attach(monitor); next.attach(limiter)
        next.connect(source, to: voice, format: mono)
        next.connect(voice, to: next.mainMixerNode, format: mono)
        next.connect(next.mainMixerNode, to: limiter, format: nil)
        next.connect(limiter, to: monitor, format: nil)
        next.connect(monitor, to: next.outputNode, format: nil)
        engine = next; context = dsp; voiceMixer = voice; monitorMixer = monitor
        voice.outputVolume = try validVolume(voiceVolume)
        next.mainMixerNode.outputVolume = try validVolume(masterVolume)
        monitor.outputVolume = recording ? 0 : 1
        if mixed {
            guard let music, let settings else { throw LabError.message("请先在主音频页选择并应用音乐播放设置") }
            _ = try settings.validated(duration: music.duration)
            let file = try AVAudioFile(forReading: AudioFileManager.url(for: music))
            try AudioRuntimeValidation.validate(file.processingFormat)
            let start = try AudioPlaybackSettings.frame(settings.startOffset, sampleRate: file.processingFormat.sampleRate, length: file.length)
            guard file.length - start <= Int64(UInt32.max) else { throw LabError.invalidFormat }
            let node = AVAudioPlayerNode(), timePitch = AVAudioUnitTimePitch()
            timePitch.rate = settings.playbackRate
            next.attach(node); next.attach(timePitch)
            next.connect(node, to: timePitch, format: file.processingFormat)
            next.connect(timePitch, to: next.mainMixerNode, format: file.processingFormat)
            node.volume = try validVolume(musicVolume)
            node.scheduleSegment(file, startingFrame: start, frameCount: AVAudioFrameCount(file.length-start), at: nil)
            musicNode = node; musicPitch = timePitch; musicFile = file; fixedMusicSettings = settings; musicPosition = settings.startOffset
        } else { fixedMusicSettings = nil }
        input.installTap(onBus: 0, bufferSize: 512, format: hardware) { buffer, _ in
            VLInput(dsp.pointer, buffer.audioBufferList, buffer.frameLength)
        }
        inputTapInstalled = true
        if recording {
            let tapNode: AVAudioNode = limiter
            let format = tapNode.outputFormat(forBus: 0)
            try AudioRuntimeValidation.validate(format)
            guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else { throw LabError.invalidFormat }
            writer = try VoiceRecordingWriter(context: dsp, sampleRate: format.sampleRate)
            parameterEvents = []
            recordParameters()
            recordingTapNode = tapNode; recordPreset = preset; startedAt = Date(); recordURL = writer?.url
            tapNode.installTap(onBus: 0, bufferSize: 512, format: format) { buffer, _ in
                VLRecordPush(dsp.pointer, buffer.audioBufferList, buffer.frameLength)
            }
        }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: next, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.token == generation, self.isActive else { return }
                self.abort(LabError.message("Voice Lab 硬件配置已改变，请重新开始以建立新图"))
            }
        }
        try session.validateForPlayback()
        next.prepare(); try next.start()
        guard next.isRunning else { throw LabError.audioUnavailable }
        musicNode?.play()
        status = "\(Int(hardware.sampleRate)) Hz / \(hardware.channelCount)ch 输入 · DSP \(String(format: "%.1f", Double(VLLatency(dsp.pointer)) / hardware.sampleRate * 1000)) ms · 输入 \(String(format: "%.1f", snapshot.inputLatency*1000)) ms · 输出 \(String(format: "%.1f", snapshot.outputLatency*1000)) ms"
        logger.log("Voice DSP", "pitch=\(preset.pitch)，formant=\(preset.formant)，highpass=\(preset.highpass)，lowmid=\(preset.lowmid)，presence=\(preset.presence)，air=\(preset.air)，compression=\(preset.compression)，deesser=\(preset.deesser)，wet=\(preset.wet * strength)，gain=\(preset.outputGain)，\(status)")
    }
    private func validVolume(_ volume: Float) throws -> Float {
        guard volume.isFinite, (0...1).contains(volume) else { throw LabError.invalidFormat }; return volume
    }
    func updateParameters() {
        do {
            try context?.apply(preset, strength: strength)
            voiceMixer?.outputVolume = try validVolume(voiceVolume)
            musicNode?.volume = try validVolume(musicVolume)
            engine?.mainMixerNode.outputVolume = try validVolume(masterVolume)
            if isRecording { recordParameters() }
            logger.log("Voice 参数", "preset=\(preset.id)，strength=\(strength)，voice=\(voiceVolume)，music=\(musicVolume)，master=\(masterVolume)")
        } catch { abort(error) }
    }
    private func recordParameters() {
        parameterEvents.append(.init(date:Date(),preset:preset,strength:strength,
            volumes:.init(voice:voiceVolume,music:musicVolume,master:masterVolume),musicSettings:fixedMusicSettings))
    }
    private func updateMeters() {
        guard let context else { return }
        inputLevel = VLInputLevel(context.pointer); outputLevel = VLOutputLevel(context.pointer)
        if let node = musicNode, let render = node.lastRenderTime, let time = node.playerTime(forNodeTime: render),
            time.isSampleTimeValid, time.sampleRate.isFinite, time.sampleRate > 0, let file = musicFile {
            musicPosition = min(Double(file.length)/file.processingFormat.sampleRate,
                (fixedMusicSettings?.startOffset ?? 0) + Double(max(0,time.sampleTime))/time.sampleRate)
        }
        if let error = writer?.currentFailure() { abort(error) }
        else if VLDropped(context.pointer)>0 { abort(LabError.message("实时音频缓冲已溢出，请降低负载后重试")) }
    }
    func seekMusic(_ settings: AudioPlaybackSettings) {
        guard state == .running, let node = musicNode, let file = musicFile else { return }
        do {
            try session.validateForPlayback()
            _ = try settings.validated(duration: Double(file.length)/file.processingFormat.sampleRate)
            let frame = try AudioPlaybackSettings.frame(settings.startOffset, sampleRate:file.processingFormat.sampleRate,length:file.length)
            node.stop(); musicPitch?.rate = settings.playbackRate
            node.scheduleSegment(file,startingFrame:frame,frameCount:AVAudioFrameCount(file.length-frame),at:nil)
            node.volume = try validVolume(musicVolume); node.play()
            fixedMusicSettings = settings; musicPosition = settings.startOffset
            if isRecording { recordParameters() }
            logger.log("Mixer 音乐 seek", "起点=\(settings.startOffset)，rate=\(settings.playbackRate)，musicVolume=\(musicVolume)")
        } catch { abort(error) }
    }
    func stop(saveRecording: Bool = true) {
        guard isActive || writer != nil else { return }
        token = UUID(); task?.cancel(); task = nil; timer?.invalidate(); timer = nil
        stopGraph(stopHardware: true)
        let recordingWriter = writer; writer = nil
        var savedAsset: AudioAsset?
        do {
            if let recordingWriter, saveRecording {
                let url = try recordingWriter.finish()
                let mixed = mode == .mixedRecording
                let presetLabel = Set(parameterEvents.map { $0.preset.name }).count > 1 ? "多预设" : preset.name
                let asset = try AudioFileManager.inspect(url: url, displayName: "\(mixed ? "混合录音" : "处理后人声") \(presetLabel).caf",
                    source: mixed ? .mixedRecording : .voiceLabRecording, presetName: presetLabel)
                try AudioFileManager.register(asset)
                savedAsset = asset
                let record = VoiceLabRecord(id: UUID(), date: startedAt ?? Date(), asset: asset, preset: recordPreset ?? preset,
                    strength: strength, mixed: mixed, voiceVolume: voiceVolume, musicVolume: musicVolume,
                    masterVolume: masterVolume, musicSettings: fixedMusicSettings, parameterEvents: parameterEvents)
                let updated = [record] + recordings
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(updated).write(to: Self.recordsURL(), options: .atomic)
                recordings = updated
                logger.log("录音保存", "asset=\(asset.id)，来源=\(asset.source)，时长=\(asset.duration)，格式=\(asset.formatDescription)，字节=\(asset.byteCount)")
                onSaved?(asset)
            } else { recordingWriter?.discard() }
            state = .idle; status = "已停止，音频资源已释放"
        } catch {
            if let savedAsset { try? AudioFileManager.removeAudio(savedAsset) }
            else { recordingWriter?.discard() }
            state = .failed; errorMessage = userFacingAudioError(error); logger.log("录音保存失败", diagnosticError(error))
        }
        recordURL = nil; startedAt = nil; recordPreset = nil; parameterEvents = []
        releaseSession()
    }
    private func stopGraph(stopHardware: Bool) {
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        if stopHardware {
            if inputTapInstalled { engine?.inputNode.removeTap(onBus: 0) }
            recordingTapNode?.removeTap(onBus: 0)
            musicNode?.stop(); engine?.stop()
        }
        inputTapInstalled = false; recordingTapNode = nil
        engine = nil; voiceMixer = nil; musicNode = nil; musicPitch = nil; musicFile = nil; monitorMixer = nil
        // writer retains its context until the remaining ring has been drained.
        context = nil; inputLevel = 0; outputLevel = 0
    }
    private func releaseSession() { if ownsSession { ownsSession = false; session.deactivate() } }
    private func cleanup(stopHardware: Bool) { stopGraph(stopHardware: stopHardware); writer?.discard(); writer = nil; releaseSession() }
    private func abort(_ error: Error, stopHardware: Bool = true) {
        token = UUID(); task?.cancel(); task = nil; timer?.invalidate(); timer = nil
        cleanup(stopHardware: stopHardware); state = .failed; errorMessage = userFacingAudioError(error)
        status = "已安全停止，请检查诊断后重试"; logger.log("Voice Lab 失败", diagnosticError(error))
    }
    func handle(_ event: AudioSessionEvent) {
        guard isActive else { return }
        switch event {
        case .mediaLost, .mediaReset: abort(LabError.audioUnavailable, stopHardware: false)
        case .interruptionBegan, .environmentUnavailable: abort(LabError.audioUnavailable)
        case .routeChanged: if state == .running { abort(LabError.message("音频路由已改变，请重新开始 Voice Lab")) }
        default: break
        }
    }
    func delete(_ record: VoiceLabRecord) {
        guard !isActive else { return }
        do {
            try AudioFileManager.removeAudio(record.asset)
            recordings.removeAll { $0.id == record.id }
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(recordings).write(to: Self.recordsURL(), options: .atomic)
        } catch { errorMessage = "录音删除失败"; logger.log("录音删除失败", diagnosticError(error)) }
    }
}
