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
    var voiceStartDelay: Double = 0
    var musicStartDelay: Double = 0
    var musicTailDuration: Double = 0
    static let maximumTailSeconds = 60.0
    init(voiceStartDelay:Double = 0,musicStartDelay:Double = 0,musicTailDuration:Double = 0) {
        self.voiceStartDelay = voiceStartDelay; self.musicStartDelay = musicStartDelay; self.musicTailDuration = musicTailDuration
    }
    private enum CodingKeys:String,CodingKey { case voiceStartDelay, musicStartDelay, musicTailDuration }
    init(from decoder:Decoder) throws {
        let values = try decoder.container(keyedBy:CodingKeys.self)
        voiceStartDelay = try values.decodeIfPresent(Double.self,forKey:.voiceStartDelay) ?? 0
        musicStartDelay = try values.decodeIfPresent(Double.self,forKey:.musicStartDelay) ?? 0
        musicTailDuration = try values.decodeIfPresent(Double.self,forKey:.musicTailDuration) ?? 0
    }
    func validate() throws {
        guard voiceStartDelay.isFinite, (0...60).contains(voiceStartDelay),
              musicStartDelay.isFinite, musicStartDelay >= 0,
              voiceStartDelay == 0 || musicStartDelay == 0,
              musicTailDuration.isFinite, (0...Self.maximumTailSeconds).contains(musicTailDuration) else {
            throw LabError.message("请选择一种起播顺序；人声延后与音乐尾声为 0～60 秒，加入时间不能为负数")
        }
    }
    func outputDuration(voiceDuration:Double,musicDuration:Double? = nil) throws -> Double {
        try validate(); try RevoiceLimits.output(voiceDuration)
        if let musicDuration {
            guard musicDuration.isFinite, musicDuration > 0, voiceStartDelay <= musicDuration else {
                throw LabError.message("人声延后不能超过所选音乐片段的实际播放时长")
            }
        }
        let duration = voiceStartDelay + voiceDuration + musicTailDuration
        guard musicStartDelay < duration else {
            throw LabError.message("背景音乐的加入时间必须早于成品结束；请提前加入或增加尾声时长")
        }
        return duration
    }
}
