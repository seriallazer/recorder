import XCTest
import CoreML
@testable import RecorderCore

final class LocalTranscriptionServiceTests: XCTestCase {
    func testDesktopTranscriptionAvoidsNeuralEngineRuntime() {
        XCTAssertEqual(LocalTranscriptionService.preferredComputeUnits, .cpuAndGPU)
    }
}
