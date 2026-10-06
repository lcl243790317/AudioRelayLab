import AVFoundation
import XCTest
@testable import AudioRelayLab

final class LibraryVoiceFeedbackTests: XCTestCase {
    @MainActor func testBatchDeletionReportsPartialFailureAndRetryClearsReferencesWithoutLosingDraft() throws {
        let savedSelection = UserDefaults.standard.data(forKey:"selectedAudio")
        defer { UserDefaults.standard.set(savedSelection,forKey:"selectedAudio") }
        let fixture = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"fixture",withExtension:"wav"))
        let first = try AudioFileManager.copyIntoLibrary(fixture,displayName:"first.wav",source:.voiceLabRecording)
        let second = try AudioFileManager.copyIntoLibrary(fixture,displayName:"second.wav",source:.imported)
        defer { try? AudioFileManager.removeAudio(first); try? AudioFileManager.removeAudio(second) }
        let history = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:history) }
        let model = ExperimentCoordinator(historyDirectoryURL:history)
        try model.selectAudio(first); model.prepare(); model.stop()
        let count = model.store.experiments.count
        model.aiVoice.selectInput(first); model.revoice.selectInput(first)
        model.revoice.kind = .custom; model.revoice.text = "保留的用户草稿"; model.revoice.usesAutomaticInstruction = true
        model.revoice.editAutomaticInstruction("手动表达"); let draft = model.revoice.automaticInstructionDraft
        model.voiceMix.voiceID = first.id; model.voiceMix.musicID = second.id
        model.audition(first,owner:UUID())
        let result = model.deleteAudio(ids:[first.id,second.id]) { asset in
            if asset.id == second.id { throw LabError.message("测试删除失败") }
            try AudioFileManager.removeAudio(asset)
        }
        XCTAssertEqual(result.deletedIDs,[first.id]); XCTAssertEqual(Set(result.failures.keys),[second.id])
        XCTAssertFalse(model.preview.isActive); XCTAssertNil(model.aiVoice.input); XCTAssertNil(model.revoice.input)
        XCTAssertNil(model.voiceMix.voiceID); XCTAssertEqual(model.voiceMix.musicID,second.id)
        XCTAssertEqual(model.revoice.text,"保留的用户草稿"); XCTAssertEqual(model.revoice.automaticInstructionDraft,draft)
        XCTAssertEqual(model.store.experiments.count,count); XCTAssertEqual(model.audio?.source,.bundled)
        XCTAssertFalse(FileManager.default.fileExists(atPath:try AudioFileManager.url(for:first).appendingPathExtension("metadata.json").path))
        XCTAssertTrue(model.library.contains { $0.id == second.id })
        let retried = model.deleteAudio(ids:Set(result.failures.keys))
        XCTAssertEqual(retried.deletedIDs,[second.id]); XCTAssertTrue(retried.failures.isEmpty)
        XCTAssertNil(model.voiceMix.musicID); XCTAssertEqual(model.store.experiments.count,count)
    }
    @MainActor func testBatchDeletionProtectsBuiltinAndDoesNotRollbackOtherSuccesses() throws {
        let fixture = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"fixture",withExtension:"wav"))
        let asset = try AudioFileManager.importFile(from:fixture)
        defer { try? AudioFileManager.removeAudio(asset) }
        let model = ExperimentCoordinator(),builtin = try AudioFileManager.loadBundledAudio()
        model.refreshLibrary()
        let result = model.deleteAudio(ids:[asset.id,builtin.id])
        XCTAssertEqual(result.deletedIDs,[asset.id]); XCTAssertEqual(Set(result.failures.keys),[builtin.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath:try AudioFileManager.url(for:builtin).path))
        XCTAssertFalse(model.library.contains { $0.id == asset.id })
    }
    @MainActor func testBatchDeletionDuringMixingRejectsEveryItemBeforeRemovingAnything() throws {
        let fixture = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"fixture",withExtension:"wav"))
        let asset = try AudioFileManager.importFile(from:fixture)
        defer { try? AudioFileManager.removeAudio(asset) }
        let model = ExperimentCoordinator(); model.refreshLibrary(); try model.beginMixing()
        defer { model.endMixing() }
        var called = false
        let result = model.deleteAudio(ids:[asset.id]) { _ in called = true }
        XCTAssertFalse(called); XCTAssertTrue(result.deletedIDs.isEmpty); XCTAssertNotNil(result.failures[asset.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath:try AudioFileManager.url(for:asset).path))
    }
    func testGeneratedNamesDistinguishSourceAndTakeInFilesAndLibrary() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let id = UUID()
        let raw = AudioNaming.generated(kind:"原声",fileExtension:"caf",date:date,id:id)
        let ai = AudioNaming.generated(kind:"AI成品",label:"自然女声",fileExtension:"wav",date:date,id:id)
        let second = AudioNaming.generated(kind:"原声",fileExtension:"caf",date:date)
        XCTAssertNotEqual(raw,ai); XCTAssertNotEqual(raw,second)
        XCTAssertTrue(raw.hasPrefix("原声_")); XCTAssertTrue(ai.hasPrefix("AI成品_自然女声_"))
        XCTAssertTrue(raw.contains(String(id.uuidString.prefix(8))))
        let unsafe = AudioNaming.generated(kind:"AI成品",label:"test/voice\\name\nnext",fileExtension:"wav")
        XCTAssertEqual(URL(fileURLWithPath:unsafe).lastPathComponent,unsafe)
        XCTAssertFalse(unsafe.contains("\n"))
    }
    func testLegacyIdenticalNamesReceiveDistinctSourceAndIdentityLabels() {
        let raw = AudioAsset(id:UUID(),fileName:"录音.wav",sandboxFileName:"old1.wav",duration:1,
            sampleRate:22050,channelCount:1,byteCount:44000,source:.voiceLabRecording,presetName:"AI 原声")
        let ai = AudioAsset(id:UUID(),fileName:"录音.wav",sandboxFileName:"old2.wav",duration:1,
            sampleRate:22050,channelCount:1,byteCount:44000,source:.aiConverted)
        XCTAssertNotEqual(raw.libraryName,ai.libraryName)
        XCTAssertTrue(raw.libraryName.contains("原声录音")); XCTAssertTrue(ai.libraryName.contains("AI 成品"))
        XCTAssertEqual(raw.sandboxFileName,"old1.wav")
    }
    @MainActor func testDeletingSelectedAudioClearsAIInputAndKeepsExperimentHistory() throws {
        let original = UserDefaults.standard.data(forKey:"selectedAudio")
        defer { UserDefaults.standard.set(original,forKey:"selectedAudio") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("delete-history-\(UUID())")
        defer { try? FileManager.default.removeItem(at:folder) }
        let fixture = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"fixture",withExtension:"wav"))
        let asset = try AudioFileManager.importFile(from:fixture)
        defer { try? AudioFileManager.removeAudio(asset) }
        let url = try AudioFileManager.url(for:asset)
        let coordinator = ExperimentCoordinator(historyDirectoryURL:folder)
        try coordinator.selectAudio(asset); coordinator.aiVoice.selectInput(asset)
        coordinator.prepare(); coordinator.stop()
        let count = coordinator.store.experiments.count
        XCTAssertGreaterThan(count,0)
        coordinator.deleteAudio(asset)
        XCTAssertFalse(FileManager.default.fileExists(atPath:url.path))
        XCTAssertFalse(coordinator.library.contains { $0.id == asset.id })
        XCTAssertNil(coordinator.aiVoice.input)
        XCTAssertEqual(coordinator.audio?.source,.bundled)
        XCTAssertEqual(coordinator.store.experiments.count,count)
    }
    @MainActor func testDeletionRejectsActivePlaybackAndPreservesBuiltinTestTone() throws {
        let fixture = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"fixture",withExtension:"wav"))
        let asset = try AudioFileManager.importFile(from:fixture)
        let original = UserDefaults.standard.data(forKey:"selectedAudio")
        defer { try? AudioFileManager.removeAudio(asset); UserDefaults.standard.set(original,forKey:"selectedAudio") }
        let coordinator = ExperimentCoordinator()
        try coordinator.selectAudio(asset); coordinator.prepare()
        coordinator.deleteAudio(asset)
        XCTAssertTrue(FileManager.default.fileExists(atPath:try AudioFileManager.url(for:asset).path))
        coordinator.stop(); coordinator.useTestAudio()
        try coordinator.beginMixing()
        coordinator.deleteAudio(asset)
        XCTAssertTrue(FileManager.default.fileExists(atPath:try AudioFileManager.url(for:asset).path))
        coordinator.endMixing()
        let builtin = try XCTUnwrap(coordinator.audio)
        coordinator.deleteAudio(builtin)
        XCTAssertTrue(FileManager.default.fileExists(atPath:try AudioFileManager.url(for:builtin).path))
        XCTAssertEqual(coordinator.audio?.id,builtin.id)
    }
    func testLibrarySortsAllSourcesByAddedTimeWithBuiltinLast() throws {
        let fixture = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"fixture",withExtension:"wav"))
        var assets: [AudioAsset] = []
        defer { for asset in assets { try? AudioFileManager.removeAudio(asset) } }
        for (index, source) in [AudioSource.imported,.voiceLabRecording,.aiConverted,.mixedRecording].enumerated() {
            var asset = try AudioFileManager.copyIntoLibrary(fixture,displayName:"\(4-index).wav",source:source)
            assets.append(asset)
            asset.addedAt = Date(timeIntervalSince1970:Double(index+1))
            // Simulate stored records with arbitrary dates and names.
            let url = try AudioFileManager.url(for:asset)
            try JSONEncoder().encode(asset).write(to:url.appendingPathExtension("metadata.json"))
        }
        let ids = Set(assets.map(\.id))
        let loaded = try AudioFileManager.listLocalAudio().filter { ids.contains($0.id) }
        XCTAssertEqual(loaded.map(\.source),[.mixedRecording,.aiConverted,.voiceLabRecording,.imported])
        XCTAssertEqual(try AudioFileManager.listLocalAudio().filter { ids.contains($0.id) }.map(\.id),loaded.map(\.id))
        let recordings = loaded.filter { [.voiceLabRecording,.aiConverted,.mixedRecording].contains($0.source) }
        XCTAssertEqual(recordings.map(\.source),[.mixedRecording,.aiConverted,.voiceLabRecording])
        let builtin = try AudioFileManager.loadBundledAudio()
        XCTAssertEqual((loaded+[builtin]).sorted(by:AudioFileManager.newestFirst).last?.id,builtin.id)
        try AudioFileManager.removeAudio(loaded[0])
        XCTAssertEqual(try AudioFileManager.listLocalAudio().filter { ids.contains($0.id) }.map(\.id),Array(loaded.dropFirst()).map(\.id))
    }
    func testLegacyTimestampFallbackAndReregistrationDoNotReorder() throws {
        let fixture = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"fixture",withExtension:"wav"))
        var asset = try AudioFileManager.importFile(from:fixture)
        defer { try? AudioFileManager.removeAudio(asset) }
        let url = try AudioFileManager.url(for:asset), sidecar = url.appendingPathExtension("metadata.json")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(asset)) as? [String:Any])
        legacy.removeValue(forKey:"addedAt")
        try JSONSerialization.data(withJSONObject:legacy).write(to:sidecar)
        let loaded = try XCTUnwrap(AudioFileManager.listLocalAudio().first { $0.id == asset.id })
        XCTAssertNotNil(loaded.addedAt)
        asset.addedAt = Date(timeIntervalSince1970:9_999_999_999)
        try AudioFileManager.register(asset)
        let updated = try XCTUnwrap(AudioFileManager.listLocalAudio().first { $0.id == asset.id })
        XCTAssertEqual(updated.addedAt,loaded.addedAt)
        XCTAssertEqual(updated.id,asset.id)
        XCTAssertEqual(updated.sandboxFileName,asset.sandboxFileName)
    }
    func testEqualTimestampsHaveStableOrderAndCodableCompatibility() throws {
        let a = AudioAsset(id:UUID(),fileName:"a",sandboxFileName:"a.wav",duration:1,sampleRate:22050,channelCount:1,byteCount:2)
        let b = AudioAsset(id:UUID(),fileName:"b",sandboxFileName:"b.wav",duration:1,sampleRate:22050,channelCount:1,byteCount:2)
        XCTAssertEqual([a,b].sorted(by:AudioFileManager.newestFirst).map(\.id),[b,a].sorted(by:AudioFileManager.newestFirst).map(\.id))
        XCTAssertFalse(AudioFileManager.newestFirst(a,a))
        XCTAssertNil(try JSONDecoder().decode(AudioAsset.self,from:JSONEncoder().encode(a)).addedAt)
    }
    @MainActor func testLibraryAuditionPreservesSelectedAudioAndRange() throws {
        let fixture = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"fixture",withExtension:"wav"))
        let asset = try AudioFileManager.importFile(from:fixture)
        let original = UserDefaults.standard.data(forKey:"selectedAudio")
        defer { try? AudioFileManager.removeAudio(asset); UserDefaults.standard.set(original,forKey:"selectedAudio") }
        let coordinator = ExperimentCoordinator()
        let selected = coordinator.audio?.id
        coordinator.editing.startOffset = 0.1
        let editing = coordinator.editing, applied = coordinator.applied
        coordinator.audition(asset)
        XCTAssertEqual(coordinator.audio?.id,selected)
        XCTAssertEqual(coordinator.editing,editing)
        XCTAssertEqual(coordinator.applied,applied)
        coordinator.preview.stop()
    }

    @MainActor func testLibraryExitCancelsPreparingPreviewAndItsLateCompletion() async throws {
        let original = UserDefaults.standard.data(forKey:"selectedAudio")
        defer { UserDefaults.standard.set(original,forKey:"selectedAudio") }
        let coordinator = ExperimentCoordinator()
        let asset = try XCTUnwrap(coordinator.audio)
        let owner = UUID()
        defer { coordinator.preview.stop() }
        coordinator.audition(asset,owner:owner)
        XCTAssertEqual(coordinator.preview.state,.preparing)
        coordinator.preview.stop(owner:owner)
        XCTAssertEqual(coordinator.preview.state,.idle)
        // Give the cancelled preparation task a chance to run after leaving.
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(coordinator.preview.state,.idle)
        XCTAssertFalse(coordinator.preview.isActive)
    }

    @MainActor func testLibraryExitOnlyStopsItsOwnPreview() throws {
        let original = UserDefaults.standard.data(forKey:"selectedAudio")
        defer { UserDefaults.standard.set(original,forKey:"selectedAudio") }
        let coordinator = ExperimentCoordinator()
        let asset = try XCTUnwrap(coordinator.audio)
        let firstLibrary = UUID(), nextLibrary = UUID()
        defer { coordinator.preview.stop() }
        coordinator.audition(asset,owner:firstLibrary)
        coordinator.audition(asset,owner:nextLibrary)
        coordinator.preview.stop(owner:firstLibrary)
        XCTAssertEqual(coordinator.preview.state,.preparing)
        coordinator.preview.stop(owner:nextLibrary)
        XCTAssertEqual(coordinator.preview.state,.idle)

        coordinator.audition(asset)
        coordinator.preview.stop(owner:firstLibrary)
        XCTAssertEqual(coordinator.preview.state,.preparing)
    }

    @MainActor func testLibraryExitStopsAlreadyPlayingPreview() async throws {
        let fixture = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"fixture",withExtension:"wav"))
        let asset = try AudioFileManager.importFile(from:fixture)
        defer { try? AudioFileManager.removeAudio(asset) }
        let logger = DiagnosticsLogger(), session = AudioSessionManager(logger:logger)
        let preview = PreviewPlaybackController(session:session,logger:logger)
        let owner = UUID()
        defer { preview.stop() }
        preview.play(asset:asset,settings:.init(volume:0),fiveSeconds:false,owner:owner)
        for _ in 0..<100 where preview.state == .preparing { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(preview.state,.playing,preview.errorMessage ?? "")
        preview.stop(owner:owner)
        XCTAssertEqual(preview.state,.idle)
        XCTAssertNil(preview.preparedDuration)
        XCTAssertFalse(preview.isActive)
    }

    @MainActor func testLeavingLibraryKeepsPreparedDelayedExperiment() throws {
        let original = UserDefaults.standard.data(forKey:"selectedAudio")
        defer { UserDefaults.standard.set(original,forKey:"selectedAudio") }
        let coordinator = ExperimentCoordinator()
        defer { coordinator.stop(); coordinator.preview.stop() }
        coordinator.prepare()
        XCTAssertEqual(coordinator.state,.preparing)
        coordinator.preview.stop(owner:UUID())
        XCTAssertEqual(coordinator.state,.preparing)
        XCTAssertTrue(coordinator.isRunning)
    }

}
