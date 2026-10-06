import AVFAudio
import XCTest
@testable import AudioRelayLab

final class VoiceMixTests:XCTestCase {
    func testMusicFirstBoundsUseActualTrimmedRateDurationAndMaximumIs300Seconds() throws {
        XCTAssertEqual(try AudioMixTiming(voiceStartDelay:60,musicTailDuration:60).outputDuration(voiceDuration:180,musicDuration:60),300)
        for value in [-1.0,60.1,Double.nan,Double.infinity] {
            XCTAssertThrowsError(try AudioMixTiming(voiceStartDelay:value).outputDuration(voiceDuration:2,musicDuration:80))
        }
        XCTAssertThrowsError(try AudioMixTiming(voiceStartDelay:1,musicStartDelay:1).outputDuration(voiceDuration:2,musicDuration:80))
        XCTAssertThrowsError(try AudioMixTiming(voiceStartDelay:2).outputDuration(voiceDuration:2,musicDuration:1.9))
        XCTAssertEqual(try AudioMixTiming(voiceStartDelay:2).outputDuration(voiceDuration:2,musicDuration:2),4)
    }
    @MainActor func testMusicFirstRequestFreezesTimingAndRejectsDelayPastSpeedAdjustedClip() throws {
        let voice = asset(.aiConverted),music = asset(.imported,seconds:8),mix = VoiceMixController()
        mix.voiceID = voice.id; mix.musicID = music.id
        mix.settings = .init(startOffset:2,playbackRate:2,endOffset:6); mix.timing = .init(voiceStartDelay:2,musicTailDuration:1)
        let frozen = try mix.request(library:[voice,music],volumes:.init())
        mix.timing.voiceStartDelay = 2.1
        XCTAssertThrowsError(try mix.request(library:[voice,music],volumes:.init()))
        XCTAssertEqual(frozen.timing.voiceStartDelay,2); XCTAssertEqual(frozen.timing.musicTailDuration,1)
    }
    func testVersion164TimingWithoutVoiceDelayDecodesAsZero() throws {
        let data = Data("{\"musicStartDelay\":2.5,\"musicTailDuration\":3}".utf8)
        XCTAssertEqual(try JSONDecoder().decode(AudioMixTiming.self,from:data),.init(musicStartDelay:2.5,musicTailDuration:3))
        let timing = AudioMixTiming(voiceStartDelay:1.2,musicTailDuration:2)
        XCTAssertEqual(try JSONDecoder().decode(AudioMixTiming.self,from:JSONEncoder().encode(timing)),timing)
    }
    func testRenderedMusicIntroAndCompleteDelayedVoiceAcrossSampleRates() throws {
        for rate in [24000.0,44100.0,48000.0] {
            let voiceURL = try tone(seconds:0.8,sampleRate:rate),musicURL = try tone(seconds:2,sampleRate:44100)
            defer { try? FileManager.default.removeItem(at:voiceURL); try? FileManager.default.removeItem(at:musicURL) }
            let timing = AudioMixTiming(voiceStartDelay:0.35,musicTailDuration:0.4)
            for volumes in [AudioMixParameters(voice:1,music:0,master:1),.init(voice:0,music:1,master:1)] {
                let mixed = try RecordedVoiceMixer.mix(voiceURL:voiceURL,musicURL:musicURL,settings:.init(),volumes:volumes,timing:timing)
                defer { try? AudioFileManager.removeAudio(mixed) }
                XCTAssertEqual(mixed.duration,1.55,accuracy:2/48000.0)
                if volumes.voice == 1 {
                    XCTAssertLessThan(try energy(mixed,from:0.1,to:0.25),0.000001)
                    XCTAssertGreaterThan(try energy(mixed,from:0.45,to:0.65),0.01)
                    XCTAssertGreaterThan(try energy(mixed,from:1.02,to:1.12),0.01)
                    XCTAssertLessThan(try energy(mixed,from:1.25,to:1.45),0.000001)
                } else {
                    XCTAssertGreaterThan(try energy(mixed,from:0.1,to:0.25),0.01)
                    XCTAssertGreaterThan(try energy(mixed,from:1.25,to:1.45),0.01)
                }
            }
        }
    }
    private func asset(_ source:AudioSource,seconds:Double = 2) -> AudioAsset {
        .init(id:UUID(),fileName:"fixture.wav",sandboxFileName:"fixture.wav",duration:seconds,
            sampleRate:24000,channelCount:1,byteCount:96044,source:source)
    }
    @MainActor func testMixSourcesIncludeOriginalAndGeneratedVoicesIndependentlyOfLatestResult() throws {
        let original = asset(.voiceLabRecording),generated = asset(.aiConverted),music = asset(.imported)
        let library = [original,generated,music,asset(.bundled),asset(.mixedRecording)]
        let mix = VoiceMixController()
        XCTAssertEqual(VoiceMixController.voices(in:library).map(\.id),[original.id,generated.id])
        XCTAssertEqual(VoiceMixController.music(in:library).count,2)
        for voice in [original,generated] {
            mix.voiceID = voice.id; mix.musicID = music.id
            let request = try mix.request(library:library,volumes:.init())
            XCTAssertEqual(request.voice.id,voice.id); XCTAssertEqual(request.settings.startOffset,0)
            XCTAssertEqual(request.settings.playbackRate,1); XCTAssertNil(request.settings.endOffset)
            XCTAssertEqual(request.timing,AudioMixTiming())
        }
    }
    @MainActor func testMixFreezesSelectionAndSettingsThenNewMusicStartsWithIndependentDefaults() throws {
        let voice = asset(.aiConverted,seconds:90),first = asset(.imported,seconds:15),second = asset(.bundled,seconds:4)
        let mix = VoiceMixController(); mix.voiceID = voice.id; mix.musicID = first.id
        mix.settings = .init(startOffset:1,playbackRate:1.5,endOffset:12)
        mix.timing = .init(musicStartDelay:3,musicTailDuration:2)
        let frozen = try mix.request(library:[voice,first,second],volumes:.init(voice:0.8,music:0.04,master:0.9))
        mix.timing = .init(musicStartDelay:8,musicTailDuration:4)
        mix.musicID = second.id
        XCTAssertEqual(mix.settings,AudioPlaybackSettings()); XCTAssertEqual(frozen.music.id,first.id)
        XCTAssertEqual(frozen.settings.startOffset,1); XCTAssertEqual(frozen.settings.playbackRate,1.5)
        XCTAssertEqual(frozen.voice.duration,90)
        XCTAssertEqual(frozen.timing,.init(musicStartDelay:3,musicTailDuration:2))
        XCTAssertEqual(mix.timing,.init(musicStartDelay:8,musicTailDuration:4))
    }
    @MainActor func testMissingSourcesInvalidRangeAndOverlongVoiceRejectBeforeMixing() throws {
        let mix = VoiceMixController(),voice = asset(.voiceLabRecording,seconds:181),music = asset(.imported)
        mix.voiceID = voice.id; mix.musicID = music.id
        XCTAssertThrowsError(try mix.request(library:[voice,music],volumes:.init()))
        let valid = asset(.aiConverted); mix.voiceID = valid.id; mix.settings.startOffset = 5
        XCTAssertThrowsError(try mix.request(library:[valid,music],volumes:.init()))
        mix.settings = .init(); XCTAssertThrowsError(try mix.request(library:[music],volumes:.init()))
    }

