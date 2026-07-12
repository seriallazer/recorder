import Foundation
import Combine

@MainActor
public final class RecordingLibrary: ObservableObject {
    @Published public private(set) var recordings: [RecordingManifest] = []
    @Published public private(set) var rootURL: URL

    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let bookmarkKey = "RecorderLibraryBookmark"
    private let pathKey = "RecorderLibraryPath"
    private var folderCache: [UUID: URL] = [:]

    public init(fileManager: FileManager = .default, defaults: UserDefaults = .standard) {
        self.fileManager = fileManager
        self.defaults = defaults
        self.rootURL = Self.defaultRoot(fileManager: fileManager)
        restoreBookmark()
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        reload()
    }

    public func setRootURL(_ url: URL) throws {
        rootURL.stopAccessingSecurityScopedResource()
        defaults.set(url.path, forKey: pathKey)
        if let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            defaults.set(bookmark, forKey: bookmarkKey)
        }
        rootURL = url
        _ = rootURL.startAccessingSecurityScopedResource()
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        reload()
    }

    public func reload() {
        let decoder = JSONDecoder.recorder
        guard let folders = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            recordings = []
            return
        }

        var resolvedFolders: [UUID: URL] = [:]
        recordings = folders.compactMap { folder in
            let url = folder.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: url) else { return nil }
            guard let recording = try? decoder.decode(RecordingManifest.self, from: data) else { return nil }
            resolvedFolders[recording.id] = folder
            return recording
        }.sorted { $0.createdAt > $1.createdAt }
        folderCache = resolvedFolders
    }

    public func create(configuration: CaptureConfiguration) throws -> (RecordingManifest, URL) {
        guard Self.availableCapacity(at: rootURL) > 500 * 1_024 * 1_024 else {
            throw RecorderError.insufficientDiskSpace
        }

        let id = UUID()
        let createdAt = Date()
        let title = Self.defaultTitle(for: configuration.mode, date: createdAt)
        let manifest = RecordingManifest(
            id: id,
            title: title,
            createdAt: createdAt,
            mode: configuration.mode,
            state: .idle,
            configuration: configuration
        )
        let folder = try uniqueFolderURL(
            baseName: Self.defaultFolderName(for: configuration.mode, date: createdAt)
        )
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: folder.appendingPathComponent("working", isDirectory: true),
            withIntermediateDirectories: true
        )
        folderCache[id] = folder
        try save(manifest, in: folder)
        return (manifest, folder)
    }

    public func save(_ manifest: RecordingManifest, in folder: URL? = nil) throws {
        var updated = manifest
        updated.updatedAt = Date()
        let targetFolder = folder ?? folderURL(for: manifest.id)
        try fileManager.createDirectory(at: targetFolder, withIntermediateDirectories: true)
        let data = try JSONEncoder.recorder.encode(updated)
        try data.write(to: targetFolder.appendingPathComponent("manifest.json"), options: .atomic)

        if let index = recordings.firstIndex(where: { $0.id == updated.id }) {
            recordings[index] = updated
        } else {
            recordings.append(updated)
        }
        folderCache[updated.id] = targetFolder
        recordings.sort { $0.createdAt > $1.createdAt }
    }

    public func delete(_ manifest: RecordingManifest) throws {
        try fileManager.removeItem(at: folderURL(for: manifest.id))
        recordings.removeAll { $0.id == manifest.id }
        folderCache[manifest.id] = nil
    }

    public func renameFolder(for manifest: RecordingManifest, identifier: String) throws -> URL {
        let current = folderURL(for: manifest.id)
        let baseName = Self.defaultFolderName(for: manifest.mode, date: manifest.createdAt, identifier: identifier)
        let destination = try uniqueFolderURL(baseName: baseName)
        guard current != destination else { return current }
        try fileManager.moveItem(at: current, to: destination)
        folderCache[manifest.id] = destination
        return destination
    }

    public func folderURL(for id: UUID) -> URL {
        if let cached = folderCache[id] {
            return cached
        }

        guard let folders = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
        }

        for folder in folders {
            let manifestURL = folder.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder.recorder.decode(RecordingManifest.self, from: data),
                  manifest.id == id else { continue }
            folderCache[id] = folder
            return folder
        }

        return rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public var availableCapacity: Int64 {
        Self.availableCapacity(at: rootURL)
    }

    public func recoverInterruptedRecordings() {
        for var recording in recordings where [.recording, .finalizing, .transcribing].contains(recording.state) {
            recording.state = .failed
            recording.errorMessage = "The app closed before this operation completed. Recoverable source files remain in the working folder."
            try? save(recording)
        }
    }

    private func restoreBookmark() {
        if let data = defaults.data(forKey: bookmarkKey) {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                rootURL = url
                _ = rootURL.startAccessingSecurityScopedResource()
                if stale, let refreshed = try? url.bookmarkData(options: .withSecurityScope) {
                    defaults.set(refreshed, forKey: bookmarkKey)
                }
                return
            }
        }
        if let path = defaults.string(forKey: pathKey), !path.isEmpty {
            rootURL = URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    private static func defaultRoot(fileManager: FileManager) -> URL {
        let movies = fileManager.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        return movies.appendingPathComponent("Recorder", isDirectory: true)
    }

    private static func defaultTitle(for mode: RecordingMode, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "\(mode.displayName) Recording \(formatter.string(from: date))"
    }

    private static func defaultFolderName(for mode: RecordingMode, date: Date) -> String {
        defaultFolderName(for: mode, date: date, identifier: nil)
    }

    private static func defaultFolderName(for mode: RecordingMode, date: Date, identifier: String?) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmm"
        let prefix = "\(formatter.string(from: date))_\(mode.folderName)"
        guard let identifier, !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return prefix
        }
        return "\(prefix)_\(identifier)"
    }

    private func uniqueFolderURL(baseName: String) throws -> URL {
        var candidate = sanitizedFolderName(baseName)
        var url = rootURL.appendingPathComponent(candidate, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: url.path) {
            candidate = "\(sanitizedFolderName(baseName))_\(suffix)"
            url = rootURL.appendingPathComponent(candidate, isDirectory: true)
            suffix += 1
        }
        return url
    }

    private func sanitizedFolderName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let collapsed = String(scalars)
            .split(separator: "_", omittingEmptySubsequences: true)
            .joined(separator: "_")
        return collapsed.isEmpty ? "recording" : collapsed
    }

    private static func availableCapacity(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? .max
    }
}

private extension RecordingMode {
    var folderName: String {
        switch self {
        case .audio: "audio"
        case .camera: "video"
        case .screen: "screen"
        }
    }
}

extension JSONEncoder {
    static var recorder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var recorder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
