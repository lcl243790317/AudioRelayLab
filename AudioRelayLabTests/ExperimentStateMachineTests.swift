import Foundation
import XCTest
@testable import AudioRelayLab

final class ExperimentStateMachineTests: XCTestCase {
    private func playingMachine() throws -> (ExperimentStateMachine, UUID) {
        var machine = ExperimentStateMachine()
        let token = try machine.begin()
        XCTAssertTrue(machine.transition(to: .prepared, for: token))
        XCTAssertTrue(machine.transition(to: .waiting, for: token))
        XCTAssertTrue(machine.transition(to: .playing, for: token))
        return (machine, token)
    }

    func testNormalCompletion() throws {
        var machine = ExperimentStateMachine()
        XCTAssertEqual(machine.state, .idle)
        let token = try machine.begin()
        XCTAssertEqual(machine.state, .preparing)
        XCTAssertTrue(machine.transition(to: .prepared, for: token))
        XCTAssertTrue(machine.transition(to: .waiting, for: token))
        XCTAssertTrue(machine.transition(to: .playing, for: token))
        XCTAssertTrue(machine.transition(to: .completed, for: token))
        XCTAssertFalse(machine.isActive)
        XCTAssertFalse(machine.transition(to: .playing, for: token))
    }

    func testCancelDuringPrepareExpiresToken() throws {
        var machine = ExperimentStateMachine()
        let token = try machine.begin()
        machine.cancel()
        XCTAssertEqual(machine.state, .cancelled)
        XCTAssertNotEqual(machine.generation, token)
        XCTAssertFalse(machine.transition(to: .prepared, for: token))
        XCTAssertFalse(machine.claimRecovery(for: token))
    }

    func testCancelDuringScheduledPlayback() throws {
        var machine = ExperimentStateMachine()
        let token = try machine.begin()
        XCTAssertTrue(machine.transition(to: .prepared, for: token))
        XCTAssertTrue(machine.transition(to: .waiting, for: token))
        machine.cancel()
        XCTAssertFalse(machine.transition(to: .playing, for: token))
        XCTAssertFalse(machine.transition(to: .completed, for: token))
        XCTAssertEqual(machine.state, .cancelled)
    }

    func testInterruptionDuringPlayback() throws {
        let (initial, token) = try playingMachine()
        var machine = initial
        XCTAssertTrue(machine.transition(to: .interrupted, for: token))
        XCTAssertEqual(machine.state, .interrupted)
        XCTAssertFalse(machine.transition(to: .waiting, for: token))
        XCTAssertTrue(machine.claimRecovery(for: token))
        XCTAssertTrue(machine.transition(to: .waiting, for: token))
        XCTAssertTrue(machine.transition(to: .playing, for: token))
        XCTAssertTrue(machine.transition(to: .completed, for: token))
    }

    func testActivationFailureStopsPreparation() throws {
        var machine = ExperimentStateMachine()
        let token = try machine.begin()
        XCTAssertTrue(machine.transition(to: .failed, for: token))
        XCTAssertFalse(machine.transition(to: .prepared, for: token))
        XCTAssertFalse(machine.claimRecovery(for: token))
        XCTAssertEqual(machine.state, .failed)
    }

    func testRecoveryFailureEndsExperiment() throws {
        let (initial, token) = try playingMachine()
        var machine = initial
        XCTAssertTrue(machine.transition(to: .interrupted, for: token))
        XCTAssertTrue(machine.claimRecovery(for: token))
        XCTAssertTrue(machine.transition(to: .failed, for: token))
        XCTAssertFalse(machine.claimRecovery(for: token))
        XCTAssertFalse(machine.transition(to: .waiting, for: token))
        XCTAssertEqual(machine.recoveryAttempts, 1)
    }

    func testSecondInterruptionDoesNotGetAnotherRecovery() throws {
        let (initial, token) = try playingMachine()
        var machine = initial
        XCTAssertTrue(machine.transition(to: .interrupted, for: token))
        XCTAssertTrue(machine.claimRecovery(for: token))
        XCTAssertFalse(machine.claimRecovery(for: token))
        XCTAssertTrue(machine.transition(to: .waiting, for: token))
        XCTAssertTrue(machine.transition(to: .interrupted, for: token))
        XCTAssertFalse(machine.claimRecovery(for: token))
        XCTAssertFalse(machine.transition(to: .waiting, for: token))
    }

    func testDoubleStartDoesNotReplaceActiveToken() throws {
        var machine = ExperimentStateMachine()
        let token = try machine.begin()
        XCTAssertThrowsError(try machine.begin())
        XCTAssertEqual(machine.generation, token)
        XCTAssertEqual(machine.state, .preparing)
        XCTAssertTrue(machine.transition(to: .prepared, for: token))
        XCTAssertThrowsError(try machine.begin())
    }

    func testStaleCallbackCannotChangeNewExperiment() throws {
        var machine = ExperimentStateMachine()
        let stale = try machine.begin()
        machine.cancel()
        let current = try machine.begin()
        XCTAssertNotEqual(stale, current)
        XCTAssertFalse(machine.transition(to: .prepared, for: stale))
        XCTAssertFalse(machine.transition(to: .failed, for: stale))
        XCTAssertEqual(machine.state, .preparing)
        XCTAssertTrue(machine.transition(to: .prepared, for: current))
    }

    func testIllegalJumpIsRejected() throws {
        var machine = ExperimentStateMachine()
        let token = try machine.begin()
        XCTAssertFalse(machine.transition(to: .playing, for: token))
        XCTAssertFalse(machine.transition(to: .completed, for: token))
        XCTAssertEqual(machine.state, .preparing)
    }

    func testCompletionWithoutForegroundObservation() throws {
        var machine = ExperimentStateMachine()
        let token = try machine.begin()
        XCTAssertTrue(machine.transition(to: .prepared, for: token))
        XCTAssertTrue(machine.transition(to: .waiting, for: token))
        XCTAssertTrue(machine.transition(to: .completed, for: token))
    }

    func testStopIsTerminalButNextExperimentMayBegin() throws {
        let (initial, token) = try playingMachine()
        var machine = initial
        XCTAssertTrue(machine.transition(to: .stopped, for: token))
        XCTAssertFalse(machine.transition(to: .playing, for: token))
        let next = try machine.begin()
        XCTAssertNotEqual(token, next)
        XCTAssertEqual(machine.recoveryAttempts, 0)
        XCTAssertEqual(machine.state, .preparing)
    }

    func testRecoveryCannotBeClaimedWithoutInterruption() throws {
        var machine = ExperimentStateMachine()
        let token = try machine.begin()
        XCTAssertFalse(machine.claimRecovery(for: token))
        XCTAssertTrue(machine.transition(to: .prepared, for: token))
        XCTAssertFalse(machine.claimRecovery(for: token))
        XCTAssertEqual(machine.recoveryAttempts, 0)
    }
}
