import XCTest
@testable import RecorderCore

@MainActor
final class RecordingCoordinatorTests: XCTestCase {
    func testStartingRecordingIsVisibleAndCanBeStoppedFromAnotherControl() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(root.path, forKey: "RecorderLibraryPath")
        let library = RecordingLibrary(defaults: defaults)
        let capture = GatedStartingCapture()
        let coordinator = RecordingCoordinator(
            library: library,
            finalizer: PassthroughFinalizer(),
            captureFactory: { _ in capture }
        )

        let startTask = Task {
            await coordinator.start(configuration: CaptureConfiguration(mode: .screen))
        }
        for _ in 0..<20 where coordinator.activeRecording == nil {
            await Task.yield()
        }
        XCTAssertEqual(coordinator.activeRecording?.state, .previewing)

        await coordinator.stop()
        XCTAssertEqual(coordinator.activeRecording?.state, .finalizing)
        await capture.allowStart()
        await startTask.value

        XCTAssertNil(coordinator.activeRecording)
        let stopCallCount = await capture.stopCallCount
        XCTAssertEqual(stopCallCount, 1)
    }

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

    func testSuccessfulFinalizationRemovesWorkingDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(root.path, forKey: "RecorderLibraryPath")
        let library = RecordingLibrary(defaults: defaults)
        let capture = WorkingFileCapture()
        let coordinator = RecordingCoordinator(
            library: library,
            finalizer: CopyingFinalizer(),
            captureFactory: { _ in capture }
        )

        await coordinator.start(configuration: CaptureConfiguration(
            mode: .screen,
            capturesSystemAudio: false,
            capturesMicrophone: false
        ))
        let recordingID = try XCTUnwrap(coordinator.activeRecording?.id)
        let folder = library.folderURL(for: recordingID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("working").path))

        await coordinator.stop()

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("working").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("recording.mov").path))
    }

    func testFailedFinalizationPreservesWorkingDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(root.path, forKey: "RecorderLibraryPath")
        let library = RecordingLibrary(defaults: defaults)
        let capture = WorkingFileCapture()
        let coordinator = RecordingCoordinator(
            library: library,
            finalizer: FailingFinalizer(),
            captureFactory: { _ in capture }
        )

        await coordinator.start(configuration: CaptureConfiguration(
            mode: .screen,
            capturesSystemAudio: false,
            capturesMicrophone: false
        ))
        let recordingID = try XCTUnwrap(coordinator.activeRecording?.id)
        let working = library.folderURL(for: recordingID).appendingPathComponent("working")

        await coordinator.stop()

        XCTAssertTrue(FileManager.default.fileExists(atPath: working.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: working.appendingPathComponent("source.mov").path))
    }

    func testLateCaptureFailureStopsImmediatelyAndPreservesWorkingFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(root.path, forKey: "RecorderLibraryPath")
        let library = RecordingLibrary(defaults: defaults)
        let capture = LateFailingCapture()
        let coordinator = RecordingCoordinator(
            library: library,
            finalizer: FailingFinalizer(),
            captureFactory: { _ in capture }
        )

        await coordinator.start(configuration: CaptureConfiguration(mode: .audio))
        let recordingID = try XCTUnwrap(coordinator.activeRecording?.id)
        capture.fail("Test encoder failure")

        for _ in 0..<40 where coordinator.activeRecording != nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertNil(coordinator.activeRecording)
        let recording = try XCTUnwrap(
            library.recordings.first(where: { $0.id == recordingID })
        )
        XCTAssertEqual(recording.state, .failed)
        XCTAssertTrue(recording.errorMessage?.contains("Test encoder failure") == true)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: library.folderURL(for: recordingID)
                    .appendingPathComponent("working/source.m4a").path
            )
        )
        XCTAssertEqual(capture.stopCallCount, 1)
    }

    func testExportUsesCurrentUnsavedTrimSelection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(root.path, forKey: "RecorderLibraryPath")
        let library = RecordingLibrary(defaults: defaults)
        let finalizer = TrimSpyFinalizer()
        let coordinator = RecordingCoordinator(
            library: library,
            finalizer: finalizer
        )
        var (recording, folder) = try library.create(
            configuration: CaptureConfiguration(mode: .screen)
        )
        recording.mediaFile = "recording.mov"
        recording.duration = 100
        recording.trimStart = 0
        recording.trimEnd = 100
        try Data("media".utf8).write(to: folder.appendingPathComponent("recording.mov"))
        try library.save(recording, in: folder)

        try await coordinator.exportTrimmed(
            recording,
            to: root.appendingPathComponent("trimmed.mov"),
            startTime: 12.5,
            endTime: 34.25
        )

        let range = await finalizer.exportedRange
        XCTAssertEqual(range?.start, 12.5)
        XCTAssertEqual(range?.end, 34.25)
    }
}

