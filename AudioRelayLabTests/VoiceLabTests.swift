import AVFAudio
import AudioToolbox
import XCTest
@testable import AudioRelayLab

final class VoiceLabTests: XCTestCase {
    func testAllFifteenPresetsAreDistinctAndValid() throws {
        XCTAssertEqual(VoicePreset.all.count, 15)
        XCTAssertEqual(Set(VoicePreset.all.map(\.id)).count, 15)
        XCTAssertEqual(Set(VoicePreset.all).count, 15)
        for preset in VoicePreset.all { XCTAssertNoThrow(try preset.validate()) }
    }
    func testPresetCodableRoundTrip() throws {
        for preset in VoicePreset.all {
            XCTAssertEqual(try JSONDecoder().decode(VoicePreset.self, from: JSONEncoder().encode(preset)), preset)
        }
    }
    func testLegacyPresetMissingParametersGetsValidDefaults() throws {
        let preset = try JSONDecoder().decode(VoicePreset.self, from: Data("{\"id\":\"old\",\"name\":\"旧音色\"}".utf8))
        XCTAssertEqual(preset.pitch, 0); XCTAssertEqual(preset.formant, 0)
        XCTAssertEqual(preset.wet, 1); XCTAssertNoThrow(try preset.validate())
    }
    func testLegacyVoiceRecordDefaultsAndParameterAuditRoundTrip() throws {
        let asset = try AudioFileManager.generateTestAudio()
        let original = VoiceLabRecord(id:UUID(),date:Date(),asset:asset,preset:VoicePreset.all[1],strength:0.7,mixed:true,
            voiceVolume:0.8,musicVolume:0.04,masterVolume:0.9,musicSettings:.init(startOffset:0.3,playbackRate:2,volume:0.04),
            parameterEvents:[.init(date:Date(),preset:VoicePreset.all[2],strength:0.8,volumes:.init(music:0.04),musicSettings:nil)])
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(VoiceLabRecord.self,from:data)
        XCTAssertEqual(decoded.parameterEvents.count,1); XCTAssertEqual(decoded.parameterEvents[0].preset,VoicePreset.all[2])
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
    func testDSPRejectsInvalidSampleRateAndStrength() throws {
        XCTAssertThrowsError(try VoiceDSPContext(sampleRate: 0))
        XCTAssertThrowsError(try VoiceDSPContext(sampleRate: .nan))
        let dsp = try VoiceDSPContext(sampleRate: 44_100)
        XCTAssertThrowsError(try dsp.apply(VoicePreset.all[1], strength: .infinity))
        XCTAssertThrowsError(try dsp.apply(VoicePreset.all[1], strength: -0.1))
    }
    private func signal() -> [Float] {
        (0..<88200).map { Float(0.2*sin(2*Double.pi*220*Double($0)/44100)+0.05*sin(2*Double.pi*440*Double($0)/44100)) }
    }
    private func render(_ preset: VoicePreset, strength: Float = 1) throws -> [Float] {
        let dsp = try VoiceDSPContext(sampleRate: 44_100)
        try dsp.apply(preset, strength: strength)
        let input = signal()
        var output = [Float](repeating:0,count:input.count)
        input.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { output in
                if let source = input.baseAddress, let target = output.baseAddress {
                    dsp.process(input: source, output: target, frames: UInt32(input.count))
                }
            }
        }
        return output
    }
    func testEveryPresetProcessesRealPCMWithoutNaNOrClipping() throws {
        for preset in VoicePreset.all {
            let output = try render(preset)
            XCTAssertTrue(output.allSatisfy { $0.isFinite && abs($0)<=0.981 })
            XCTAssertGreaterThan(output.dropFirst(44100).map { abs($0) }.max() ?? 0, 0.005)
        }
    }
    func testPitchPresetChangesWaveformBeyondDrySignal() throws {
        let dry = try render(VoicePreset.all[0])
        let wet = try render(VoicePreset.all[1])
        let difference = zip(dry.dropFirst(44100),wet.dropFirst(44100)).reduce(0.0) { $0+Double(abs($1.0-$1.1)) }/44100
        XCTAssertGreaterThan(difference, 0.01)
    }
    func testStrengthZeroMatchesOriginalDelayedSignal() throws {
        var original = VoicePreset.all[0]
        original.outputGain = VoicePreset.all[1].outputGain
        let dry = try render(original)
        let zero = try render(VoicePreset.all[1], strength:0)
        let difference = zip(dry.dropFirst(44100),zero.dropFirst(44100)).reduce(0.0) { $0+Double(abs($1.0-$1.1)) }/44100
        XCTAssertLessThan(difference, 0.0001)
    }
    func testPresetSwitchKeepsOutputFinite() throws {
        let dsp = try VoiceDSPContext(sampleRate:44100)
        let input = signal()
        var output = [Float](repeating:0,count:input.count)
        for offset in stride(from:0,to:input.count,by:512) {
            if offset % 4096 == 0 { try dsp.apply(VoicePreset.all[(offset/4096)%15], strength:0.8) }
            let n = min(512,input.count-offset)
            input.withUnsafeBufferPointer { source in output.withUnsafeMutableBufferPointer { target in
                if let s = source.baseAddress, let t = target.baseAddress { dsp.process(input:s+offset,output:t+offset,frames:UInt32(n)) }
            }}
        }
        XCTAssertTrue(output.allSatisfy(\.isFinite))
    }
    func testIndependentMixVolumesAndBounds() throws {
        XCTAssertNoThrow(try AudioMixParameters().validate())
        XCTAssertThrowsError(try AudioMixParameters(voice: .nan).validate())
        XCTAssertThrowsError(try AudioMixParameters(music: 1.1).validate())
        XCTAssertEqual(AudioMixParameters(voice:1,music:0,master:0.5).sample(voiceSample:0.4,musicSample:1),0.2,accuracy:0.00001)
        XCTAssertEqual(AudioMixParameters(voice:0,music:0.04,master:1).sample(voiceSample:1,musicSample:0.5),0.02,accuracy:0.00001)
        XCTAssertEqual(AudioMixParameters(voice:1,music:1,master:0).sample(voiceSample:1,musicSample:1),0)
    }
    private func recording(mix: AudioMixParameters) throws {
        try mix.validate()
        let dsp = try VoiceDSPContext(sampleRate:44100)
        let writer = try VoiceRecordingWriter(context:dsp,sampleRate:44100)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate:44100,channels:1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:2048))
        let data = try XCTUnwrap(buffer.floatChannelData?[0]); buffer.frameLength = 2048
        for i in 0..<2048 { data[i] = mix.sample(voiceSample:0.2,musicSample:0.1) }
        dsp.enqueueRecording(buffer)
        let url = try writer.finish()
        defer { try? FileManager.default.removeItem(at:url) }
        let info = try AudioFileManager.inspect(url:url,source:.voiceLabRecording)
        XCTAssertEqual(info.channelCount,1); XCTAssertEqual(info.sampleRate,44100)
        XCTAssertEqual(info.duration,2048/44100.0,accuracy:1/44100.0)
        let file = try AVAudioFile(forReading:url)
        let result = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:2048))
        try file.read(into:result)
        XCTAssertEqual(try XCTUnwrap(result.floatChannelData?[0])[100],mix.sample(voiceSample:0.2,musicSample:0.1),accuracy:0.00001)
    }
    func testVoiceOnlyRecordingWritesRealCAFMetadata() throws { try recording(mix:.init(voice:1,music:0,master:1)) }
    func testMusicOnlyRecordingWritesRealCAFMetadata() throws { try recording(mix:.init(voice:0,music:0.04,master:1)) }
    func testVoiceAndMusicRecordingWritesRealCAFMetadata() throws { try recording(mix:.init(voice:0.8,music:0.04,master:0.9)) }
    func testEmptyRecordingFailsAndCleansFile() throws {
        let writer = try VoiceRecordingWriter(context:VoiceDSPContext(sampleRate:44100),sampleRate:44100)
        XCTAssertThrowsError(try writer.finish())
        XCTAssertFalse(FileManager.default.fileExists(atPath:writer.url.path))
    }
    func testDiscardRecordingRemovesFile() throws {
        let writer = try VoiceRecordingWriter(context:VoiceDSPContext(sampleRate:44100),sampleRate:44100)
        XCTAssertTrue(FileManager.default.fileExists(atPath:writer.url.path)); writer.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath:writer.url.path))
    }
    func testPublicAppleOutputLimiterIsAvailableAndConfigurable() throws {
        let effect = try VoiceOutputLimiter.make()
        XCTAssertEqual(effect.audioComponentDescription.componentSubType, kAudioUnitSubType_DynamicsProcessor)
    }
    @MainActor func testCancelVoiceStartBeforePermissionOrActivation() async {
        let logger = DiagnosticsLogger(); let session = AudioSessionManager(logger:logger)
        let engine = VoiceProcessingEngine(session:session,logger:logger)
        engine.start(.voiceRecording); XCTAssertEqual(engine.state,.preparing)
        engine.stop(saveRecording:false)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(engine.state,.idle)
        XCTAssertFalse(logger.entries().contains { $0.message.contains("setActive(true)") })
    }
}
