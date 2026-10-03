import XCTest
@testable import AudioRelayLab

final class ParameterTests: XCTestCase {
    private func validate(delay: Double = 5, volume: Double = 0.5,
                          duration: Double? = nil, audioDuration: Double = 20) throws {
        try ExperimentParameters.validate(delay: delay, volume: volume,
                                          requestedDuration: duration, audioDuration: audioDuration)
    }

    func testVolumeZero() {
        XCTAssertNoThrow(try validate(volume: 0))
    }

    func testVolumeOne() {
        XCTAssertNoThrow(try validate(volume: 1))
    }

    func testLowVolumeObservedOnDeviceRemainsAllowed() {
        XCTAssertNoThrow(try validate(volume: 0.04))
    }

    func testInvalidVolume() {
        for volume in [-0.001, 1.001, Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertThrowsError(try validate(volume: volume))
        }
    }

    func testDelayLowerAndUpperBoundaries() {
        XCTAssertNoThrow(try validate(delay: 0.1))
        XCTAssertNoThrow(try validate(delay: 60))
    }

    func testInvalidDelay() {
        for delay in [-1, 0, 0.099, 60.001, Double.nan, Double.infinity, Double.greatestFiniteMagnitude] {
            XCTAssertThrowsError(try validate(delay: delay))
        }
    }

    func testDurationLowerBoundary() {
        XCTAssertNoThrow(try validate(duration: 0.1))
    }

    func testDurationCannotExceedFile() {
        XCTAssertNoThrow(try validate(duration: 20))
        XCTAssertThrowsError(try validate(duration: 20.001))
    }

    func testExplicitDurationMaximum() {
        XCTAssertNoThrow(try validate(duration: 600, audioDuration: 900))
        XCTAssertThrowsError(try validate(duration: 600.001, audioDuration: 900))
    }

    func testInvalidDuration() {
        for duration in [-1, 0, 0.099, Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertThrowsError(try validate(duration: duration))
        }
    }

    func testFullFileDurationIsAllowed() {
        XCTAssertNoThrow(try validate(duration: nil, audioDuration: 900))
        XCTAssertNoThrow(try validate(duration: nil, audioDuration: 0.05))
    }

    func testInvalidAudioDuration() {
        for duration in [-1, 0, Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertThrowsError(try validate(audioDuration: duration))
        }
    }
}
