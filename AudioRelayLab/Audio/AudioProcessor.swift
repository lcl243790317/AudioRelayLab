import AVFAudio

enum AudioProcessor {
    static func optimizedCopy(of url: URL) throws -> URL {
        let source = try AVAudioFile(forReading: url)
        let format = source.processingFormat
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
            Double(source.length) / format.sampleRate <= 600 else {
            throw LabError.message("语音优化支持最长 10 分钟、可解码为浮点 PCM 的音频")
        }
        guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192),
            let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                channels: 1, interleaved: false),
            let output = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 8192) else {
            throw LabError.message("语音优化缓冲分配失败")
        }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).caf")
        do {
            let writer = try AVAudioFile(forWriting: destination, settings: monoFormat.settings)
            var peak: Float = 0
            while source.framePosition < source.length {
                try source.read(into: input)
                guard input.frameLength > 0, let channels = input.floatChannelData else { break }
                for index in 0..<Int(input.frameLength) {
                    var value: Float = 0
                    for channel in 0..<Int(format.channelCount) { value += channels[channel][index] / Float(format.channelCount) }
                    peak = max(peak, abs(value))
                }
            }
            // 只衰减，不提升安静音频；轻量 3:1 软拐点压缩，留出滤波余量。
            let gain: Float = peak > 0.7 ? 0.7 / peak : 1
            source.framePosition = 0
            while source.framePosition < source.length {
                try source.read(into: input)
                guard input.frameLength > 0, let channels = input.floatChannelData,
                    let samples = output.floatChannelData?[0] else { break }
                output.frameLength = input.frameLength
                for index in 0..<Int(input.frameLength) {
                    var value: Float = 0
                    for channel in 0..<Int(format.channelCount) { value += channels[channel][index] / Float(format.channelCount) }
                    value *= gain
                    let magnitude = abs(value)
                    if magnitude > 0.45 { value = (value < 0 ? -1 : 1) * (0.45 + (magnitude - 0.45) / 3) }
                    samples[index] = min(0.7, max(-0.7, value))
                }
                try writer.write(from: output)
            }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
    static func configure(eq: AVAudioUnitEQ, sampleRate: Double) {
        eq.globalGain = -2
        eq.bands[0].filterType = .highPass
        eq.bands[0].frequency = Float(min(120, sampleRate * 0.1))
        eq.bands[0].bypass = false
        eq.bands[1].filterType = .lowPass
        eq.bands[1].frequency = Float(min(7500, sampleRate * 0.45))
        eq.bands[1].bypass = false
    }
}
