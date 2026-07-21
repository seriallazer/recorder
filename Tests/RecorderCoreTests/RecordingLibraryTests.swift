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

    func testExistingTagsAreUniqueAndCaseInsensitiveSorted() throws {
        let (library, defaults, suite, root) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        defer { try? FileManager.default.removeItem(at: root) }

        try library.setRootURL(root)
        let (first, _) = try library.create(configuration: CaptureConfiguration(mode: .audio))
        let (second, _) = try library.create(configuration: CaptureConfiguration(mode: .audio))
        let (third, _) = try library.create(configuration: CaptureConfiguration(mode: .audio))
        _ = try library.rename(first, title: "First", tag: "System Design")
        _ = try library.rename(second, title: "Second", tag: "mocks")
        _ = try library.rename(third, title: "Third", tag: "Mocks")

        XCTAssertEqual(library.existingTags.count, 2)
        XCTAssertEqual(library.existingTags.map { $0.lowercased() }, ["mocks", "system design"])
    }

    func testCleanupOnlyRemovesRecognizedCompletedRecordingLeftovers() throws {
        let (library, defaults, suite, root) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        defer { try? FileManager.default.removeItem(at: root) }

        try library.setRootURL(root)
        var (ready, readyFolder) = try library.create(configuration: CaptureConfiguration(mode: .screen))
        ready.state = .ready
        ready.mediaFile = "recording.mov"
        let activeMedia = readyFolder.appendingPathComponent("recording.mov")
        let temporaryMedia = readyFolder.appendingPathComponent(".recording.tmp.mov")
        let rollbackMedia = readyFolder.appendingPathComponent("recording.pre-echo-cleanup.mov")
        let working = readyFolder.appendingPathComponent("working", isDirectory: true)
        let workingFile = working.appendingPathComponent("capture-part.mov")
        try Data(repeating: 1, count: 512).write(to: activeMedia)
        try Data(repeating: 2, count: 256).write(to: temporaryMedia)
        try Data(repeating: 3, count: 384).write(to: rollbackMedia)
        try Data(repeating: 4, count: 128).write(to: workingFile)
        try library.save(ready, in: readyFolder)

        var (failed, failedFolder) = try library.create(configuration: CaptureConfiguration(mode: .screen))
        failed.state = .failed
        let recoveryFile = failedFolder
            .appendingPathComponent("working", isDirectory: true)
            .appendingPathComponent("recoverable.mov")
        try Data(repeating: 5, count: 640).write(to: recoveryFile)
        try library.save(failed, in: failedFolder)

        let summary = library.cleanupSummary()
        XCTAssertEqual(summary.temporaryItemCount, 2)
        XCTAssertGreaterThan(summary.temporaryBytes, 0)
        XCTAssertEqual(summary.rollbackItemCount, 1)
        XCTAssertGreaterThan(summary.rollbackBytes, 0)

        let safeResult = try library.cleanTemporaryFiles()
        XCTAssertEqual(safeResult.removedItemCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: activeMedia.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryMedia.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: working.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rollbackMedia.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryFile.path))

        let rollbackResult = try library.cleanTemporaryFiles(includeRollbackMedia: true)
        XCTAssertEqual(rollbackResult.removedItemCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rollbackMedia.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: activeMedia.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryFile.path))
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
