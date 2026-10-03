import AVFAudio

/// Render playback speed before scheduling. The AVAudioPlayer device-clock gate stays at 1x.
enum RateAdjustedAudio {
    static func copy(of url:URL, startOffset:TimeInterval, rate:Float, duration:TimeInterval?, endOffset:TimeInterval? = nil) throws -> URL {
        let file = try AVAudioFile(forReading:url)
        let format = file.processingFormat
        try AudioRuntimeValidation.validate(format)
        let selected = try AudioPlaybackSettings(startOffset:startOffset,playbackRate:rate,endOffset:endOffset).validated(duration:Double(file.length)/format.sampleRate)
        let first = try AudioPlaybackSettings.frame(startOffset,sampleRate:format.sampleRate,length:file.length)
        if let duration {
            guard duration.isFinite, (0.1...600).contains(duration) else { throw LabError.invalidFormat }
        }
        let sourceFrames = try selected.selectedFrameCount(sampleRate:format.sampleRate,length:file.length,sourceLimit:duration)
        let outputLength = ceil(Double(sourceFrames)/Double(rate))
        guard sourceFrames>0, sourceFrames<=Int64(UInt32.max), outputLength.isFinite,
            outputLength*Double(format.channelCount)*4 <= 512*1024*1024 else {
            throw LabError.message("倍速准备后的 PCM 超过 512 MB，请缩短源播放时长或调整起点")
        }
        let engine = AVAudioEngine(), node = AVAudioPlayerNode(), pitch = AVAudioUnitTimePitch()
        engine.attach(node); engine.attach(pitch)
        engine.connect(node,to:pitch,format:format)
        engine.connect(pitch,to:engine.mainMixerNode,format:format)
        pitch.rate = rate
        try engine.enableManualRenderingMode(.offline,format:format,maximumFrameCount:4096)
        defer { node.stop(); engine.stop(); engine.disableManualRenderingMode() }
        node.scheduleSegment(file,startingFrame:first,frameCount:UInt32(sourceFrames),at:nil)
        try engine.start(); node.play()
        let latency = pitch.auAudioUnit.latency
        guard latency.isFinite, (0...2).contains(latency),
            let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4096) else { throw LabError.invalidFormat }
        let skip = Int64(ceil(latency*format.sampleRate)), needed = Int64(outputLength)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("rate-\(UUID()).caf")
        do {
            let writer = try AVAudioFile(forWriting:destination,settings:format.settings)
            var rendered:Int64=0, written:Int64=0, stalls=0
            while written<needed {
                try Task.checkCancellation()
                let n = AVAudioFrameCount(min(4096,needed+skip-rendered))
                guard n>0 else { throw LabError.invalidFormat }
                let status = try engine.renderOffline(n,to:buffer)
                if status == .success {
                    guard buffer.frameLength>0 else { throw LabError.invalidFormat }
                    stalls=0
                    let discard = Int(min(Int64(buffer.frameLength),max(0,skip-rendered)))
                    rendered += Int64(buffer.frameLength)
                    if discard>0 {
                        guard let channels = buffer.floatChannelData else { throw LabError.invalidFormat }
                        let left = Int(buffer.frameLength)-discard
                        for ch in 0..<Int(format.channelCount) {
                            for i in 0..<left { channels[ch][i] = channels[ch][i+discard] }
                        }
                        buffer.frameLength = AVAudioFrameCount(left)
                    }
                    if buffer.frameLength>0 { try writer.write(from:buffer); written += Int64(buffer.frameLength) }
                } else {
                    stalls += 1
                    guard status != .error, stalls<=100 else { throw LabError.message("音频倍速离线渲染未能继续，请重试") }
                }
            }
            return destination
        } catch { try? FileManager.default.removeItem(at:destination); throw error }
    }
}
