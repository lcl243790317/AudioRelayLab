import AVFoundation
import XCTest
@testable import AudioRelayLab

final class LibraryVoiceFeedbackTests: XCTestCase {
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
}
