import AVFAudio
import Foundation
import XCTest
@testable import AudioRelayLab

/// 人工发送公开通知只验证本 App 的事件门禁；不模拟系统通话，也不激活音频。
/// 此测试通过不能证明真实设备上的 interruption / media reset 行为已验证。
final class SessionSafetyTests: XCTestCase {
    @MainActor
    private func postInterruption(_ type: AVAudioSession.InterruptionType, shouldResume: Bool = false) {
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), userInfo: [
                AVAudioSessionInterruptionTypeKey: NSNumber(value: type.rawValue),
                AVAudioSessionInterruptionOptionKey: NSNumber(value: shouldResume ? AVAudioSession.InterruptionOptions.shouldResume.rawValue : 0)
            ])
    }

    private func assertNoActivation(_ logger: DiagnosticsLogger,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(logger.entries().contains { $0.message.contains("setActive(true)") }, file: file, line: line)
    }

    @MainActor func testPostedInterruptionBeganBlocksPreflightWithoutActivation() async throws {
        let logger = DiagnosticsLogger()
        let manager = AudioSessionManager(logger: logger)
        defer {
            postInterruption(.ended)
            logger.flush()
        }
        var receivedBegan = false
        manager.onEvent = { event in
            if case .interruptionBegan = event { receivedBegan = true }
        }
        XCTAssertNoThrow(try manager.ensureCanActivate())
        postInterruption(.began)
        XCTAssertTrue(receivedBegan)
        XCTAssertThrowsError(try manager.ensureCanActivate())
        XCTAssertTrue(logger.entries().contains { $0.category == "音频中断" })
        assertNoActivation(logger)
    }

    @MainActor func testPostedInterruptionEndedReopensPreflightWithoutStartingAudio() async throws {
        let logger = DiagnosticsLogger()
        let manager = AudioSessionManager(logger: logger)
        defer {
            postInterruption(.ended)
            logger.flush()
        }
        var endedAllowsResume = false
        manager.onEvent = { event in
            if case .interruptionEnded(let shouldResume) = event { endedAllowsResume = shouldResume }
        }
        XCTAssertNoThrow(try manager.ensureCanActivate())
        postInterruption(.began)
        XCTAssertThrowsError(try manager.ensureCanActivate())
        postInterruption(.ended, shouldResume: true)
        XCTAssertTrue(endedAllowsResume)
        XCTAssertNoThrow(try manager.ensureCanActivate())
        assertNoActivation(logger)
    }

    @MainActor func testPostedMediaLostBlocksUntilPostedResetWithoutActivation() async throws {
        let logger = DiagnosticsLogger()
        let manager = AudioSessionManager(logger: logger)
        defer {
            NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereResetNotification,
                object: AVAudioSession.sharedInstance())
            logger.flush()
        }
        var receivedLost = false
        var receivedReset = false
        manager.onEvent = { event in
            if case .mediaLost = event { receivedLost = true }
            if case .mediaReset = event { receivedReset = true }
        }
        XCTAssertNoThrow(try manager.ensureCanActivate())
        NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereLostNotification,
            object: AVAudioSession.sharedInstance())
        XCTAssertTrue(receivedLost)
        XCTAssertThrowsError(try manager.ensureCanActivate())
        NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance())
        XCTAssertTrue(receivedReset)
        XCTAssertNoThrow(try manager.ensureCanActivate())
        XCTAssertTrue(logger.entries().contains { $0.message.contains("媒体服务已丢失") })
        XCTAssertTrue(logger.entries().contains { $0.message.contains("媒体服务已重置") })
        assertNoActivation(logger)
    }

    @MainActor func testExplicitManualAttemptCanClearStaleInterruptionWithoutActivation() async throws {
        let logger = DiagnosticsLogger()
        let manager = AudioSessionManager(logger: logger)
        defer {
            postInterruption(.ended)
            logger.flush()
        }
        XCTAssertNoThrow(try manager.ensureCanActivate())
        postInterruption(.began)
        XCTAssertThrowsError(try manager.ensureCanActivate())
        // 模拟 ended 未到达后用户明确重试，仅清除本 App 缓存；不证明系统允许实际激活。
        XCTAssertNoThrow(try manager.beginManualAttempt())
        XCTAssertNoThrow(try manager.ensureCanActivate())
        assertNoActivation(logger)
    }
}
