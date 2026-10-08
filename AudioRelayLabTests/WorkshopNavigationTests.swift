import AVFoundation
import XCTest
@testable import AudioRelayLab

final class WorkshopNavigationTests:XCTestCase {
    @MainActor func testRevoiceMixAndLibraryBringVerifiedAudioToPlaybackWithoutStartingOrResettingDrafts() throws {
        let selected = UserDefaults.standard.data(forKey:"selectedAudio")
        defer { UserDefaults.standard.set(selected,forKey:"selectedAudio") }
        let data = RevoiceTestAudio.wav(seconds:1),choice = RevoiceChoice.custom(speaker:"Serena",instruction:"自然")
        let audio = try RevoiceWAV.validate(data,response:RevoiceTestAudio.response(data,choice:choice,duration:1),choice:choice,totalSeconds:1)
        let context = RevoiceSaveContext(id:UUID(),createdAt:Date(),choice:choice,voiceName:"Serena",instruction:"自然",
            fixedReferenceID:nil,recognizedText:nil,text:"成品原文",sourceAudioID:nil)
        let revoice = try RevoiceSaving.save(audio,context:context)
        defer { try? AudioFileManager.removeAudio(revoice) }
        let music = try AudioFileManager.loadBundledAudio()
        let mix = try RecordedVoiceMixer.mix(voiceURL:AudioFileManager.url(for:revoice),musicURL:AudioFileManager.url(for:music),
            settings:.init(),volumes:.init(),voiceAsset:revoice,musicAsset:music)
        defer { try? AudioFileManager.removeAudio(mix) }
        let model = ExperimentCoordinator(draftStore:nil)
        model.revoice.text = "还在编辑的另一份草稿"; model.revoice.kind = .custom; model.revoice.instruction = "另一份表达"
        model.voiceMix.voiceID = revoice.id; model.voiceMix.musicID = music.id; model.voiceMix.settings.startOffset = 0.5
        model.voiceMix.timing = .init(voiceStartDelay:2,musicTailDuration:3)
        let settings = model.voiceMix.settings,timing = model.voiceMix.timing
        for (asset,tab) in [(revoice,AppNavigation.Tab.workshop),(mix,.workshop),(music,.library)] {
            model.navigation.tab = tab
            XCTAssertTrue(model.navigation.useForPlayback(asset,coordinator:model))
            XCTAssertEqual(model.navigation.tab,.playback); XCTAssertEqual(model.audio?.id,asset.id)
            XCTAssertEqual(model.state,.idle); XCTAssertFalse(model.isRunning); XCTAssertFalse(model.preview.isActive)
            XCTAssertEqual(model.revoice.text,"还在编辑的另一份草稿"); XCTAssertEqual(model.revoice.instruction,"另一份表达")
            XCTAssertEqual(model.voiceMix.settings,settings); XCTAssertEqual(model.voiceMix.timing,timing)
        }
    }
    @MainActor func testMissingAudioAndActiveOperationKeepPageValidSelectionAndFormalPlayback() throws {
        let selected = UserDefaults.standard.data(forKey:"selectedAudio")
        defer { UserDefaults.standard.set(selected,forKey:"selectedAudio") }
        let model = ExperimentCoordinator(draftStore:nil),original = try XCTUnwrap(model.audio)
        model.navigation.tab = .library
        let missing = AudioAsset(id:UUID(),fileName:"已删除的成品.wav",sandboxFileName:"missing-\(UUID()).wav",duration:1,
            sampleRate:24000,channelCount:1,byteCount:48044,source:.aiConverted)
        XCTAssertFalse(model.navigation.useForPlayback(missing,coordinator:model))
        XCTAssertEqual(model.navigation.tab,.library); XCTAssertEqual(model.audio?.id,original.id); XCTAssertNotNil(model.errorMessage)
        XCTAssertNotNil(model.navigation.playbackSelectionFailure)
        XCTAssertTrue(model.navigation.playbackSelectionFailure?.message.contains("原选择已保留") == true)
        model.navigation.dismissPlaybackSelectionFailure(); XCTAssertNil(model.navigation.playbackSelectionFailure)
        model.prepare(); defer { model.stop() }
        let state = model.state
        XCTAssertFalse(model.navigation.useForPlayback(original,coordinator:model))
        XCTAssertEqual(model.navigation.tab,.library); XCTAssertEqual(model.state,state); XCTAssertTrue(model.isRunning)
        XCTAssertTrue(model.errorMessage?.contains("结束") == true)
        XCTAssertTrue(model.navigation.playbackSelectionFailure?.message.contains("结束") == true)
        model.preview.stop(owner:UUID())
        let owner = UUID()
        model.navigation.previewPageAppeared(owner:owner,tab:.library)
        model.navigation.stopActivePagePreview(model.preview)
        XCTAssertEqual(model.state,state); XCTAssertTrue(model.isRunning)
    }
    @MainActor func testWorkshopOwnerStopsPreparationAndOldScreenCannotStopNewPreview() async throws {
        let selected = UserDefaults.standard.data(forKey:"selectedAudio")
        defer { UserDefaults.standard.set(selected,forKey:"selectedAudio") }
        let model = ExperimentCoordinator(draftStore:nil),asset = try XCTUnwrap(model.audio)
        let revoice = UUID(),mix = UUID(),library = UUID()
        defer { model.preview.stop() }
        for owner in [revoice,mix,library] {
            model.audition(asset,owner:owner); XCTAssertEqual(model.preview.state,.preparing)
            model.preview.stop(owner:owner)
            for _ in 0..<5 { await Task.yield() }
            XCTAssertFalse(model.preview.isActive); XCTAssertEqual(model.preview.currentTime,0); XCTAssertNil(model.preview.errorMessage)
        }
        model.audition(asset,owner:mix); model.preview.stop(owner:revoice)
        XCTAssertTrue(model.preview.isOwned(by:mix)); XCTAssertFalse(model.preview.hasContext(owner:revoice))
        XCTAssertEqual(model.preview.state,.preparing)
        model.audition(asset,owner:library); model.preview.stop(owner:mix)
        XCTAssertTrue(model.preview.isOwned(by:library))
        model.navigation.tab = .workshop
        model.navigation.previewPageAppeared(owner:revoice,tab:.workshop)
        model.navigation.previewPageAppeared(owner:mix,tab:.workshop)
        model.navigation.previewPageDisappeared(owner:revoice)
        model.audition(asset,owner:mix)
        model.navigation.stopActivePagePreview(model.preview)
        XCTAssertFalse(model.preview.isActive)
    }
    @MainActor func testPreviewErrorsAndProgressBelongToTheirOriginatingPage() async throws {
        let model = ExperimentCoordinator(draftStore:nil),asset = try XCTUnwrap(model.audio)
        let first = UUID(),second = UUID()
        let missing = AudioAsset(id:UUID(),fileName:"missing.wav",sandboxFileName:"missing-\(UUID()).wav",duration:1,
            sampleRate:24000,channelCount:1,byteCount:48044,source:.imported)
        model.audition(missing,owner:first)
        for _ in 0..<100 where model.preview.state == .preparing { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(model.preview.state,.failed); XCTAssertTrue(model.preview.hasContext(owner:first)); XCTAssertNotNil(model.preview.errorMessage)
        model.audition(asset,owner:second)
        XCTAssertFalse(model.preview.hasContext(owner:first)); XCTAssertNil(model.preview.errorMessage); XCTAssertEqual(model.preview.currentTime,0)
        model.preview.stop(owner:first); XCTAssertTrue(model.preview.isOwned(by:second)); model.preview.stop(owner:second)
    }
    @MainActor func testFiveSecondPreviewCompletionRetainsProgressUntilItsOwnerExits() async throws {
        let model = ExperimentCoordinator(draftStore:nil),asset = try AudioFileManager.loadBundledAudio(),owner = UUID(),other = UUID()
        defer { model.preview.stop() }
        model.preview.play(asset:asset,settings:.init(volume:0),fiveSeconds:true,owner:owner)
        for _ in 0..<100 where model.preview.state == .preparing { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(model.preview.state,.playing,model.preview.errorMessage ?? "")
        for _ in 0..<120 where model.preview.isActive { try await Task.sleep(for:.milliseconds(50)) }
        XCTAssertEqual(model.preview.state,.idle); XCTAssertNil(model.preview.errorMessage)
        XCTAssertGreaterThan(model.preview.currentTime,4.5); XCTAssertLessThan(model.preview.currentTime,6)
        XCTAssertTrue(model.preview.hasContext(owner:owner)); XCTAssertFalse(model.preview.isOwned(by:owner))
        let completed = model.preview.currentTime
        model.preview.stop(owner:other); XCTAssertEqual(model.preview.currentTime,completed)
        model.preview.stop(owner:owner); XCTAssertEqual(model.preview.currentTime,0)
        model.preview.play(asset:asset,settings:.init(volume:0),fiveSeconds:true,owner:owner)
        model.preview.stop(owner:owner)
        try await Task.sleep(for:.milliseconds(100))
        XCTAssertFalse(model.preview.isActive); XCTAssertEqual(model.preview.currentTime,0)
        model.preview.play(asset:asset,settings:.init(volume:0),fiveSeconds:true,owner:owner)
        for _ in 0..<100 where model.preview.state == .preparing { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(model.preview.state,.playing,model.preview.errorMessage ?? "")
        model.preview.stop(owner:owner)
        try await Task.sleep(for:.milliseconds(100))
        XCTAssertFalse(model.preview.isActive); XCTAssertEqual(model.preview.currentTime,0)
        XCTAssertEqual(model.state,.idle)
    }
}
