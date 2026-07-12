import XCTest
@testable import RecorderCore

@MainActor
final class RecordingLibraryTests: XCTestCase {
    func testManifestRoundTripAndRecovery() throws {
        let suite = "RecorderCoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = RecordingLibrary(defaults: defaults)
        try library.setRootURL(root)
        let config = CaptureConfiguration(mode: .audio, capturesSystemAudio: false)
        var (manifest, folder) = try library.create(configuration: config)
        manifest.state = .recording
        try library.save(manifest, in: folder)

        library.reload()
        XCTAssertEqual(library.recordings.first?.state, .recording)
        library.recoverInterruptedRecordings()
        XCTAssertEqual(library.recordings.first?.state, .failed)
        XCTAssertNotNil(library.recordings.first?.errorMessage)
    }

    func testEffectiveTrimRangeIsClamped() {
        let config = CaptureConfiguration(mode: .audio)
        var manifest = RecordingManifest(title: "Test", mode: .audio, configuration: config)
        manifest.duration = 60
        manifest.trimStart = 10
        manifest.trimEnd = 100
        XCTAssertEqual(manifest.effectiveTrimEnd, 60)
    }
}
