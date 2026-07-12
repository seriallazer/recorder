import XCTest
@testable import RecorderCore

@MainActor
final class RecordingLibraryTests: XCTestCase {
    func testManifestRoundTripAndRecovery() throws {
        let (library, defaults, suite, root) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        defer { try? FileManager.default.removeItem(at: root) }

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

    func testCreatedFolderUsesReadableTimestampModeName() throws {
        let (library, defaults, suite, root) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        defer { try? FileManager.default.removeItem(at: root) }

        try library.setRootURL(root)
        let (_, folder) = try library.create(configuration: CaptureConfiguration(mode: .screen))

        XCTAssertTrue(folder.lastPathComponent.range(
            of: #"^\d{8}_\d{4}_screen$"#,
            options: .regularExpression
        ) != nil)
    }

    func testFolderLookupUsesManifestIDForReadableFolders() throws {
        let (library, defaults, suite, root) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        defer { try? FileManager.default.removeItem(at: root) }

        try library.setRootURL(root)
        let (manifest, folder) = try library.create(configuration: CaptureConfiguration(mode: .audio))
        library.reload()

        XCTAssertEqual(
            library.folderURL(for: manifest.id).resolvingSymlinksInPath(),
            folder.resolvingSymlinksInPath()
        )
    }

    func testRenameFolderAddsIdentifier() throws {
        let (library, defaults, suite, root) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        defer { try? FileManager.default.removeItem(at: root) }

        try library.setRootURL(root)
        let (manifest, _) = try library.create(configuration: CaptureConfiguration(mode: .audio))
        let renamed = try library.renameFolder(for: manifest, identifier: "Demo File.m4a")

        XCTAssertTrue(renamed.lastPathComponent.hasSuffix("_audio_Demo_File_m4a"))
        XCTAssertEqual(library.folderURL(for: manifest.id), renamed)
    }

    func testEffectiveTrimRangeIsClamped() {
        let config = CaptureConfiguration(mode: .audio)
        var manifest = RecordingManifest(title: "Test", mode: .audio, configuration: config)
        manifest.duration = 60
        manifest.trimStart = 10
        manifest.trimEnd = 100
        XCTAssertEqual(manifest.effectiveTrimEnd, 60)
    }

    private func makeLibrary() throws -> (RecordingLibrary, UserDefaults, String, URL) {
        let suite = "RecorderCoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (RecordingLibrary(defaults: defaults), defaults, suite, root)
    }
}
