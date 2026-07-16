import XCTest
@testable import RecorderCore

final class RecordingMetadataTests: XCTestCase {
    func testLoadsRecursiveFolderSizeAndFileCount() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let nested = folder.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10).write(to: folder.appendingPathComponent("one.bin"))
        try Data(repeating: 2, count: 25).write(to: nested.appendingPathComponent("two.bin"))
        let metadata = await RecordingMetadataReader.loadStorage(folder: folder)

        XCTAssertEqual(metadata.logicalSize, 35)
        XCTAssertGreaterThanOrEqual(metadata.allocatedSize, metadata.logicalSize)
        XCTAssertEqual(metadata.fileCount, 2)
        XCTAssertNotNil(metadata.latestModificationDate)
        XCTAssertNil(metadata.media)
    }
}
