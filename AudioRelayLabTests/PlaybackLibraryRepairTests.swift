import AVFoundation
import XCTest
@testable import AudioRelayLab

final class PlaybackLibraryRepairTests: XCTestCase {
    #if DEBUG
    @MainActor func testInteractionFixtureSwitchesPCMWithoutDuplicateIDsOrChangingUnownedFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        func pcm(_ name:String, seconds:Double, sample:Float) throws -> URL {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate:8000,channels:1))
            let count = AVAudioFrameCount(seconds*8000)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:count))
            buffer.frameLength = count
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            samples.initialize(repeating:sample,count:Int(count))
            let url = directory.appendingPathComponent(name+".wav")
            do { let writer = try AVAudioFile(forWriting:url,settings:format.settings); try writer.write(from:buffer) }
            return url
        }
        let short = try pcm("short-source",seconds:11.7,sample:0.125)
        let long = try pcm("long-source",seconds:93.6,sample:0.25)
        let id = try XCTUnwrap(UUID(uuidString:"16300000-0000-4000-8000-000000000013"))
        let name = "混音测试原声"
        let legacy = directory.appendingPathComponent(name+"-长回听.wav")
        try FileManager.default.copyItem(at:long,to:legacy)
        let legacyPCM = try Data(contentsOf:legacy)
        let legacySidecar = legacy.appendingPathExtension("metadata.json")
        let old = try AudioFileManager.inspect(url:legacy,displayName:name,id:id,source:.voiceLabRecording)
        try JSONEncoder().encode(old).write(to:legacySidecar)

        for (input,seconds,sample) in [(short,11.7,Float(0.125)),(long,93.6,Float(0.25)),(short,11.7,Float(0.125))] {
            let asset = try LibraryInteractionFixture.copy(from:input,directory:directory,name:name,id:id,source:.voiceLabRecording)
            XCTAssertEqual(asset.id,id); XCTAssertEqual(asset.sandboxFileName,name+".wav")
            XCTAssertEqual(asset.duration,seconds,accuracy:1/8000.0)
            let canonical = directory.appendingPathComponent(asset.sandboxFileName)
            XCTAssertEqual(try Data(contentsOf:canonical),try Data(contentsOf:input))
            let reader = try AVAudioFile(forReading:canonical)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:reader.processingFormat,frameCapacity:16))
            try reader.read(into:buffer)
            XCTAssertEqual(try XCTUnwrap(buffer.floatChannelData?[0])[0],sample,accuracy:0.00001)
            XCTAssertFalse(FileManager.default.fileExists(atPath:legacySidecar.path))
            XCTAssertEqual(try Data(contentsOf:legacy),legacyPCM)
            let indexed = try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)
                .filter { $0.lastPathComponent.hasSuffix(".metadata.json") }
                .map { try JSONDecoder().decode(AudioAsset.self,from:Data(contentsOf:$0)) }
            XCTAssertEqual(indexed.filter { $0.id == id }.count,1)
        }
        var foreignMetadata = try AudioFileManager.inspect(url:legacy,displayName:name,id:UUID(),source:.imported)
        let unownedData = try JSONEncoder().encode(foreignMetadata)
        try unownedData.write(to:legacySidecar)
        _ = try LibraryInteractionFixture.copy(from:long,directory:directory,name:name,id:id,source:.voiceLabRecording)
        XCTAssertEqual(try Data(contentsOf:legacySidecar),unownedData)
        XCTAssertEqual(try Data(contentsOf:legacy),legacyPCM)
        let canonical = directory.appendingPathComponent(name+".wav")
        let canonicalSidecar = canonical.appendingPathExtension("metadata.json")
        let before = try Data(contentsOf:canonical)
        foreignMetadata = try AudioFileManager.inspect(url:canonical,displayName:name,id:UUID(),source:.imported)
        let protectedMetadata = try JSONEncoder().encode(foreignMetadata)
        try protectedMetadata.write(to:canonicalSidecar)
        XCTAssertThrowsError(try LibraryInteractionFixture.copy(from:short,directory:directory,name:name,id:id,source:.voiceLabRecording))
        XCTAssertEqual(try Data(contentsOf:canonical),before)
        XCTAssertEqual(try Data(contentsOf:canonicalSidecar),protectedMetadata)
    }
    #endif

    private func asset(_ index:Int,source:AudioSource = .voiceLabRecording) -> AudioAsset {
        AudioAsset(id:UUID(),fileName:"删除测试\(index).wav",sandboxFileName:"fixture-\(index).wav",duration:3,
            sampleRate:44100,channelCount:1,byteCount:264600,source:source)
    }

    func testDeletionRequestKeepsFiveNamesAndIDsAfterSelectionChanges() throws {
        var selected = (1...5).map { asset($0) }
        let ids = Set(selected.map(\.id)), names = selected.map(\.libraryName)
        let request = try XCTUnwrap(AudioDeletionRequest(assets:selected))
        selected.removeAll()
        XCTAssertEqual(request.items.count,5)
        XCTAssertEqual(request.audioIDs,ids)
        XCTAssertEqual(request.items.map(\.name),names)
        let reopened = try XCTUnwrap(AudioDeletionRequest(assets:(1...5).map { asset($0) }))
        XCTAssertNotEqual(request.id,reopened.id)
    }

    func testEmptyAndProtectedSelectionsCannotPresentDeletion() {
        XCTAssertNil(AudioDeletionRequest(assets:[]))
        XCTAssertNil(AudioDeletionRequest(assets:[asset(1,source:.bundled)]))
    }

    func testDeletionRequestExcludesBuiltinAndKeepsVisibleOrder() throws {
        let first = asset(1,source:.imported), second = asset(2,source:.aiConverted)
        let request = try XCTUnwrap(AudioDeletionRequest(assets:[first,asset(3,source:.bundled),second]))
        XCTAssertEqual(request.items.map(\.id),[first.id,second.id])
        XCTAssertEqual(request.audioIDs,[first.id,second.id])
    }

    @MainActor func testApplyingPreviewSettingsPreservesFormalVolumeAndTaskParameters() throws {
        let saved = UserDefaults.standard.data(forKey:"selectedAudio")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = ExperimentCoordinator(historyDirectoryURL:folder)
        defer { model.stop(); model.preview.stop(); UserDefaults.standard.set(saved,forKey:"selectedAudio"); try? FileManager.default.removeItem(at:folder) }
        model.useTestAudio()
        for volume in [0.04,0.20] {
            model.volume = volume
            model.editing = .init(startOffset:1,playbackRate:1.5,volume:0.9,endOffset:4)
            model.applyPlaybackSettings(); model.applyPlaybackSettings()
            XCTAssertEqual(model.volume,volume)
            XCTAssertEqual(model.applied.startOffset,1); XCTAssertEqual(model.applied.endOffset,4)
            XCTAssertEqual(model.applied.playbackRate,1.5); XCTAssertEqual(model.editing.volume,0.9)
            model.prepare()
            let settings = try XCTUnwrap(model.currentExperiment?.settings)
            XCTAssertEqual(settings.volume,Float(volume),accuracy:0.00001)
            XCTAssertEqual(settings.startOffset,1); XCTAssertEqual(settings.endOffset,4); XCTAssertEqual(settings.playbackRate,1.5)
            model.stop()
        }
    }

    @MainActor func testInvalidApplyPreservesFormalVolumeAndPreviouslyAppliedSettings() {
        let model = ExperimentCoordinator()
        defer { model.stop(); model.preview.stop() }
        model.volume = 0.04
        let applied = model.applied
        model.editing.volume = .nan
        model.applyPlaybackSettings()
        XCTAssertEqual(model.volume,0.04); XCTAssertEqual(model.applied,applied)
        XCTAssertNotNil(model.errorMessage)
    }

    @MainActor func testPlaybackPageExitCancelsBothPreparingPreviewsWithoutResurrection() async throws {
        let model = ExperimentCoordinator(), owner = UUID()
        defer { model.preview.stop() }
        model.editing.endOffset = min(1,try XCTUnwrap(model.audio).duration)
        for fiveSeconds in [false,true] {
            model.audition(fiveSeconds:fiveSeconds,owner:owner)
            XCTAssertEqual(model.preview.state,.preparing)
            XCTAssertTrue(model.preview.isOwned(by:owner))
            model.preview.stop(owner:owner)
            try await Task.sleep(for:.milliseconds(50))
            XCTAssertEqual(model.preview.state,.idle); XCTAssertFalse(model.preview.isActive)
            XCTAssertNil(model.preview.preparedDuration)
        }
    }

    @MainActor func testPlaybackPageExitStopsBothPlayingPreviews() async throws {
        let model = ExperimentCoordinator(), owner = UUID()
        defer { model.preview.stop() }
        model.editing.volume = 0
        for fiveSeconds in [false,true] {
            model.audition(fiveSeconds:fiveSeconds,owner:owner)
            for _ in 0..<200 where model.preview.state == .preparing { try await Task.sleep(for:.milliseconds(10)) }
            XCTAssertEqual(model.preview.state,.playing,model.preview.errorMessage ?? "")
            model.preview.stop(owner:owner)
            XCTAssertEqual(model.preview.state,.idle); XCTAssertNil(model.preview.preparedDuration)
        }
    }

    @MainActor func testLatePlaybackPageExitKeepsNewLibraryPreviewAndFormalExperiment() throws {
        let model = ExperimentCoordinator(), playbackOwner = UUID(), libraryOwner = UUID()
        defer { model.stop(); model.preview.stop() }
        model.audition(owner:playbackOwner)
        model.audition(try XCTUnwrap(model.audio),owner:libraryOwner)
        model.preview.stop(owner:playbackOwner)
        XCTAssertTrue(model.preview.isOwned(by:libraryOwner)); XCTAssertEqual(model.preview.state,.preparing)
        model.preview.stop(owner:libraryOwner)
        model.prepare()
        let id = model.currentExperiment?.id
        model.preview.stop(owner:playbackOwner)
        XCTAssertEqual(model.state,.preparing); XCTAssertEqual(model.currentExperiment?.id,id)
        XCTAssertTrue(model.isRunning)
    }
}
