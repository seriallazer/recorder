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

    func testRenameUpdatesTitleAndCreatesStableUntaggedSymlink() throws {
        let (library, defaults, suite, root) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        defer { try? FileManager.default.removeItem(at: root) }

        try library.setRootURL(root)
        let (manifest, canonicalFolder) = try library.create(configuration: CaptureConfiguration(mode: .audio))
        let renamed = try library.rename(manifest, title: "Mock Interview", tag: nil)
        let organizationPath = try XCTUnwrap(renamed.organizationPath)
        let link = root.appendingPathComponent(organizationPath)

        XCTAssertEqual(renamed.title, "Mock Interview")
        XCTAssertNil(renamed.tag)
        XCTAssertEqual(library.folderURL(for: manifest.id), canonicalFolder)
        XCTAssertTrue(link.lastPathComponent.hasSuffix("_Mock_Interview"))
        XCTAssertEqual(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, true)
        XCTAssertEqual(normalizedPath(link.resolvingSymlinksInPath()), normalizedPath(canonicalFolder))

        library.reload()
        XCTAssertEqual(library.recordings.first?.title, "Mock Interview")
        XCTAssertEqual(normalizedPath(library.folderURL(for: manifest.id)), normalizedPath(canonicalFolder))
    }

    func testTagCreatesNestedSymlinkAndRetagRemovesOldLink() throws {
        let (library, defaults, suite, root) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        defer { try? FileManager.default.removeItem(at: root) }

        try library.setRootURL(root)
        let (manifest, canonicalFolder) = try library.create(configuration: CaptureConfiguration(mode: .screen))
        let tagged = try library.rename(manifest, title: "API Design", tag: "System Design")
        let oldPath = try XCTUnwrap(tagged.organizationPath)
        let oldLink = root.appendingPathComponent(oldPath)

        XCTAssertEqual(tagged.tag, "System Design")
        XCTAssertEqual(oldLink.deletingLastPathComponent().lastPathComponent, "System_Design")
        XCTAssertEqual(oldLink.resolvingSymlinksInPath(), canonicalFolder.resolvingSymlinksInPath())

        let retagged = try library.rename(tagged, title: "API Design Round 2", tag: "Mocks")
        let newLink = root.appendingPathComponent(try XCTUnwrap(retagged.organizationPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldLink.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("System_Design").path))
        XCTAssertEqual(newLink.deletingLastPathComponent().lastPathComponent, "Mocks")
        XCTAssertEqual(newLink.resolvingSymlinksInPath(), canonicalFolder.resolvingSymlinksInPath())
    }

    func testOrganizationLinkDoesNotReuseCanonicalFolderName() throws {
        let (library, defaults, suite, root) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        defer { try? FileManager.default.removeItem(at: root) }

        try library.setRootURL(root)
        let (manifest, canonicalFolder) = try library.create(configuration: CaptureConfiguration(mode: .audio))
        let renamed = try library.rename(manifest, title: "audio", tag: nil)
        let link = root.appendingPathComponent(try XCTUnwrap(renamed.organizationPath))

        XCTAssertNotEqual(normalizedPath(link), normalizedPath(canonicalFolder))
        XCTAssertEqual(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, true)
        XCTAssertEqual(normalizedPath(link.resolvingSymlinksInPath()), normalizedPath(canonicalFolder))
    }

    func testRenameIsRejectedDuringTranscription() throws {
        let (library, defaults, suite, root) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        defer { try? FileManager.default.removeItem(at: root) }

        try library.setRootURL(root)
        var (manifest, folder) = try library.create(configuration: CaptureConfiguration(mode: .audio))
        let staleIdleManifest = manifest
        manifest.state = .transcribing
        try library.save(manifest, in: folder)

        XCTAssertThrowsError(try library.rename(staleIdleManifest, title: "Unsafe Rename", tag: "Mocks"))
        XCTAssertEqual(library.folderURL(for: manifest.id), folder)
    }

    func testEffectiveTrimRangeIsClamped() {
        let config = CaptureConfiguration(mode: .audio)
        var manifest = RecordingManifest(title: "Test", mode: .audio, configuration: config)
        manifest.duration = 60
        manifest.trimStart = 10
        manifest.trimEnd = 100
        XCTAssertEqual(manifest.effectiveTrimEnd, 60)
    }

    func testDeleteRemovesRecordingFolderAndLibraryEntry() throws {
        let (library, defaults, suite, root) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        defer { try? FileManager.default.removeItem(at: root) }
        try library.setRootURL(root)
        let (manifest, folder) = try library.create(configuration: CaptureConfiguration(mode: .audio))
        let renamed = try library.rename(manifest, title: "Delete Me", tag: "Temporary")
        let link = root.appendingPathComponent(try XCTUnwrap(renamed.organizationPath))

        try library.delete(renamed)

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Temporary").path))
        XCTAssertFalse(library.recordings.contains(where: { $0.id == manifest.id }))
    }

    private func makeLibrary() throws -> (RecordingLibrary, UserDefaults, String, URL) {
        let suite = "RecorderCoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (RecordingLibrary(defaults: defaults), defaults, suite, root)
    }

    private func normalizedPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : path
    }
}