    func testMixTimingValidatesPlacementAndKeepsMaximumVoiceWithTail() throws {
        XCTAssertEqual(try AudioMixTiming().outputDuration(voiceDuration:2),2)
        XCTAssertEqual(try AudioMixTiming(musicStartDelay:200,musicTailDuration:60).outputDuration(voiceDuration:180),240)
        for timing in [AudioMixTiming(musicStartDelay: -1),.init(musicStartDelay:.nan),
                       .init(musicStartDelay:.infinity),.init(musicTailDuration: -1),
                       .init(musicTailDuration:.nan),.init(musicTailDuration:.infinity),
                       .init(musicTailDuration:60.01),.init(musicStartDelay:2),
                       .init(musicStartDelay:3,musicTailDuration:1)] {
            XCTAssertThrowsError(try timing.outputDuration(voiceDuration:2))
        }
        XCTAssertThrowsError(try AudioMixTiming(musicTailDuration:60).outputDuration(voiceDuration:181))
    }

    @MainActor func testInvalidMusicPlacementRejectsBeforeMixing() throws {
        let mix = VoiceMixController(),voice = asset(.aiConverted),music = asset(.imported)
        mix.voiceID = voice.id; mix.musicID = music.id
        mix.timing.musicStartDelay = 2
        XCTAssertThrowsError(try mix.request(library:[voice,music],volumes:.init()))
        mix.timing.musicTailDuration = 1
        XCTAssertEqual(try mix.request(library:[voice,music],volumes:.init()).timing.musicStartDelay,2)
    }

