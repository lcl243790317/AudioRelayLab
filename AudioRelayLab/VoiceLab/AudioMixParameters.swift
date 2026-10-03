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
