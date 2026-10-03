import AVFoundation
import XCTest
@testable import AudioRelayLab

final class AIConversionTests: XCTestCase {
    func testLocalEndpointAndRemoteHTTPSValidation() throws {
        for address in ["http://192.168.1.8:7867","http://10.0.0.2:7867","http://172.16.0.4:7867","http://voice.local:7867","https://voice.example.com"] {
            XCTAssertNoThrow(try AIEndpoint.validate(address))
        }
        for address in ["http://example.com","http://8.8.8.8","http://192.168.999.1","file:///tmp","http://a:b@192.168.1.1","http://192.168.1.1?token=x"] {
            XCTAssertThrowsError(try AIEndpoint.validate(address))
        }
    }
    func testRequestAudioIsMonoPCM16At22050HzWithChosenRange() throws {
        let input = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"fixture",withExtension:"wav"))
        let prepared = try AIRequestAudio.make(url:input,start:0.2,limit:0.5)
        defer { try? FileManager.default.removeItem(at:prepared) }
        let file = try AVAudioFile(forReading:prepared)
        XCTAssertEqual(file.processingFormat.sampleRate,22050)
        XCTAssertEqual(file.processingFormat.channelCount,1)
        XCTAssertEqual(file.fileFormat.commonFormat,.pcmFormatInt16)
        XCTAssertEqual(Double(file.length)/22050,0.5,accuracy:0.004)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:1024))
        try file.read(into:buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        let samples = (0..<Int(buffer.frameLength)).map { channel[$0] }
        XCTAssertTrue(samples.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(samples.map(abs).max() ?? 0,0.01)
    }
    func testInvalidRangeRejectedBeforeUpload() throws {
        let input = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"fixture",withExtension:"wav"))
        for offset in [-1.0,Double.nan,Double.infinity,30] {
            XCTAssertThrowsError(try AIRequestAudio.make(url:input,start:offset))
        }
        XCTAssertThrowsError(try AIRequestAudio.make(url:input,limit:0.1))
    }
    func testAIProvenanceRoundTripAndLegacyAssetDecode() throws {
        let metadata = AIConversionMetadata(engine:"Seed-VC v2",sourceRevision:String(repeating:"a",count:40),
            device:"cuda",sampleRate:22050,duration:1,sha256:String(repeating:"b",count:64),voiceID:"female",
            voiceName:"自然女声",referenceOrigin:"authorized reference",conversionSeconds:2,
            settings:["steps":30,"similarity":0.7])
        var asset = AudioAsset(id:UUID(),fileName:"AI.wav",sandboxFileName:"local.wav",duration:1,
            sampleRate:22050,channelCount:1,byteCount:44144,source:.aiConverted)
        asset.aiConversion = metadata
        let restored = try JSONDecoder().decode(AudioAsset.self,from:JSONEncoder().encode(asset))
        XCTAssertEqual(restored.source,.aiConverted)
        XCTAssertEqual(restored.aiConversion?.sha256,metadata.sha256)
        let legacy = try JSONDecoder().decode(AudioAsset.self,from:Data("{\"sandboxFileName\":\"test-tone.wav\"}".utf8))
        XCTAssertEqual(legacy.source,.bundled)
        XCTAssertNil(legacy.aiConversion)
    }
    func testCalibrationMeasuresMaleFundamentalAndComputesTargetShift() throws {
        let rate = 22050.0
        let samples = (0..<Int(rate*1.5)).map { Float(0.25*sin(2*Double.pi*120*Double($0)/rate)) }
        let measured = try VoiceCalibration.fundamental(samples:samples,sampleRate:rate)
        XCTAssertEqual(measured,120,accuracy:1)
        let shift = try VoiceCalibration.pitchShift(source:measured,target:210)
        XCTAssertEqual(Double(shift),12*log2(210/120),accuracy:0.2)
        XCTAssertThrowsError(try VoiceCalibration.fundamental(samples:[Float](repeating:0,count:33075),sampleRate:rate))
    }
    func testCalibrationClampsExtremeShiftAndRejectsNonFiniteInputs() throws {
        XCTAssertEqual(try VoiceCalibration.pitchShift(source:65,target:400),12)
        XCTAssertEqual(try VoiceCalibration.pitchShift(source:400,target:65),-12)
        XCTAssertThrowsError(try VoiceCalibration.pitchShift(source:.nan,target:210))
    }
    func testRecordedAIMixCreatesDecodableNonSilentProtectedPCM() throws {
        let input = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"fixture",withExtension:"wav"))
        let asset = try RecordedVoiceMixer.mix(voiceURL:input,musicURL:input,
            settings:.init(startOffset:0.2,playbackRate:2),volumes:.init(voice:1,music:0.04,master:0.9))
        defer { try? AudioFileManager.removeAudio(asset) }
        XCTAssertEqual(asset.source,.mixedRecording)
        XCTAssertEqual(asset.sampleRate,48000)
        XCTAssertEqual(asset.channelCount,1)
        let reader = try AVAudioFile(forReading:AudioFileManager.url(for:asset))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:reader.processingFormat,frameCapacity:AVAudioFrameCount(reader.length)))
        try reader.read(into:buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        let peak = (0..<Int(buffer.frameLength)).map { abs(channel[$0]) }.max() ?? 0
        XCTAssertGreaterThan(peak,0.01)
        XCTAssertLessThanOrEqual(peak,0.981)
    }
}
