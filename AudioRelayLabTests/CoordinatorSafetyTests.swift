import Foundation
import XCTest
@testable import AudioRelayLab

/// Uses the real coordinator and its generated WAV. Every accepted preparation is
/// cancelled in the same main-actor turn, before the queued task can activate audio.
final class CoordinatorSafetyTests: XCTestCase {
    @MainActor
    private func withCoordinator(_ body: @MainActor (ExperimentCoordinator) async throws -> Void) async throws {
        let selectedAudio = UserDefaults.standard.data(forKey: "selectedAudio")
        let coordinator = ExperimentCoordinator()
        let existingIDs = Set(coordinator.store.experiments.map(\.id))
        defer {
            coordinator.stop()
            coordinator.logger.flush()
            // Remove only UUID files created by this test, leaving the host's existing history intact.
            if let directory = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                            in: .userDomainMask, appropriateFor: nil, create: false) {
                for experiment in coordinator.store.experiments where !existingIDs.contains(experiment.id) {
                    let file = directory.appendingPathComponent("Experiments", isDirectory: true)
                        .appendingPathComponent("\(experiment.id.uuidString).json")
                    try? FileManager.default.removeItem(at: file)
                }
            }
            if let selectedAudio { UserDefaults.standard.set(selectedAudio, forKey: "selectedAudio") }
            else { UserDefaults.standard.removeObject(forKey: "selectedAudio") }
        }
        coordinator.useTestAudio()
        XCTAssertNotNil(coordinator.audio)
        XCTAssertEqual(coordinator.audio?.duration ?? 0, 11.7, accuracy: 1 / 44_100.0)
        try await body(coordinator)
    }

    @MainActor
    private func assertNoAudioActivation(_ coordinator: ExperimentCoordinator,
                                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(coordinator.logger.entries().contains { $0.message.contains("setActive(true)") }, file: file, line: line)
        XCTAssertNil(coordinator.currentExperiment?.schedule, file: file, line: line)
    }

    @MainActor func testNonfiniteVolumePrepareFailsAndUnlocksControls() async throws {
        try await withCoordinator { coordinator in
            for volume in [Double.nan, Double.infinity, -Double.infinity] {
                coordinator.volume = volume
                coordinator.prepare()
                XCTAssertEqual(coordinator.state, .failed)
                XCTAssertFalse(coordinator.controlsLocked)
                XCTAssertFalse(coordinator.isRunning)
                XCTAssertNotNil(coordinator.errorMessage)
                self.assertNoAudioActivation(coordinator)
            }
        }
    }

    @MainActor func testOutOfRangeVolumePrepareFailsAndUnlocksControls() async throws {
        try await withCoordinator { coordinator in
            for volume in [-0.001, 1.001] {
                coordinator.volume = volume
                coordinator.prepare()
                XCTAssertEqual(coordinator.state, .failed)
                XCTAssertFalse(coordinator.controlsLocked)
                XCTAssertNotNil(coordinator.errorMessage)
                self.assertNoAudioActivation(coordinator)
            }
        }
    }

    @MainActor func testLegacyBPrepareIsRejectedBeforeActivation() async throws {
        try await withCoordinator { coordinator in
            coordinator.profile = .playback
            coordinator.prepare()
            XCTAssertEqual(coordinator.state, .failed)
            XCTAssertFalse(coordinator.controlsLocked)
            XCTAssertNil(coordinator.currentExperiment)
            XCTAssertNotNil(coordinator.errorMessage)
            self.assertNoAudioActivation(coordinator)
            await Task.yield()
            XCTAssertEqual(coordinator.state, .failed)
        }
    }

    @MainActor func testUnknownEnginePrepareIsRejectedBeforeActivation() async throws {
        try await withCoordinator { coordinator in
            coordinator.engineKind = .unknown
            coordinator.prepare()
            XCTAssertEqual(coordinator.state, .failed)
            XCTAssertFalse(coordinator.controlsLocked)
            XCTAssertNil(coordinator.currentExperiment)
            self.assertNoAudioActivation(coordinator)
            await Task.yield()
            XCTAssertEqual(coordinator.state, .failed)
        }
    }

    @MainActor func testDoublePrepareKeepsExperimentIDUntilImmediateCancellation() async throws {
        try await withCoordinator { coordinator in
            coordinator.prepare()
            let id = try XCTUnwrap(coordinator.currentExperiment?.id)
            XCTAssertEqual(coordinator.state, .preparing)
            XCTAssertTrue(coordinator.controlsLocked)
            coordinator.prepare()
            XCTAssertEqual(coordinator.currentExperiment?.id, id)
            XCTAssertEqual(coordinator.state, .preparing)
            coordinator.stop()
            XCTAssertEqual(coordinator.state, .cancelled)
            XCTAssertFalse(coordinator.controlsLocked)
            self.assertNoAudioActivation(coordinator)
            await Task.yield()
            XCTAssertEqual(coordinator.currentExperiment?.id, id)
            XCTAssertEqual(coordinator.state, .cancelled)
            self.assertNoAudioActivation(coordinator)
        }
    }

    @MainActor func testQueuedPreparationCannotReviveStateAfterStop() async throws {
        try await withCoordinator { coordinator in
            coordinator.profile = .mixingSpeaker
            coordinator.prepare()
            coordinator.stop()
            let id = try XCTUnwrap(coordinator.currentExperiment?.id)
            XCTAssertEqual(coordinator.currentExperiment?.finalState, .cancelled)
            XCTAssertNotNil(coordinator.currentExperiment?.finishedAt)
            for _ in 0..<4 { await Task.yield() }
            XCTAssertEqual(coordinator.state, .cancelled)
            XCTAssertEqual(coordinator.currentExperiment?.id, id)
            XCTAssertEqual(coordinator.currentExperiment?.finalState, .cancelled)
            XCTAssertFalse(coordinator.isRunning)
            self.assertNoAudioActivation(coordinator)
        }
    }

    @MainActor func testCancelledPreparationCannotMutateNewExperiment() async throws {
        try await withCoordinator { coordinator in
            coordinator.prepare()
            let staleID = try XCTUnwrap(coordinator.currentExperiment?.id)
            coordinator.stop()
            coordinator.prepare()
            let currentID = try XCTUnwrap(coordinator.currentExperiment?.id)
            XCTAssertNotEqual(currentID, staleID)
            XCTAssertEqual(coordinator.state, .preparing)
            coordinator.stop()
            for _ in 0..<4 { await Task.yield() }
            XCTAssertEqual(coordinator.state, .cancelled)
            XCTAssertEqual(coordinator.currentExperiment?.id, currentID)
            XCTAssertEqual(coordinator.currentExperiment?.finalState, .cancelled)
            XCTAssertFalse(coordinator.controlsLocked)
            self.assertNoAudioActivation(coordinator)
        }
    }
}
