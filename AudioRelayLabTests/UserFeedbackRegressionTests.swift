import UniformTypeIdentifiers
import XCTest
@testable import AudioRelayLab

final class UserFeedbackRegressionTests: XCTestCase {
    @MainActor func testHistoryClearPersistsAndCheckpointDoesNotRestoreDeletedDraft() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("history-clear-\(UUID())")
        defer { try? FileManager.default.removeItem(at:folder) }
        let coordinator = ExperimentCoordinator(historyDirectoryURL:folder)
        coordinator.prepare(); coordinator.stop()
        XCTAssertFalse(coordinator.store.experiments.isEmpty)
        try coordinator.clearHistory()
        XCTAssertNil(coordinator.currentExperiment)
        coordinator.checkpoint(); coordinator.sceneChanged(.active)
        XCTAssertTrue(coordinator.store.experiments.isEmpty)
        XCTAssertTrue(ExperimentStore(logger:DiagnosticsLogger(),directoryURL:folder).experiments.isEmpty)
        XCTAssertNotNil(coordinator.audio)
    }
    @MainActor func testActiveExperimentRejectsClearAndKeepsStoredDraft() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("history-active-\(UUID())")
        defer { try? FileManager.default.removeItem(at:folder) }
        let coordinator = ExperimentCoordinator(historyDirectoryURL:folder)
        coordinator.prepare()
        defer { coordinator.stop() }
        XCTAssertThrowsError(try coordinator.clearHistory())
        XCTAssertNotNil(coordinator.currentExperiment); XCTAssertFalse(coordinator.store.experiments.isEmpty)
    }
    func testNewestDisplayOrderingPreservesChronologicalExperimentAudit() {
        let logger = DiagnosticsLogger()
        logger.log("first","1"); logger.log("second","2"); logger.log("third","3")
        XCTAssertEqual(logger.newestVisibleEntries.map(\.category),["third","second","first"])
        XCTAssertEqual(logger.entries().map(\.category),["first","second","third"])
        logger.clearDisplay(); logger.log("latest","4")
        XCTAssertEqual(logger.newestVisibleEntries.first?.category,"latest")
        XCTAssertEqual(logger.entries().first?.category,"first")
    }
    @MainActor func testPickerAllowsSupportedAudioButExcludesDocumentsAndImages() throws {
        XCTAssertEqual(AudioDocumentPicker.supportedTypes.count,8)
        for ext in AudioDocumentPicker.supportedExtensions {
            let type = try XCTUnwrap(UTType(filenameExtension:ext))
            XCTAssertTrue(AudioDocumentPicker.supportedTypes.contains { type.conforms(to:$0) })
        }
        for type in [UTType.json,.pdf,.jpeg,.plainText,.zip] {
            XCTAssertFalse(AudioDocumentPicker.supportedTypes.contains { type.conforms(to:$0) })
        }
        XCTAssertFalse(AudioDocumentPicker.supportedTypes.contains(.item))
    }
}
