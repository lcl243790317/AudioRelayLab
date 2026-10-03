import CallKit
import Foundation

/// 只读取系统公开的通话状态，不创建通话、不读取号码，也不识别具体 App。
@MainActor final class AudioEnvironmentGuard: NSObject, CXCallObserverDelegate {
    private let observer = CXCallObserver()
    var onChange: (() -> Void)?
    override init() {
        super.init()
        observer.setDelegate(self, queue: .main)
    }
    var hasActiveCall: Bool { observer.calls.contains { !$0.hasEnded } }
    func ensureNoKnownCall() throws {
        if hasActiveCall { throw LabError.audioUnavailable }
    }
    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        Task { @MainActor [weak self] in self?.onChange?() }
    }
}
