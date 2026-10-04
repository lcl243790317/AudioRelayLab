import AVFAudio
import Combine
import UIKit

/// Original speech only. AVAudioRecorder owns microphone/file IO; no playback,
/// voice DSP, live monitor, music graph or voice-preset configuration is involved.
@MainActor final class RawVoiceRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    enum State { case idle, preparing, running, saving, failed }
    enum Purpose { case computerConversion, revoice }
    @Published private(set) var state: State = .idle
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var status = "尚未录音"
    @Published private(set) var errorMessage: String?
    @Published private(set) var recordings: [VoiceLabRecord] = []
    var isActive: Bool { [.preparing, .running, .saving].contains(state) }
    var beforeStart: (() -> Void)?
    var onSaved: ((AudioAsset, Purpose) -> Void)?
    private let session: AudioSessionManager
    private let logger: DiagnosticsLogger
    private var recorder: AVAudioRecorder?
    private var rawURL: URL?
    private var purpose: Purpose = .computerConversion
    private var startedAt = Date()
    private var token = UUID()
    private var task: Task<Void, Never>?
    private var routeTask: Task<Void, Never>?
    private var timer: Timer?
    private var ownsSession = false
    private var initialRoute: VoiceHardwareRoute?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init(session: AudioSessionManager, logger: DiagnosticsLogger) {
        self.session = session; self.logger = logger
        super.init()
        if let url = try? Self.recordsURL(), let data = try? Data(contentsOf: url),
           let objects = (try? JSONSerialization.jsonObject(with: data)) as? [Any] {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            recordings = objects.compactMap {
                guard let data = try? JSONSerialization.data(withJSONObject: $0) else { return nil }
                return try? decoder.decode(VoiceLabRecord.self, from: data)
            }
        }
    }
    deinit { task?.cancel(); routeTask?.cancel(); timer?.invalidate() }
    private static func recordsURL() throws -> URL {
        try AudioFileManager.audioDirectory().appendingPathComponent("voice-lab-records.json")
    }
    func start(_ purpose: Purpose) {
        guard !isActive else { return }
        beforeStart?()
        self.purpose = purpose; errorMessage = nil; state = .preparing; status = "准备麦克风…"
        let generation = UUID(); token = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try self.session.beginManualAttempt()
                let granted = await withCheckedContinuation { continuation in
                    AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
                }
                try Task.checkCancellation()
                guard self.token == generation, self.state == .preparing else { return }
                guard granted else { throw LabError.message("请在系统设置允许麦克风权限，以录制原声") }
                try self.session.configure(profile: .mixingSpeaker, speakerOverride: false)
                self.ownsSession = true
                try await Task.sleep(for: .milliseconds(150))
                try Task.checkCancellation()
                guard self.token == generation, self.state == .preparing else { return }
                try self.session.validateForPlayback()
                let route = VoiceHardwareRoute.current()
                guard route.isUsable else { throw LabError.audioUnavailable }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("raw-\(UUID()).caf")
                self.rawURL = url
                let recorder = try AVAudioRecorder(url: url, settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: route.sampleRate,
                    AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
                recorder.delegate = self; recorder.isMeteringEnabled = true
                guard recorder.prepareToRecord(), recorder.record(forDuration: AIAudioLimits.maximumSeconds) else {
                    throw LabError.audioUnavailable
                }
                self.recorder = recorder; self.initialRoute = route; self.startedAt = Date()
                try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:url.path)
                self.state = .running; self.status = "正在录制原声 · 最长 60 秒"
                self.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, let recorder = self.recorder, self.state == .running else { return }
                        recorder.updateMeters()
                        let level = Float(pow(10, Double(recorder.averagePower(forChannel: 0))/20))
                        self.inputLevel = level.isFinite ? min(1,max(0,level)) : 0
                    }
                }
            } catch {
                if self.token == generation { self.fail(error) }
            }
        }
    }
    func stop(saveRecording: Bool = true) {
        guard state == .preparing || state == .running else { return }
        token = UUID(); task?.cancel(); task = nil; routeTask?.cancel(); routeTask = nil
        timer?.invalidate(); timer = nil; inputLevel = 0
        let url = rawURL, selectedPurpose = purpose, date = startedAt
        recorder?.delegate = nil; recorder?.stop(); recorder = nil; rawURL = nil; initialRoute = nil
        releaseSession()
        guard saveRecording, let url else {
            if let url { try? FileManager.default.removeItem(at: url) }
            state = .idle; status = "录音已停止"; return
        }
        state = .saving; status = "保存原声…"
        let generation = token
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save original speech") { [weak self] in
            Task { @MainActor [weak self] in self?.task?.cancel(); self?.endBackgroundTask() }
        }
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.endBackgroundTask(); if self.token == generation { self.task = nil } }
            var destination: URL?
            do {
                let work = Task.detached { try AIRequestAudio.make(url:url, limit:AIAudioLimits.maximumSeconds) }
                let prepared = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                defer { try? FileManager.default.removeItem(at: prepared); try? FileManager.default.removeItem(at: url) }
                try Task.checkCancellation()
                guard self.token == generation else { return }
                let id = UUID(), name = AudioNaming.generated(kind:"原声",fileExtension:"wav",date:date,id:id)
                let saved = try AudioFileManager.audioDirectory().appendingPathComponent(name); destination = saved
                try FileManager.default.moveItem(at: prepared, to: saved)
                try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:saved.path)
                let label = selectedPurpose == .revoice ? "重新配音原声" : "AI 原声"
                var asset = try AudioFileManager.inspect(url:saved,displayName:name,id:id,source:.voiceLabRecording,presetName:label)
                asset.addedAt = Date(); try AudioFileManager.register(asset)
                let record = VoiceLabRecord(id:UUID(),date:date,asset:asset,preset:VoicePreset.original,strength:0,
                    mixed:false,voiceVolume:1,musicVolume:0,masterVolume:1,musicSettings:nil)
                let updated = [record] + self.recordings
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(updated).write(to:Self.recordsURL(),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
                self.recordings = updated; self.state = .idle; self.status = "原声已保存"
                self.logger.log("原声已保存", "asset=\(asset.id)，时长=\(asset.duration)")
                self.onSaved?(asset,selectedPurpose)
            } catch {
                try? FileManager.default.removeItem(at:url)
                if let destination {
                    try? FileManager.default.removeItem(at:destination)
                    try? FileManager.default.removeItem(at:destination.appendingPathExtension("metadata.json"))
                }
                if self.token == generation { self.fail(error) }
            }
        }
    }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let url = recorder.url
        Task { @MainActor [weak self] in
            guard let self, self.rawURL == url, self.state == .running else { return }
            if flag { self.stop() } else { self.fail(LabError.audioUnavailable) }
        }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let url = recorder.url
        Task { @MainActor [weak self] in
            guard let self, self.rawURL == url else { return }
            self.fail(LabError.audioUnavailable)
        }
    }
    func handle(_ event: AudioSessionEvent) {
        guard isActive else { return }
        switch event {
        case .routeChanged:
            guard state == .running else { return }
            routeTask?.cancel()
            routeTask = Task { [weak self] in
                do { try await Task.sleep(for:.milliseconds(150)) } catch { return }
                guard let self, self.state == .running else { return }
                if self.initialRoute != VoiceHardwareRoute.current() || self.recorder?.isRecording != true {
                    self.fail(LabError.message("麦克风或采样格式已改变，请重新录音"))
                }
            }
        case .interruptionBegan, .environmentUnavailable, .mediaLost, .mediaReset:
            if state != .saving { fail(LabError.audioUnavailable) }
        default: break
        }
    }
    private func fail(_ error: Error) {
        stop(saveRecording:false)
        state = .failed; errorMessage = userFacingAudioError(error); status = "录音未完成，请重试"
        logger.log("原声录音失败",diagnosticError(error))
    }
    private func releaseSession() { if ownsSession { ownsSession = false; session.deactivate() } }
    private func endBackgroundTask() {
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
    }
    func removeRecord(for assetID: UUID) throws {
        guard !isActive else { throw LabError.audioUnavailable }
        let updated = recordings.filter { $0.asset.id != assetID }
        guard updated.count != recordings.count else { return }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(updated).write(to:Self.recordsURL(),options:.atomic); recordings = updated
    }
}
