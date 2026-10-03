import AVFAudio
import XCTest
@testable import AudioRelayLab

final class AudioImportEditorTests: XCTestCase {
    private func fixture(_ ext: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture", withExtension: ext))
    }
    private func checkCodec(_ ext: String) throws {
        let input = try fixture(ext)
        let asset = try AudioFileManager.importFile(from: input)
        defer { try? AudioFileManager.removeAudio(asset) }
        let local = try AudioFileManager.url(for: asset)
        XCTAssertNotEqual(input, local)
        XCTAssertEqual(try Data(contentsOf: input), try Data(contentsOf: local))
        XCTAssertEqual(asset.source, .imported)
        XCTAssertGreaterThan(asset.duration, 1)
        XCTAssertGreaterThan(asset.byteCount, 0)
        XCTAssertEqual(asset.sampleRate, 44_100)
        XCTAssertEqual(asset.channelCount, 1)
        let player = try AVAudioPlayer(contentsOf: local)
        player.enableRate = true; player.rate = 1.25; player.currentTime = 0.3
        XCTAssertEqual(player.rate, 1.25)
        XCTAssertEqual(player.currentTime, 0.3, accuracy: 0.04)
        let source = try AVAudioFile(forReading: local)
        let first = try AudioPlaybackSettings.frame(0.3, sampleRate: source.processingFormat.sampleRate, length: source.length)
        source.framePosition = first
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 256))
        try source.read(into: buffer)
        XCTAssertGreaterThan(buffer.frameLength, 0)
    }
    func testWAVImportDecodeAndSeek() throws { try checkCodec("wav") }
    func testMP3ImportDecodeAndSeek() throws { try checkCodec("mp3") }
    func testM4AImportDecodeAndSeek() throws { try checkCodec("m4a") }
    func testAACImportDecodeAndSeek() throws { try checkCodec("aac") }
    func testAIFFImportDecodeAndSeek() throws { try checkCodec("aiff") }
    func testAIFCImportDecodeAndSeek() throws { try checkCodec("aifc") }
    func testCAFImportDecodeAndSeek() throws { try checkCodec("caf") }
    func testFLACImportDecodeAndSeek() throws { try checkCodec("flac") }
    func testBundleSelectionUsesRealPackagedResource() throws {
        XCTAssertNotNil(Bundle.main.url(forResource: "BundledTest", withExtension: "wav"))
        let asset = try AudioFileManager.loadBundledAudio()
        defer { try? AudioFileManager.removeAudio(asset) }
        XCTAssertEqual(asset.source, .bundled)
        XCTAssertEqual(asset.duration, 11.7, accuracy: 1 / 44_100.0)
    }
    func testMissingFileRejected() {
        XCTAssertThrowsError(try AudioFileManager.importFile(from: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    }
    func testUnsupportedInputDoesNotLeaveLibraryAudio() throws {
        let folder = try AudioFileManager.audioDirectory()
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        let bad = FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: bad) }
        try Data("not audio".utf8).write(to: bad)
        XCTAssertThrowsError(try AudioFileManager.importFile(from: bad))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)), before)
    }
    func testDuplicateNameUsesIndependentCopies() throws {
        let first = try AudioFileManager.importFile(from: fixture("wav"))
        let second = try AudioFileManager.importFile(from: fixture("wav"))
        defer { try? AudioFileManager.removeAudio(first); try? AudioFileManager.removeAudio(second) }
        XCTAssertEqual(first.fileName, second.fileName)
        XCTAssertNotEqual(first.sandboxFileName, second.sandboxFileName)
        XCTAssertNotEqual(first.id, second.id)
    }
    func testOffsetsClampAndRejectEnd() throws {
        XCTAssertEqual(AudioPlaybackSettings.clamp(-1, duration: 10), 0)
        XCTAssertEqual(AudioPlaybackSettings.clamp(11, duration: 10), 10)
        XCTAssertEqual(AudioPlaybackSettings.clamp(.nan, duration: 10), 0)
        XCTAssertNoThrow(try AudioPlaybackSettings(startOffset: 9.9).validated(duration: 10))
        XCTAssertThrowsError(try AudioPlaybackSettings(startOffset: 10).validated(duration: 10))
        XCTAssertThrowsError(try AudioPlaybackSettings(startOffset: .infinity).validated(duration: 10))
    }
    func testRateBoundsAndEstimatedDuration() throws {
        for rate in [Float(0.5), 1, 2] {
            let settings = AudioPlaybackSettings(startOffset: 4, playbackRate: rate)
            XCTAssertNoThrow(try settings.validated(duration: 10))
            XCTAssertEqual(settings.estimatedDuration(duration: 10), 6 / Double(rate))
        }
        XCTAssertThrowsError(try AudioPlaybackSettings(playbackRate: 0).validated(duration: 10))
        XCTAssertThrowsError(try AudioPlaybackSettings(playbackRate: .nan).validated(duration: 10))
    }
    func testSegmentCropBeginsAtOffset() throws {
        let original = try fixture("wav")
        let copy = try AudioProcessor.trimmedCopy(of: original, duration: 0.2, startOffset: 0.4)
        defer { try? FileManager.default.removeItem(at: copy) }
        XCTAssertEqual(try AudioFileManager.inspect(url: copy).duration, 0.2, accuracy: 1 / 44_100.0)
        let file = try AVAudioFile(forReading: original)
        let segment = try AVAudioFile(forReading: copy)
        file.framePosition = 17640
        let a = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 256))
        let b = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: segment.processingFormat, frameCapacity: 256))
        try file.read(into: a); try segment.read(into: b)
        let ac = try XCTUnwrap(a.floatChannelData?[0]); let bc = try XCTUnwrap(b.floatChannelData?[0])
        XCTAssertEqual(ac[100], bc[100], accuracy: 0.00001)
    }
    @MainActor func testCancelImportThenBundleSelectionCannotBeOverwritten() async throws {
        let coordinator = ExperimentCoordinator()
        defer { coordinator.stop(); coordinator.preview.stop() }
        coordinator.importAudio(try fixture("mp3"))
        XCTAssertTrue(coordinator.isImporting)
        coordinator.stop()
        XCTAssertFalse(coordinator.isImporting)
        coordinator.useTestAudio()
        let chosen = try XCTUnwrap(coordinator.audio)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(coordinator.audio?.id, chosen.id)
        XCTAssertEqual(coordinator.audio?.source, .bundled)
        XCTAssertFalse(coordinator.isImporting)
    }
    @MainActor func testSelectionResetsEditorAndPreviewAndAppliedParameters() throws {
        let coordinator = ExperimentCoordinator()
        defer { coordinator.stop(); coordinator.preview.stop() }
        coordinator.editing = AudioPlaybackSettings(startOffset: 1, playbackRate: 2, volume: 0.04)
        coordinator.applyPlaybackSettings()
        XCTAssertEqual(coordinator.applied.startOffset, 1)
        coordinator.editing.startOffset = 2
        XCTAssertEqual(coordinator.applied.startOffset, 1)
        coordinator.useTestAudio()
        XCTAssertEqual(coordinator.applied, AudioPlaybackSettings())
        XCTAssertEqual(coordinator.editing, AudioPlaybackSettings())
        XCTAssertEqual(coordinator.preview.currentTime, 0)
        XCTAssertNil(coordinator.requestedDuration)
    }
    func testOldSettingsDefaultOffsetAndRate() throws {
        let decoded = try JSONDecoder().decode(ExperimentSettings.self, from: Data("{\"engine\":\"AVAudioPlayer\",\"profile\":\"B\"}".utf8))
        XCTAssertEqual(decoded.startOffset, 0); XCTAssertEqual(decoded.playbackRate, 1); XCTAssertEqual(decoded.profile, .playback)
    }
}
