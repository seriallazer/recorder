import Foundation
import Darwin
import RecorderCore

@main
struct RecorderEchoRepairCommand {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let folderArgument = arguments.first, !folderArgument.hasPrefix("-") else {
            throw CommandError.usage
        }
        let folder = URL(fileURLWithPath: folderArgument, isDirectory: true).standardizedFileURL
        var transcriptionMode: DiarizationMode?
        var expectedSpeakers = 2
        var cleanExistingTranscript = false
        var reprocessFromOriginals = false
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--transcribe":
                guard transcriptionMode == nil, index + 1 < arguments.count else {
                    throw CommandError.invalidArgument("--transcribe requires one mode.")
                }
                transcriptionMode = try parseMode(arguments[index + 1])
                index += 2
            case "--expected-speakers":
                guard index + 1 < arguments.count else {
                    throw CommandError.invalidArgument("--expected-speakers requires a value.")
                }
                expectedSpeakers = try parseSpeakerCount(arguments[index + 1])
                index += 2
            case "--clean-existing-transcript":
                guard !cleanExistingTranscript else {
                    throw CommandError.invalidArgument(
                        "--clean-existing-transcript may only be supplied once."
                    )
                }
                cleanExistingTranscript = true
                index += 1
            case "--reprocess":
                guard !reprocessFromOriginals else {
                    throw CommandError.invalidArgument("--reprocess may only be supplied once.")
                }
                reprocessFromOriginals = true
                index += 1
            default:
                throw CommandError.invalidArgument("Unknown argument: \(arguments[index])")
            }
        }
        guard transcriptionMode == nil || !cleanExistingTranscript else {
            throw CommandError.invalidArgument(
                "Use either --transcribe or --clean-existing-transcript, not both."
            )
        }

        log("Analyzing \(folder.path)…")
        let repair = try await ScreenEchoRepairService().repair(
            folder: folder,
            reprocessFromOriginals: reprocessFromOriginals
        )
        if repair.alreadyClean {
            log("Echo cleanup was already applied; active media was left unchanged.")
        } else if repair.applied {
            let delay = Int(((repair.detectedDelay ?? 0) * 1_000).rounded())
            let confidence = String(format: "%.3f", repair.confidence ?? 0)
            log("Echo cleanup applied (delay \(delay) ms, confidence \(confidence)).")
            log("Raw rollback files were retained as *.pre-echo-cleanup.*")
        } else {
            log("No high-confidence echo was detected; active media was left unchanged.")
        }

        if let transcriptionMode {
            try await transcribe(
                folder: folder,
                mode: transcriptionMode,
                expectedSpeakers: expectedSpeakers,
                preserveCurrentTranscript: repair.applied
            )
        } else if cleanExistingTranscript {
            try cleanTranscript(folder: folder)
        }
    }

    private static func cleanTranscript(folder: URL) throws {
        let manifestURL = folder.appendingPathComponent("manifest.json")
        var manifest = try decoder.decode(
            RecordingManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        guard manifest.mode == .screen,
              manifest.state == .ready,
              manifest.echoCancellationApplied == true else {
            throw RecorderError.invalidState(
                "Clean the completed screen recording before de-duplicating its transcript."
            )
        }
        let jsonURL = folder.appendingPathComponent("transcript.json")
        let textURL = folder.appendingPathComponent("transcript.txt")
        var document = try decoder.decode(
            TranscriptDocument.self,
            from: Data(contentsOf: jsonURL)
        )
        try preserveIfPresent(
            jsonURL,
            as: folder.appendingPathComponent("transcript.pre-cross-channel-dedup.json")
        )
        try preserveIfPresent(
            textURL,
            as: folder.appendingPathComponent("transcript.pre-cross-channel-dedup.txt")
        )

        let originalCount = document.segments.count
        let unmarked = document.segments.map { segment -> TranscriptSegment in
            var segment = segment
            if segment.source != .mixed { segment.isOverlapping = false }
            return segment
        }
        document.segments = TranscriptAligner.markingCrossSourceOverlaps(
            in: TranscriptAligner.removingCrossSourceEcho(in: unmarked)
        )
        document.generatedAt = Date()
        document.speakerCount = Set(document.segments.map(\.speaker)).count
        try encoder.encode(document).write(to: jsonURL, options: .atomic)
        try document.plainText(
            trimStart: manifest.trimStart,
            trimEnd: manifest.effectiveTrimEnd
        ).write(to: textURL, atomically: true, encoding: .utf8)
        manifest.speakerCount = document.speakerCount
        manifest.updatedAt = Date()
        manifest.errorMessage = nil
        try save(manifest, to: manifestURL)
        log("Removed \(originalCount - document.segments.count) time-aligned cross-channel echo segments.")
        log("Transcript updated: \(textURL.path)")
    }

    private static func transcribe(
        folder: URL,
        mode: DiarizationMode,
        expectedSpeakers: Int,
        preserveCurrentTranscript: Bool
    ) async throws {
        let manifestURL = folder.appendingPathComponent("manifest.json")
        var manifest = try decoder.decode(
            RecordingManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        guard manifest.state == .ready else {
            throw RecorderError.invalidState("Wait until recording and transcription work has finished.")
        }
        if preserveCurrentTranscript {
            try preserveIfPresent(
                folder.appendingPathComponent("transcript.json"),
                as: folder.appendingPathComponent("transcript.pre-echo-cleanup.json")
            )
            try preserveIfPresent(
                folder.appendingPathComponent("transcript.txt"),
                as: folder.appendingPathComponent("transcript.pre-echo-cleanup.txt")
            )
        }

        manifest.state = .transcribing
        manifest.errorMessage = nil
        manifest.updatedAt = Date()
        try save(manifest, to: manifestURL)

        let service = LocalTranscriptionService { phase, fraction in
            let percent = Int((min(max(fraction, 0), 1) * 100).rounded())
            log("[\(percent)%] \(phase)")
        }
        do {
            let document = try await service.transcribe(
                recording: manifest,
                folder: folder,
                options: DiarizationOptions(
                    mode: mode,
                    expectedSpeakerCount: expectedSpeakers
                )
            )
            let jsonURL = folder.appendingPathComponent("transcript.json")
            let textURL = folder.appendingPathComponent("transcript.txt")
            try encoder.encode(document).write(to: jsonURL, options: .atomic)
            try document.plainText(
                trimStart: manifest.trimStart,
                trimEnd: manifest.effectiveTrimEnd
            ).write(to: textURL, atomically: true, encoding: .utf8)
            manifest.state = .ready
            manifest.transcriptFile = textURL.lastPathComponent
            manifest.speakerCount = document.speakerCount
            manifest.errorMessage = nil
            manifest.updatedAt = Date()
            try save(manifest, to: manifestURL)
            log("Transcript regenerated: \(textURL.path)")
        } catch {
            manifest.state = .ready
            manifest.errorMessage = error.localizedDescription
            manifest.updatedAt = Date()
            try? save(manifest, to: manifestURL)
            throw error
        }
    }

    private static func parseMode(_ value: String) throws -> DiarizationMode {
        guard let mode = DiarizationMode(rawValue: value.lowercased()) else {
            throw CommandError.invalidArgument("--transcribe must be automatic, stable, or enhanced.")
        }
        return mode
    }

    private static func parseSpeakerCount(_ value: String) throws -> Int {
        guard let count = Int(value), (2...6).contains(count) else {
            throw CommandError.invalidArgument("--expected-speakers must be between 2 and 6.")
        }
        return count
    }

    private static func preserveIfPresent(_ source: URL, as destination: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.path),
              !fileManager.fileExists(atPath: destination.path) else { return }
        try fileManager.copyItem(at: source, to: destination)
    }

    private static func save(_ manifest: RecordingManifest, to url: URL) throws {
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    private static func log(_ message: String) {
        print(message)
        fflush(stdout)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private enum CommandError: LocalizedError {
    case usage
    case invalidArgument(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            "Usage: repair-screen-echo.sh <recording-folder> [--reprocess] [--transcribe automatic|stable|enhanced] [--expected-speakers 2-6] [--clean-existing-transcript]"
        case .invalidArgument(let message):
            message
        }
    }
}
