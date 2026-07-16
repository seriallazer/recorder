import XCTest
@testable import RecorderCore

@MainActor
final class RecordingCoordinatorTests: XCTestCase {
    func testConcurrentStopRequestsOnlyStopCaptureOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(root.path, forKey: "RecorderLibraryPath")
        let library = RecordingLibrary(defaults: defaults)
        let capture = DelayedCapture()
        let coordinator = RecordingCoordinator(
            library: library,
            finalizer: PassthroughFinalizer(),
            captureFactory: { _ in capture }
        )

        await coordinator.start(configuration: CaptureConfiguration(mode: .camera))
        async let first: Void = coordinator.stop()
        async let second: Void = coordinator.stop()
        _ = await (first, second)

        let stopCallCount = await capture.stopCallCount
        XCTAssertEqual(stopCallCount, 1)
        try? FileManager.default.removeItem(at: root)
    }
}

private actor DelayedCapture: RecordingCapturing {
    private(set) var stopCallCount = 0
    private let sourceURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("recorder-test-\(UUID().uuidString).mov")

    func start(configuration: CaptureConfiguration, workingDirectory: URL) async throws -> CaptureArtifacts {
        CaptureArtifacts(primaryMediaURL: sourceURL)
    }

    func stop() async throws -> CaptureArtifacts {
        stopCallCount += 1
        try await Task.sleep(nanoseconds: 100_000_000)
        return CaptureArtifacts(primaryMediaURL: sourceURL)
    }
}

private struct PassthroughFinalizer: MediaFinalizing {
    func finalize(
        artifacts: CaptureArtifacts,
        configuration: CaptureConfiguration,
        destinationDirectory: URL
    ) async throws -> FinalizedMedia {
        FinalizedMedia(
            mediaURL: artifacts.primaryMediaURL,
            audioURL: artifacts.primaryMediaURL,
            microphoneStemURL: nil,
            systemStemURL: nil,
            duration: 1
        )
    }

    func exportTrimmed(
        sourceURL: URL,
        destinationURL: URL,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) async throws {}
}
