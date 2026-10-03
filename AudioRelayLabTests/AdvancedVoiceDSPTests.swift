import XCTest
@testable import AudioRelayLab

final class AdvancedVoiceDSPTests: XCTestCase {
    private let rate = 44100.0
    private var neutral: VoicePreset {
        VoicePreset(id:"test",name:"test",pitch:0,formant:0,highpass:20,lowmid:0,presence:0,
            compression:0,deesser:0,outputGain:1,gateDepth:0,consonantProtection:0)
    }
    private func sine(_ hz: Double, amplitude: Double) -> [Float] {
        (0..<Int(rate*2)).map { Float(amplitude*sin(2*Double.pi*hz*Double($0)/rate)) }
    }
    private func render(_ input: [Float], preset: VoicePreset) throws -> ([Float],Int) {
        let context = try VoiceDSPContext(sampleRate:rate)
        try context.apply(preset,strength:1)
        var result = [Float](repeating:0,count:input.count)
        input.withUnsafeBufferPointer { source in result.withUnsafeMutableBufferPointer { target in
            if let s = source.baseAddress, let t = target.baseAddress {
                context.process(input:s,output:t,frames:UInt32(input.count))
            }
        }}
        XCTAssertTrue(result.allSatisfy { $0.isFinite && abs($0)<=0.981 })
        return (result,Int(context.latencyFrames)+1)
    }
    private func rms(_ samples: [Float]) -> Double {
        let tail = samples.suffix(Int(rate))
        return sqrt(tail.reduce(0.0) { $0+Double($1*$1) }/Double(tail.count))
    }
    func testAdvancedParametersValidateAndLegacyDecodesWithoutLosingOldValues() throws {
        var preset = neutral
        preset.presenceQ = 0
        XCTAssertThrowsError(try preset.validate())
        preset = neutral; preset.attackMS = .nan
        XCTAssertThrowsError(try preset.validate())
        let old = Data("{\"id\":\"female\",\"name\":\"旧女声\",\"pitch\":7,\"formant\":2.8}".utf8)
        let restored = try JSONDecoder().decode(VoicePreset.self,from:old)
        XCTAssertEqual(restored.pitch,7)
        XCTAssertEqual(restored.attackMS,10)
        XCTAssertEqual(restored.presenceHz,2500)
        XCTAssertNoThrow(try restored.validate())
    }
    func testSoftNoiseGateAttenuatesLowNoiseAndPreservesSpokenLevel() throws {
        var gated = neutral
        gated.gateDepth = 1; gated.gateThresholdDB = -30
        let quiet = sine(440,amplitude:0.003)
        let open = try render(quiet,preset:neutral).0
        let closed = try render(quiet,preset:gated).0
        XCTAssertLessThan(rms(closed),rms(open)*0.15)
        let speech = sine(220,amplitude:0.2)
        XCTAssertGreaterThan(rms(try render(speech,preset:gated).0),rms(try render(speech,preset:neutral).0)*0.85)
    }
    func testCompressorThresholdAndRatioReduceLoudVoiceWithoutMutingIt() throws {
        var compressed = neutral
        compressed.compression = 1; compressed.compressorThresholdDB = -20; compressed.compressorRatio = 4
        let loud = sine(220,amplitude:0.7)
        let open = rms(try render(loud,preset:neutral).0)
        let limited = rms(try render(loud,preset:compressed).0)
        XCTAssertLessThan(limited,open*0.6)
        XCTAssertGreaterThan(limited,open*0.1)
    }
    func testParametricPresenceBoostTargetsSelectedBand() throws {
        var tuned = neutral
        tuned.presence = 10; tuned.presenceHz = 2000; tuned.presenceQ = 2
        let mid = sine(2000,amplitude:0.04), low = sine(220,amplitude:0.04)
        let midRatio = rms(try render(mid,preset:tuned).0)/rms(try render(mid,preset:neutral).0)
        let lowRatio = rms(try render(low,preset:tuned).0)/rms(try render(low,preset:neutral).0)
        XCTAssertGreaterThan(midRatio,2.5)
        XCTAssertLessThan(lowRatio,1.1)
    }
    func testConsonantProtectionRestoresUnvoicedArticulationInsteadOfOriginalVowelPitch() throws {
        var seed: UInt32 = 12345
        var previous:Float = 0
        let input:[Float] = (0..<Int(rate*2)).map { _ in
            seed = seed &* 1664525 &+ 1013904223
            let sample = Float(Double(seed)/Double(UInt32.max)-0.5)*0.12
            defer { previous = sample }
            return sample-previous
        }
        var shifted = neutral; shifted.pitch = 7
        let plain = try render(input,preset:shifted)
        shifted.consonantProtection = 1
        let protected = try render(input,preset:shifted)
        func correlation(_ rendered:([Float],Int)) -> Double {
            var xy=0.0,xx=0.0,yy=0.0
            for i in Int(rate)..<input.count {
                let x=Double(input[i-rendered.1]),y=Double(rendered.0[i])
                xy+=x*y;xx+=x*x;yy+=y*y
            }
            return xy/sqrt(xx*yy)
        }
        XCTAssertGreaterThan(correlation(protected),correlation(plain)+0.2)
        let vowel = try render(sine(220,amplitude:0.2),preset:shifted).0
        var crossings=0
        for i in Int(rate)+1..<vowel.count { if vowel[i-1]<=0 && vowel[i]>0 { crossings+=1 } }
        XCTAssertEqual(Double(crossings),220*pow(2,7.0/12),accuracy:4)
    }
}
