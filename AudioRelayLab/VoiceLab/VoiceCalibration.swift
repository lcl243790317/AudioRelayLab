import AVFAudio

enum VoiceCalibration {
    /// YIN difference/normalized cumulative difference on voiced frames, median rejects outliers.
    static func fundamental(samples:[Float], sampleRate:Double) throws -> Double {
        guard sampleRate.isFinite, sampleRate >= 8000, samples.allSatisfy(\.isFinite) else { throw LabError.invalidFormat }
        let rate = 8000.0, step = sampleRate/rate
        let count = Int(Double(samples.count)/step)
        guard count >= 1024 else { throw LabError.message("原声太短，请录制至少一秒清晰说话") }
        let signal = (0..<count).map { index -> Double in
            let position = Double(index)*step, first = Int(position)
            let second = min(samples.count-1,first+1), fraction = position-Double(first)
            return Double(samples[first])*(1-fraction)+Double(samples[second])*fraction
        }
        var pitches:[Double] = []
        let maximumLag = Int(rate/65), minimumLag = Int(rate/400)
        for start in stride(from:0,through:count-1024,by:256) {
            let energy = (0..<512).reduce(0.0) { $0+signal[start+$1]*signal[start+$1] }/512
            if energy < 0.0001 { continue }
            var difference = [Double](repeating:0,count:maximumLag+1)
            var sum = 0.0
            for lag in 1...maximumLag {
                var value = 0.0
                for i in 0..<512 { let delta = signal[start+i]-signal[start+i+lag]; value += delta*delta }
                sum += value; difference[lag] = sum > 0 ? value*Double(lag)/sum : 1
            }
            var lag = minimumLag
            while lag < maximumLag {
                if difference[lag] < 0.15 {
                    while lag+1 <= maximumLag && difference[lag+1] < difference[lag] { lag += 1 }
                    let before = difference[lag-1], at = difference[lag], after = difference[min(maximumLag,lag+1)]
                    let denominator = before+after-2*at
                    let adjustment = abs(denominator) > 0.000001 ? 0.5*(before-after)/denominator : 0
                    let pitch = rate/(Double(lag)+min(0.5,max(-0.5,adjustment)))
                    if (65...400).contains(pitch) { pitches.append(pitch) }
                    break
                }
                lag += 1
            }
        }
        guard pitches.count >= 5 else { throw LabError.message("没有检测到足够稳定的人声，请用正常声量录制说话") }
        pitches.sort(); return pitches[pitches.count/2]
    }
    static func measure(url:URL) throws -> Double {
        let normalized = try AIRequestAudio.make(url:url,limit:8)
        defer { try? FileManager.default.removeItem(at:normalized) }
        let file = try AVAudioFile(forReading:normalized)
        guard let buffer = AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(file.length)) else { throw LabError.invalidFormat }
        try file.read(into:buffer)
        guard let samples = buffer.floatChannelData?[0] else { throw LabError.invalidFormat }
        return try fundamental(samples:Array(UnsafeBufferPointer(start:samples,count:Int(buffer.frameLength))),sampleRate:file.processingFormat.sampleRate)
    }
    static func pitchShift(source:Double,target:Double) throws -> Float {
        guard source.isFinite, target.isFinite, (65...400).contains(source), (65...400).contains(target) else { throw LabError.invalidFormat }
        return Float(min(12,max(-12,12*log2(target/source))))
    }
}