private actor GatedStartingCapture: RecordingCapturing {
    private(set) var stopCallCount = 0
    private var startIsAllowed = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private let sourceURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("recorder-start-test-\(UUID().uuidString).mov")

    func start(
        configuration: CaptureConfiguration,
        workingDirectory: URL
    ) async throws -> CaptureArtifacts {
        if !startIsAllowed {
            await withCheckedContinuation { continuation in
                startContinuation = continuation
            }
        }
        return CaptureArtifacts(primaryMediaURL: sourceURL)
    }

    func allowStart() {
        startIsAllowed = true
        startContinuation?.resume()
        startContinuation = nil
    }

    func stop() async throws -> CaptureArtifacts {
        stopCallCount += 1
        return CaptureArtifacts(primaryMediaURL: sourceURL)
    }
}

private actor TrimSpyFinalizer: MediaFinalizing {
    private(set) var exportedRange: (start: TimeInterval, end: TimeInterval)?

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
    ) async throws {
        exportedRange = (startTime, endTime)
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

private actor WorkingFileCapture: RecordingCapturing {
    private var sourceURL: URL?

    func start(configuration: CaptureConfiguration, workingDirectory: URL) async throws -> CaptureArtifacts {
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let url = workingDirectory.appendingPathComponent("source.mov")
        try Data("recoverable source".utf8).write(to: url)
        sourceURL = url
        return CaptureArtifacts(primaryMediaURL: url)
    }

    func stop() async throws -> CaptureArtifacts {
        guard let sourceURL else { throw RecorderError.invalidState("Missing test capture") }
        return CaptureArtifacts(primaryMediaURL: sourceURL)
    }
}

private final class LateFailingCapture: RecordingCapturing,
    CaptureHealthProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var failure: String?
    private var sourceURL: URL?
    private var stops = 0

    var captureFailureDescription: String? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    var stopCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return stops
    }

    func fail(_ description: String) {
        lock.lock()
        failure = description
        lock.unlock()
    }

    func start(
        configuration: CaptureConfiguration,
        workingDirectory: URL
    ) async throws -> CaptureArtifacts {
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        let url = workingDirectory.appendingPathComponent("source.m4a")
        try Data("recoverable audio".utf8).write(to: url)
        lock.withLock {
            sourceURL = url
        }
        return CaptureArtifacts(
            primaryMediaURL: url,
            microphoneStemURL: url
        )
    }

    func stop() async throws -> CaptureArtifacts {
        let (url, failure) = lock.withLock {
            stops += 1
            return (sourceURL, self.failure)
        }
        if let failure {
            throw RecorderError.captureFailed(failure)
        }
        guard let url else {
            throw RecorderError.invalidState("Missing test capture")
        }
        return CaptureArtifacts(
            primaryMediaURL: url,
            microphoneStemURL: url
        )
    }
}

private struct CopyingFinalizer: MediaFinalizing {
    func finalize(
        artifacts: CaptureArtifacts,
        configuration: CaptureConfiguration,
        destinationDirectory: URL
    ) async throws -> FinalizedMedia {
        let destination = destinationDirectory.appendingPathComponent("recording.mov")
        try FileManager.default.copyItem(at: artifacts.primaryMediaURL, to: destination)
        return FinalizedMedia(
            mediaURL: destination,
            audioURL: destination,
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

private struct FailingFinalizer: MediaFinalizing {
    func finalize(
        artifacts: CaptureArtifacts,
        configuration: CaptureConfiguration,
        destinationDirectory: URL
    ) async throws -> FinalizedMedia {
        throw RecorderError.finalizationFailed("Test failure")
    }

    func exportTrimmed(
        sourceURL: URL,
        destinationURL: URL,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) async throws {}
}
