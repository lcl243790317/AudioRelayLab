import Foundation

enum ExperimentStateMachineError: LocalizedError {
    case experimentAlreadyActive

    var errorDescription: String? {
        "当前实验尚未结束，请取消或等待结束后再开始。"
    }
}

/// Only the coordinator owns and mutates this value, on the main actor.
/// Audio callbacks carry the token returned by begin; a cancelled run can never revive.
struct ExperimentStateMachine {
    private(set) var state: PlaybackState = .idle
    private(set) var generation = UUID()
    private(set) var recoveryAttempts = 0
    private var recoveryAuthorized = false

    init() {}

    var isActive: Bool {
        switch state {
        case .preparing, .prepared, .waiting, .playing, .interrupted: return true
        case .idle, .completed, .stopped, .failed, .cancelled: return false
        }
    }

    mutating func begin() throws -> UUID {
        guard !isActive else { throw ExperimentStateMachineError.experimentAlreadyActive }
        generation = UUID()
        recoveryAttempts = 0
        recoveryAuthorized = false
        state = .preparing
        return generation
    }

    @discardableResult
    mutating func transition(to next: PlaybackState, for token: UUID) -> Bool {
        guard token == generation, next != state, isActive else { return false }
        if next == .failed || next == .cancelled || next == .stopped {
            state = next
            return true
        }
        let allowed: Bool
        switch (state, next) {
        case (.preparing, .prepared),
             (.prepared, .waiting),
             (.waiting, .playing),
             (.playing, .completed),
             // A short file can finish in the background before the UI observes its timeline.
             (.waiting, .completed),
             (.preparing, .interrupted),
             (.prepared, .interrupted),
             (.waiting, .interrupted),
             (.playing, .interrupted):
            allowed = true
        case (.interrupted, .prepared), (.interrupted, .waiting), (.interrupted, .playing):
            allowed = recoveryAuthorized
        default:
            allowed = false
        }
        guard allowed else { return false }
        if state == .interrupted || next == .interrupted { recoveryAuthorized = false }
        state = next
        return true
    }

    mutating func cancel() {
        state = .cancelled
        generation = UUID()
        recoveryAuthorized = false
    }

    /// One recovery budget per experiment, never a loop after an activation refusal.
    mutating func claimRecovery(for token: UUID) -> Bool {
        guard token == generation, state == .interrupted, recoveryAttempts == 0 else { return false }
        recoveryAttempts = 1
        recoveryAuthorized = true
        return true
    }
}
