import AVFAudio

final class VoiceDSPContext: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer
    init(sampleRate: Double) throws {
        guard let pointer = VLCreate(sampleRate) else { throw LabError.message("无法配置变声 DSP") }
        self.pointer = pointer
    }
    deinit { VLDestroy(pointer) }
    func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frames: UInt32) {
        VLProcess(pointer, input, output, frames)
    }
    func enqueueRecording(_ buffer: AVAudioPCMBuffer) { VLRecordPush(pointer, buffer.audioBufferList, buffer.frameLength) }
    var latencyFrames: UInt32 { VLLatency(pointer) }
    func apply(_ preset: VoicePreset, strength: Float) throws {
        try preset.validate()
        guard strength.isFinite, (0...1).contains(strength) else { throw LabError.invalidFormat }
        VLParameters(pointer, preset.pitch * strength, preset.formant * strength, preset.highpass,
                     preset.lowmid, preset.presence, preset.air, preset.compression, preset.deesser,
                     preset.wet * strength, preset.outputGain, preset.robot * strength)
    }
}

/// Audio callbacks only fill the C++ SPSC ring. This queue exclusively owns file IO.
final class VoiceRecordingWriter: @unchecked Sendable {
    let url: URL
    private let context: VoiceDSPContext
    private let queue = DispatchQueue(label: "AudioRelayLab.recording")
    private let buffer: AVAudioPCMBuffer
    private var file: AVAudioFile?
    private var timer: DispatchSourceTimer?
    private var failure: Error?
    private var frames: AVAudioFramePosition = 0
    private let maximumFrames: AVAudioFramePosition
    init(context: VoiceDSPContext, sampleRate: Double) throws {
        self.context = context
        guard sampleRate.isFinite, (8_000...384_000).contains(sampleRate) else { throw LabError.invalidFormat }
        maximumFrames = AVAudioFramePosition(sampleRate * 600)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { throw LabError.invalidFormat }
        self.buffer = buffer
        url = try AudioFileManager.audioDirectory().appendingPathComponent("recording-\(UUID()).caf")
        file = try AVAudioFile(forWriting: url, settings: format.settings)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.drain() }
        self.timer = timer; timer.resume()
    }
    private func drain() {
        guard failure == nil, let file, let samples = buffer.floatChannelData?[0] else { return }
        do {
            while true {
                let count = VLRecordRead(context.pointer, samples, buffer.frameCapacity)
                if count == 0 { break }
                guard frames + AVAudioFramePosition(count) <= maximumFrames else { throw LabError.message("录音达到 10 分钟上限，请停止并保存") }
                buffer.frameLength = count
                try file.write(from: buffer); frames += AVAudioFramePosition(count)
            }
            guard VLDropped(context.pointer) == 0 else { throw LabError.message("处理或录音缓冲发生丢帧，不能标为完整录音") }
        } catch { failure = error }
    }
    func currentFailure() -> Error? { queue.sync { failure } }
    /// Call only after removing taps and stopping the engine, so no producer remains.
    func finish() throws -> URL {
        timer?.cancel(); timer = nil
        return try queue.sync {
            drain(); file = nil
            if let failure { try? FileManager.default.removeItem(at: url); throw failure }
            guard frames > 0 else { try? FileManager.default.removeItem(at: url); throw LabError.message("录音未收到音频，请检查麦克风和路由") }
            return url
        }
    }
    func discard() {
        timer?.cancel(); timer = nil
        queue.sync { file = nil; try? FileManager.default.removeItem(at: url) }
    }
    deinit { timer?.cancel() }
}
