import Foundation

struct AudioMixParameters: Codable, Equatable {
    var voice: Float = 1
    var music: Float = 0.04
    var master: Float = 0.9
    func validate() throws {
        guard [voice,music,master].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw LabError.invalidFormat }
    }
    func sample(voiceSample: Float, musicSample: Float) -> Float {
        min(0.98, max(-0.98, (voiceSample*voice + musicSample*music)*master))
    }
}

/// Placement on the mixed output timeline, independent of the music's source trim.
struct AudioMixTiming: Codable, Equatable {
    var musicStartDelay: Double = 0
    var musicTailDuration: Double = 0
    static let maximumTailSeconds = 60.0
    func validate() throws {
        guard musicStartDelay.isFinite, musicStartDelay >= 0,
              musicTailDuration.isFinite, (0...Self.maximumTailSeconds).contains(musicTailDuration) else {
            throw LabError.message("音乐加入时间不能为负数，尾声时长为 0～60 秒")
        }
    }
    func outputDuration(voiceDuration:Double) throws -> Double {
        try validate(); try RevoiceLimits.output(voiceDuration)
        let duration = voiceDuration + musicTailDuration
        guard musicStartDelay < duration else {
            throw LabError.message("背景音乐的加入时间必须早于成品结束；请提前加入或增加尾声时长")
        }
        return duration
    }
}
