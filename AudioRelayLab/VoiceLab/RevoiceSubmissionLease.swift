import UIKit

/// Submission needs only a short grace period. Generation itself is an
/// independent cloud job, and result transfer uses the system background session.
@MainActor final class RevoiceSubmissionLease {
    private var identifier:UIBackgroundTaskIdentifier = .invalid
    init(onExpire:@escaping @MainActor ()->Void) {
        identifier = UIApplication.shared.beginBackgroundTask(withName:"Submit revoice job") { [weak self] in
            Task { @MainActor [weak self] in onExpire(); self?.end() }
        }
    }
    func end() {
        if identifier != .invalid { UIApplication.shared.endBackgroundTask(identifier); identifier = .invalid }
    }
}