    func testLegacyMixMetadataDefaultsTimingAndNewTimingRoundTrips() throws {
        let original = MixSourceMetadata(voiceAssetID:UUID(),musicAssetID:UUID(),revoice:nil,
            settings:.init(startOffset:1,playbackRate:1.5),volumes:.init(voice:0.8,music:0.2),
            timing:.init(musicStartDelay:2,musicTailDuration:3))
        let encoder = JSONEncoder(),decoder = JSONDecoder()
        let encoded = try encoder.encode(original)
        let current = try decoder.decode(MixSourceMetadata.self,from:encoded)
        XCTAssertEqual(current.effectiveTiming,original.effectiveTiming)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with:encoded) as? [String:Any])
        old.removeValue(forKey:"timing")
        let legacy = try decoder.decode(MixSourceMetadata.self,from:JSONSerialization.data(withJSONObject:old))
        XCTAssertEqual(legacy.effectiveTiming,AudioMixTiming())
        XCTAssertEqual(legacy.voiceAssetID,original.voiceAssetID)
        XCTAssertEqual(legacy.settings,original.settings); XCTAssertEqual(legacy.volumes,original.volumes)
    }

    private func tone(seconds:Double,sampleRate:Double = 24000,start:Double = 0,end:Double? = nil) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mix-tone-\(UUID()).wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate:sampleRate,channels:1))
        let count = AVAudioFrameCount((seconds*sampleRate).rounded())
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:count))
        buffer.frameLength = count
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<Int(count) {
            let time = Double(i)/sampleRate
            samples[i] = time >= start && time < (end ?? seconds) ? Float(0.3*sin(2 * .pi * 880 * time)) : 0
        }
        let writer = try AVAudioFile(forWriting:url,settings:format.settings)
        try writer.write(from:buffer)
        return url
    }
    private func energy(_ asset:AudioAsset,from start:Double,to end:Double) throws -> Double {
        let file = try AVAudioFile(forReading:AudioFileManager.url(for:asset))
        let rate = file.processingFormat.sampleRate
        file.framePosition = AVAudioFramePosition((start*rate).rounded())
        let count = AVAudioFrameCount(((end-start)*rate).rounded())
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:count))
        try file.read(into:buffer,frameCount:count)
        XCTAssertEqual(buffer.frameLength,count)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        return (0..<Int(buffer.frameLength)).reduce(0) { $0 + Double(samples[$1]*samples[$1]) } / Double(buffer.frameLength)
    }

    func testRenderedMusicBeginsAtSelectedOutputTimeAndContinuesThroughTail() throws {
        let voiceURL = try tone(seconds:0.8,sampleRate:44100),musicURL = try tone(seconds:2)
        defer { try? FileManager.default.removeItem(at:voiceURL); try? FileManager.default.removeItem(at:musicURL) }
        let voice = try AudioFileManager.inspect(url:voiceURL,source:.aiConverted)
        let music = try AudioFileManager.inspect(url:musicURL,source:.imported)
        let timing = AudioMixTiming(musicStartDelay:0.35,musicTailDuration:0.4)
        let mixed = try RecordedVoiceMixer.mix(voiceURL:voiceURL,musicURL:musicURL,settings:.init(),
            volumes:.init(voice:0,music:1,master:1),timing:timing,voiceAsset:voice,musicAsset:music)
        defer { try? AudioFileManager.removeAudio(mixed) }
        XCTAssertEqual(mixed.duration,1.2,accuracy:1/48000.0)
        XCTAssertLessThan(try energy(mixed,from:0.1,to:0.25),0.000001)
        XCTAssertGreaterThan(try energy(mixed,from:0.45,to:0.65),0.01)
        XCTAssertGreaterThan(try energy(mixed,from:0.9,to:1.1),0.01)
        let restored = try JSONDecoder().decode(AudioAsset.self,from:JSONEncoder().encode(mixed))
        XCTAssertEqual(restored.mixSource?.effectiveTiming,timing)
    }

    func testMusicMayStartAfterVoiceEndsInsideTail() throws {
        let voiceURL = try tone(seconds:0.4),musicURL = try tone(seconds:2,sampleRate:44100)
        defer { try? FileManager.default.removeItem(at:voiceURL); try? FileManager.default.removeItem(at:musicURL) }
        let mixed = try RecordedVoiceMixer.mix(voiceURL:voiceURL,musicURL:musicURL,settings:.init(),
            volumes:.init(voice:0,music:1,master:1),timing:.init(musicStartDelay:0.6,musicTailDuration:0.8))
        defer { try? AudioFileManager.removeAudio(mixed) }
        XCTAssertEqual(mixed.duration,1.2,accuracy:1/48000.0)
        XCTAssertLessThan(try energy(mixed,from:0.45,to:0.55),0.000001)
        XCTAssertGreaterThan(try energy(mixed,from:0.7,to:1.1),0.01)
    }

    func testTrimAndSpeedRemainIndependentOfDelayAndShortMusicDoesNotLoop() throws {
        let voiceURL = try tone(seconds:0.8),musicURL = try tone(seconds:1,sampleRate:44100,start:0.2,end:0.6)
        defer { try? FileManager.default.removeItem(at:voiceURL); try? FileManager.default.removeItem(at:musicURL) }
        let mixed = try RecordedVoiceMixer.mix(voiceURL:voiceURL,musicURL:musicURL,
            settings:.init(startOffset:0.2,playbackRate:2,endOffset:0.6),volumes:.init(voice:0,music:1,master:1),
            timing:.init(musicStartDelay:0.3,musicTailDuration:0.4))
        defer { try? AudioFileManager.removeAudio(mixed) }
        XCTAssertEqual(mixed.duration,1.2,accuracy:1/48000.0)
        XCTAssertLessThan(try energy(mixed,from:0.1,to:0.2),0.000001)
        XCTAssertGreaterThan(try energy(mixed,from:0.35,to:0.45),0.005)
        XCTAssertLessThan(try energy(mixed,from:0.7,to:1.1),0.000001)
    }

    func testFullVoiceIsPreservedWithTailAndDefaultsKeepPreviousOutputLength() throws {
        let voiceURL = try tone(seconds:0.8,sampleRate:44100),musicURL = try tone(seconds:2)
        defer { try? FileManager.default.removeItem(at:voiceURL); try? FileManager.default.removeItem(at:musicURL) }
        for timing in [AudioMixTiming(),.init(musicStartDelay:0.9,musicTailDuration:0.4)] {
            let mixed = try RecordedVoiceMixer.mix(voiceURL:voiceURL,musicURL:musicURL,settings:.init(),
                volumes:.init(voice:1,music:0,master:1),timing:timing)
            defer { try? AudioFileManager.removeAudio(mixed) }
            XCTAssertEqual(mixed.duration,0.8+timing.musicTailDuration,accuracy:1/48000.0)
            XCTAssertGreaterThan(try energy(mixed,from:0.05,to:0.2),0.01)
            XCTAssertGreaterThan(try energy(mixed,from:0.65,to:0.75),0.01)
            if timing.musicTailDuration > 0 { XCTAssertLessThan(try energy(mixed,from:0.9,to:1.1),0.000001) }
        }
    }
}
