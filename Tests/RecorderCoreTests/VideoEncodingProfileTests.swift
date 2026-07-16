import XCTest
@testable import RecorderCore

final class VideoEncodingProfileTests: XCTestCase {
    func testStorageConsciousThirtyFPSBitrateTiers() {
        XCTAssertEqual(
            VideoEncodingProfile.averageBitRate(width: 1280, height: 720, framesPerSecond: 30),
            2_500_000
        )
        XCTAssertEqual(
            VideoEncodingProfile.averageBitRate(width: 1920, height: 1080, framesPerSecond: 30),
            4_000_000
        )
        XCTAssertEqual(
            VideoEncodingProfile.averageBitRate(width: 2560, height: 1440, framesPerSecond: 30),
            7_000_000
        )
    }

    func testSixtyFPSRetainsAdditionalBitrate() {
        XCTAssertEqual(
            VideoEncodingProfile.averageBitRate(width: 1920, height: 1080, framesPerSecond: 60),
            7_000_000
        )
    }

    func testTwentyFourFPSUsesSlightlyLessSpace() {
        XCTAssertEqual(
            VideoEncodingProfile.averageBitRate(width: 1920, height: 1080, framesPerSecond: 24),
            3_600_000
        )
    }
}
