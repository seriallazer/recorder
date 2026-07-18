import Foundation

public protocol SpeakerDiarizing: Sendable {
    func diarize(_ audioURL: URL, expectedSpeakerCount: Int?) async throws -> [SpeakerInterval]
}

public struct CrashSafeDiarizationService: SpeakerDiarizing, Sendable {
    private let explicitHelperURL: URL?

    public init(helperURL: URL? = nil) {
        self.explicitHelperURL = helperURL
    }

    public func diarize(_ audioURL: URL, expectedSpeakerCount: Int?) async throws -> [SpeakerInterval] {
        let helperURL = try resolveHelperURL()
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecorderDiarization-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let outputURL = workingDirectory.appendingPathComponent("result.json")
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        let processBox = ProcessBox()
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let process = Process()
                    process.executableURL = helperURL
                    var arguments = [audioURL.path, outputURL.path]
                    if let expectedSpeakerCount {
                        arguments.append(String(expectedSpeakerCount))
                    }
                    process.arguments = arguments
                    var environment = ProcessInfo.processInfo.environment
                    environment["TMPDIR"] = workingDirectory.path
                    process.environment = environment
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    process.terminationHandler = { completed in
                        if completed.terminationReason == .exit, completed.terminationStatus == 0 {
                            continuation.resume()
                        } else {
                            continuation.resume(throwing: RecorderError.transcriptionFailed(
                                "The isolated speaker model stopped unexpectedly; stable labels were used instead."
                            ))
                        }
                    }
                    processBox.store(process)
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            } onCancel: {
                processBox.terminate()
            }
        } catch {
            // A terminated child reports a non-zero status. Preserve cancellation
            // semantics instead of misclassifying that expected status as a model
            // failure and producing a fallback transcript the user cancelled.
            try Task.checkCancellation()
            throw error
        }
        try Task.checkCancellation()

        let data = try Data(contentsOf: outputURL)
        let result = try JSONDecoder().decode(HelperOutput.self, from: data)
        guard !result.segments.isEmpty else {
            throw RecorderError.transcriptionFailed("The speaker model found no speech.")
        }
        return result.segments.map {
            SpeakerInterval(speaker: $0.speaker, startTime: $0.startTime, endTime: $0.endTime)
        }
    }

    private func resolveHelperURL() throws -> URL {
        if let explicitHelperURL, FileManager.default.isExecutableFile(atPath: explicitHelperURL.path) {
            return explicitHelperURL
        }
        var candidates: [URL] = []
        if let executable = Bundle.main.executableURL {
            candidates.append(executable.deletingLastPathComponent().appendingPathComponent("RecorderDiarizer"))
        }
        let currentExecutable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        candidates.append(currentExecutable.deletingLastPathComponent().appendingPathComponent("RecorderDiarizer"))
        if let helper = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return helper
        }
        throw RecorderError.modelUnavailable("The crash-safe speaker helper is missing from Recorder.app.")
    }
}

private struct HelperOutput: Decodable {
    var segments: [HelperSegment]
}

private struct HelperSegment: Decodable {
    var speaker: String
    var startTime: TimeInterval
    var endTime: TimeInterval
}

private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func store(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    func terminate() {
        lock.lock()
        let process = process
        lock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }
}
