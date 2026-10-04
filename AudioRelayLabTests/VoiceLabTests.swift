import AVFAudio
import XCTest
@testable import AudioRelayLab

final class VoiceLabTests: XCTestCase {
    func testLegacyPresetMissingParametersGetsValidDefaults() throws {
        let preset = try JSONDecoder().decode(VoicePreset.self, from: Data("{\"id\":\"old\",\"name\":\"旧音色\"}".utf8))
        XCTAssertEqual(preset.pitch, 0); XCTAssertEqual(preset.formant, 0)
        XCTAssertEqual(preset.wet, 1); XCTAssertNoThrow(try preset.validate())
    }
    func testLegacyVoiceRecordDefaultsAndParameterAuditRoundTrip() throws {
        let asset = try AudioFileManager.generateTestAudio()
        let original = VoiceLabRecord(id:UUID(),date:Date(),asset:asset,preset:VoicePreset(id:"female",name:"旧女声",pitch:7,formant:2.8),strength:0.7,mixed:true,
            voiceVolume:0.8,musicVolume:0.04,masterVolume:0.9,musicSettings:.init(startOffset:0.3,playbackRate:2,volume:0.04),
            parameterEvents:[.init(date:Date(),preset:VoicePreset(id:"low",name:"旧低音",pitch:-2,formant:-1),strength:0.8,volumes:.init(music:0.04),musicSettings:nil)])
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(VoiceLabRecord.self,from:data)
        XCTAssertEqual(decoded.parameterEvents.count,1); XCTAssertEqual(decoded.parameterEvents[0].preset,VoicePreset(id:"low",name:"旧低音",pitch:-2,formant:-1))
        XCTAssertEqual(decoded.musicSettings?.startOffset,0.3); XCTAssertEqual(decoded.musicSettings?.playbackRate,2)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        for key in ["strength","voiceVolume","musicVolume","masterVolume","musicSettings","parameterEvents"] { object.removeValue(forKey:key) }
        let legacy = try decoder.decode(VoiceLabRecord.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertEqual(legacy.strength,1); XCTAssertEqual(legacy.musicVolume,0.04); XCTAssertEqual(legacy.masterVolume,0.9)
        XCTAssertTrue(legacy.parameterEvents.isEmpty); XCTAssertNil(legacy.musicSettings)
    }
    func testPresetRejectsOutOfRangeParameters() {
        XCTAssertThrowsError(try VoicePreset(id:"bad",name:"bad",pitch:13,formant:0).validate())
        XCTAssertThrowsError(try VoicePreset(id:"bad",name:"bad",pitch:0,formant:.nan).validate())
        XCTAssertThrowsError(try VoicePreset(id:"bad",name:"bad",pitch:0,formant:0,wet:1.01).validate())
    }
    func testIndependentMixVolumesAndBounds() throws {
        XCTAssertNoThrow(try AudioMixParameters().validate())
        XCTAssertThrowsError(try AudioMixParameters(voice: .nan).validate())
        XCTAssertThrowsError(try AudioMixParameters(music: 1.1).validate())
        XCTAssertEqual(AudioMixParameters(voice:1,music:0,master:0.5).sample(voiceSample:0.4,musicSample:1),0.2,accuracy:0.00001)
        XCTAssertEqual(AudioMixParameters(voice:0,music:0.04,master:1).sample(voiceSample:1,musicSample:0.5),0.02,accuracy:0.00001)
        XCTAssertEqual(AudioMixParameters(voice:1,music:1,master:0).sample(voiceSample:1,musicSample:1),0)
    }
    func testAdvancedParametersValidateAndLegacyDecodesWithoutLosingOldValues() throws {
        var preset = VoicePreset.original
        preset.presenceQ = 0
        XCTAssertThrowsError(try preset.validate())
        preset = VoicePreset.original; preset.attackMS = .nan
        XCTAssertThrowsError(try preset.validate())
        let old = Data("{\"id\":\"female\",\"name\":\"旧女声\",\"pitch\":7,\"formant\":2.8}".utf8)
        let restored = try JSONDecoder().decode(VoicePreset.self,from:old)
        XCTAssertEqual(restored.pitch,7)
        XCTAssertEqual(restored.attackMS,10)
        XCTAssertEqual(restored.presenceHz,2500)
        XCTAssertNoThrow(try restored.validate())
    }
    private func nativeMixEnergy(_ mix:AudioMixParameters) throws -> Double {
        let source = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"fixture",withExtension:"wav"))
        let asset = try RecordedVoiceMixer.mix(voiceURL:source,musicURL:source,
            settings:.init(startOffset:0.3,playbackRate:2),volumes:mix)
        defer { try? AudioFileManager.removeAudio(asset) }
        let file = try AVAudioFile(forReading:AudioFileManager.url(for:asset))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:UInt32(file.length)))
        try file.read(into:buffer)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        let n = min(24000,Int(buffer.frameLength))
        XCTAssertGreaterThan(n,0)
        var energy = 0.0
        for i in 0..<n { XCTAssertTrue(samples[i].isFinite); energy += Double(samples[i]*samples[i]) }
        return energy/Double(n)
    }
    func testNativeMixerRendersVoiceMusicSeekRateAndIndependentVolumes() throws {
        let voice = try nativeMixEnergy(.init(voice:1,music:0,master:0.9))
        let music = try nativeMixEnergy(.init(voice:0,music:0.4,master:0.9))
        let mixed = try nativeMixEnergy(.init(voice:1,music:0.4,master:0.9))
        XCTAssertGreaterThan(voice,0.0001); XCTAssertGreaterThan(music,0.0001)
        XCTAssertGreaterThan(mixed,voice*1.02)
        XCTAssertLessThan(try nativeMixEnergy(.init(voice:1,music:1,master:0)),0.0000001)
    }
    @MainActor func testCancelVoiceStartBeforePermissionOrActivation() async {
        let logger = DiagnosticsLogger(); let session = AudioSessionManager(logger:logger)
        let recorder = RawVoiceRecorder(session:session,logger:logger)
        recorder.start(.computerConversion); XCTAssertEqual(recorder.state,.preparing)
        recorder.stop(saveRecording:false)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(recorder.state,.idle)
        XCTAssertFalse(logger.entries().contains { $0.message.contains("setActive(true)") })
    }
}
