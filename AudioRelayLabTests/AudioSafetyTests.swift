import AVFAudio
import Foundation
import XCTest
@testable import AudioRelayLab

/// These tests exercise real local audio files and public validation APIs.
/// They do not establish whether another app or a phone call permits playback.
final class AudioSafetyTests: XCTestCase {
    private func audioFixture() throws -> URL {
        let metadata = try AudioFileManager.generateTestAudio()
        let source = try AudioFileManager.url(for: metadata)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioSafetyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("fixture.wav")
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    private func metadata(sandboxName: String) -> AudioFileMetadata {
        AudioFileMetadata(id: UUID(), fileName: "匿名测试音频", sandboxFileName: sandboxName,
                          duration: 1, sampleRate: 44_100, channelCount: 1, byteCount: 1)
    }

    func testValidSampleRatesAndChannelCounts() {
        XCTAssertNoThrow(try AudioRuntimeValidation.validate(sampleRate: 44_100, channels: 1))
        XCTAssertNoThrow(try AudioRuntimeValidation.validate(sampleRate: 48_000, channels: 2))
        XCTAssertNoThrow(try AudioRuntimeValidation.validate(sampleRate: 8_000, channels: 1))
        XCTAssertNoThrow(try AudioRuntimeValidation.validate(sampleRate: 384_000, channels: 8))
    }

    func testInvalidSampleRateIsRejectedBeforeAnyGraphOperation() {
        for rate in [0, -1, 7_999, 384_001, Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertThrowsError(try AudioRuntimeValidation.validate(sampleRate: rate, channels: 1))
        }
    }

    func testZeroAndUnsupportedChannelCountsAreRejected() {
        XCTAssertThrowsError(try AudioRuntimeValidation.validate(sampleRate: 44_100, channels: 0))
        XCTAssertThrowsError(try AudioRuntimeValidation.validate(sampleRate: 48_000, channels: 9))
    }

    func testActualPCMFormatValidation() throws {
        for rate in [44_100.0, 48_000.0] {
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                   sampleRate: rate, channels: 1, interleaved: false))
            XCTAssertNoThrow(try AudioRuntimeValidation.validate(format))
        }
    }

    func testGeneratedWAVCanBeReadAndHasExpectedDuration() throws {
        let url = try audioFixture()
        let inspected = try AudioFileManager.inspect(url: url)
        let audio = try AVAudioFile(forReading: url)
        XCTAssertEqual(inspected.duration, 11.7, accuracy: 1 / 44_100.0)
        XCTAssertEqual(inspected.sampleRate, 44_100)
        XCTAssertEqual(inspected.channelCount, 1)
        XCTAssertGreaterThan(inspected.byteCount, 0)
        XCTAssertNoThrow(try AudioRuntimeValidation.validate(audio.processingFormat))
    }

    func testActualCAFTrimIsOneSecondAndPreservesOriginalBytes() throws {
        let original = try audioFixture()
        let originalBytes = try Data(contentsOf: original)
        let segment = try AudioProcessor.trimmedCopy(of: original, duration: 1)
        defer { try? FileManager.default.removeItem(at: segment) }
        XCTAssertNotEqual(original, segment)
        XCTAssertEqual(segment.pathExtension, "caf")
        let inspected = try AudioFileManager.inspect(url: segment)
        XCTAssertEqual(inspected.duration, 1, accuracy: 1 / 44_100.0)
        XCTAssertEqual(inspected.sampleRate, 44_100)
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
        XCTAssertEqual(try AudioFileManager.inspect(url: original).duration, 11.7, accuracy: 1 / 44_100.0)
    }

    func testTrimMinimumBoundaryProducesReadableAudio() throws {
        let original = try audioFixture()
        let segment = try AudioProcessor.trimmedCopy(of: original, duration: 0.1)
        defer { try? FileManager.default.removeItem(at: segment) }
        XCTAssertEqual(try AudioFileManager.inspect(url: segment).duration, 0.1, accuracy: 1 / 44_100.0)
    }

    func testInvalidTrimDurationDoesNotModifySource() throws {
        let original = try audioFixture()
        let before = try Data(contentsOf: original)
        for duration in [0, -1, 0.099, Double.nan, Double.infinity, 601] {
            XCTAssertThrowsError(try AudioProcessor.trimmedCopy(of: original, duration: duration))
        }
        XCTAssertEqual(try Data(contentsOf: original), before)
    }

    func testSandboxPathTraversalAndEmptyNamesAreRejected() {
        for name in ["", ".", "..", "../private.wav", "folder/file.wav", "folder\\file.wav", "/private.wav", "\\private.wav"] {
            XCTAssertThrowsError(try AudioFileManager.url(for: metadata(sandboxName: name)))
        }
    }

    func testSafeSandboxNameStaysInsideAudioDirectory() throws {
        let directory = try AudioFileManager.audioDirectory().standardizedFileURL
        let url = try AudioFileManager.url(for: metadata(sandboxName: "anonymous.caf")).standardizedFileURL
        XCTAssertEqual(url.deletingLastPathComponent(), directory)
        XCTAssertEqual(url.lastPathComponent, "anonymous.caf")
    }

    func testNamedSessionPriorityErrorsHaveFriendlyFailureMessage() {
        let blocked: [AVAudioSession.ErrorCode] = [.cannotInterruptOthers, .insufficientPriority,
                                                .cannotStartPlaying, .cannotStartRecording, .resourceNotAvailable]
        for code in blocked {
            let error = NSError(domain: NSOSStatusErrorDomain, code: code.rawValue)
            XCTAssertEqual(userFacingAudioError(error), LabError.audioUnavailable.errorDescription ?? "")
            let details = diagnosticError(error)
            XCTAssertTrue(details.contains("错误域=\(NSOSStatusErrorDomain)"))
            XCTAssertTrue(details.contains("错误码=\(code.rawValue)"))
        }
    }

    func testNamedOSStatusErrorIncludesPrintableFourCC() {
        let error = NSError(domain: NSOSStatusErrorDomain, code: AVAudioSession.ErrorCode.cannotInterruptOthers.rawValue)
        XCTAssertTrue(diagnosticError(error).contains("fourCC="))
    }

    func testArbitraryNSErrorDetailsDoNotLeakPersonalURL() {
        let privateURL = URL(fileURLWithPath: "/private/anonymous-owner/secret-source.wav")
        let error = NSError(domain: "AudioSafetyTests", code: 7, userInfo: [
            NSURLErrorFailingURLErrorKey: privateURL,
            NSLocalizedDescriptionKey: "无法打开私人文件 \(privateURL.absoluteString)"
        ])
        let details = diagnosticError(error)
        XCTAssertTrue(details.contains("错误域=AudioSafetyTests"))
        XCTAssertTrue(details.contains("错误码=7"))
        XCTAssertFalse(details.contains(privateURL.path))
        XCTAssertFalse(details.contains(privateURL.absoluteString))
    }

    func testOSStatusNSErrorDescriptionDoesNotLeakPersonalURL() {
        let privateURL = URL(fileURLWithPath: "/private/anonymous-owner/secret-source.wav")
        let error = NSError(domain: NSOSStatusErrorDomain, code: AVAudioSession.ErrorCode.cannotStartPlaying.rawValue,
                            userInfo: [NSLocalizedDescriptionKey: "无法播放 \(privateURL.absoluteString)"])
        let details = diagnosticError(error)
        XCTAssertTrue(details.contains("错误域=\(NSOSStatusErrorDomain)"))
        XCTAssertTrue(details.contains("错误码=\(error.code)"))
        XCTAssertFalse(details.contains(privateURL.path))
        XCTAssertFalse(details.contains(privateURL.absoluteString))
    }

    func testInvalidFormatHasFriendlyRetryMessage() {
        XCTAssertEqual(userFacingAudioError(LabError.invalidFormat), LabError.invalidFormat.errorDescription ?? "")
    }
}
