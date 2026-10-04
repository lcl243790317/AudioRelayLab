import XCTest
@testable import AudioRelayLab

final class VoiceMixTests:XCTestCase {
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
        }
    }
    @MainActor func testMixFreezesSelectionAndSettingsThenNewMusicStartsWithIndependentDefaults() throws {
        let voice = asset(.aiConverted,seconds:90),first = asset(.imported,seconds:15),second = asset(.bundled,seconds:4)
        let mix = VoiceMixController(); mix.voiceID = voice.id; mix.musicID = first.id
        mix.settings = .init(startOffset:1,playbackRate:1.5,endOffset:12)
        let frozen = try mix.request(library:[voice,first,second],volumes:.init(voice:0.8,music:0.04,master:0.9))
        mix.musicID = second.id
        XCTAssertEqual(mix.settings,AudioPlaybackSettings()); XCTAssertEqual(frozen.music.id,first.id)
        XCTAssertEqual(frozen.settings.startOffset,1); XCTAssertEqual(frozen.settings.playbackRate,1.5)
        XCTAssertEqual(frozen.voice.duration,90)
    }
    @MainActor func testMissingSourcesInvalidRangeAndOverlongVoiceRejectBeforeMixing() throws {
        let mix = VoiceMixController(),voice = asset(.voiceLabRecording,seconds:181),music = asset(.imported)
        mix.voiceID = voice.id; mix.musicID = music.id
        XCTAssertThrowsError(try mix.request(library:[voice,music],volumes:.init()))
        let valid = asset(.aiConverted); mix.voiceID = valid.id; mix.settings.startOffset = 5
        XCTAssertThrowsError(try mix.request(library:[valid,music],volumes:.init()))
        mix.settings = .init(); XCTAssertThrowsError(try mix.request(library:[music],volumes:.init()))
    }
}
