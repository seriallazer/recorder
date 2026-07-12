import Foundation
import Combine
import AVFoundation
import AppKit

@MainActor
public final class RecordingCoordinator: ObservableObject {
    @Published public private(set) var activeRecording: RecordingManifest?
    @Published public private(set) var elapsedTime: TimeInterval = 0
    @Published public private(set) var audioLevel: Float = 0
    @Published public private(set) var modelPhase: String?
    @Published public private(set) var modelProgress: Double = 0
    @Published public var presentedError: String?

    public let library: RecordingLibrary
    private let finalizer: any MediaFinalizing
    private var activeCapture: (any RecordingCapturing)?
    private var activeFolder: URL?
    private var timer: Timer?
    private var startDate: Date?
    private var transcriptionTasks: [UUID: Task<Void, Never>] = [:]
    private var diskStopTriggered = false

    private lazy var transcriber = LocalTranscriptionService { [weak self] phase, fraction in
        Task { @MainActor in
            self?.modelPhase = phase
            self?.modelProgress = fraction
        }
    }

    public init(
        library: RecordingLibrary,
        finalizer: any MediaFinalizing = NativeMediaFinalizer()
    ) {
        self.library = library
        self.finalizer = finalizer
        library.recoverInterruptedRecordings()
    }

    public var cameraSession: AVCaptureSession? {
        (activeCapture as? CameraCaptureService)?.session
    }

    public func start(configuration: CaptureConfiguration) async {
        guard activeCapture == nil else {
            presentedError = "Stop the current recording before starting another."
            return
        }
        do {
            let (manifest, folder) = try library.create(configuration: configuration)
            var recording = manifest
            recording.state = .recording
            recording.errorMessage = nil
            try library.save(recording, in: folder)

            let capture: any RecordingCapturing = switch configuration.mode {
            case .audio: AudioCaptureService()
            case .camera: CameraCaptureService()
            case .screen: ScreenCaptureService()
            }
            let working = folder.appendingPathComponent("working", isDirectory: true)
            _ = try await capture.start(configuration: configuration, workingDirectory: working)
            activeCapture = capture
            activeFolder = folder
            activeRecording = recording
            elapsedTime = 0
            startDate = Date()
            diskStopTriggered = false
            startTimer()
        } catch {
            presentedError = error.localizedDescription
            activeCapture = nil
            activeFolder = nil
            activeRecording = nil
        }
    }

    public func stop() async {
        guard let capture = activeCapture,
              let folder = activeFolder,
              var recording = activeRecording else { return }
        stopTimer()
        recording.state = .finalizing
        try? library.save(recording, in: folder)
        activeRecording = recording

        do {
            let artifacts = try await capture.stop()
            let finalized = try await finalizer.finalize(
                artifacts: artifacts,
                configuration: recording.configuration,
                destinationDirectory: folder
            )
            recording.state = .ready
            recording.duration = finalized.duration
            recording.trimStart = 0
            recording.trimEnd = finalized.duration
            recording.mediaFile = finalized.mediaURL.lastPathComponent
            recording.audioFile = finalized.audioURL.lastPathComponent
            recording.microphoneStemFile = finalized.microphoneStemURL?.lastPathComponent
            recording.systemStemFile = finalized.systemStemURL?.lastPathComponent
            recording.errorMessage = nil
            try await createThumbnailIfNeeded(for: &recording, folder: folder)
            try library.save(recording, in: folder)
            clearActiveRecording()
            transcribe(recording)
        } catch {
            recording.state = .failed
            recording.errorMessage = error.localizedDescription
            try? library.save(recording, in: folder)
            presentedError = error.localizedDescription
            clearActiveRecording()
        }
    }

    @discardableResult
    public func importAudioFile(from sourceURL: URL) async -> RecordingManifest? {
        guard activeCapture == nil else {
            presentedError = "Stop the current recording before importing audio."
            return nil
        }

        let configuration = CaptureConfiguration(
            mode: .audio,
            capturesSystemAudio: false,
            capturesMicrophone: false
        )

        do {
            let (manifest, folder) = try library.create(configuration: configuration)
            let fileExtension = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
            let mediaURL = folder.appendingPathComponent("recording").appendingPathExtension(fileExtension)
            try? FileManager.default.removeItem(at: mediaURL)
            try FileManager.default.copyItem(at: sourceURL, to: mediaURL)

            var imported = manifest
            imported.title = sourceURL.deletingPathExtension().lastPathComponent
            imported.state = .ready
            imported.duration = try await mediaDuration(mediaURL)
            imported.trimStart = 0
            imported.trimEnd = imported.duration
            imported.mediaFile = mediaURL.lastPathComponent
            imported.audioFile = mediaURL.lastPathComponent
            imported.microphoneStemFile = mediaURL.lastPathComponent
            imported.systemStemFile = nil
            imported.errorMessage = nil
            try library.save(imported, in: folder)
            transcribe(imported)
            return imported
        } catch {
            presentedError = error.localizedDescription
            return nil
        }
    }

    public func transcribe(_ recording: RecordingManifest) {
        guard transcriptionTasks[recording.id] == nil else { return }
        let folder = library.folderURL(for: recording.id)
        transcriptionTasks[recording.id] = Task { [weak self] in
            guard let self else { return }
            var working = recording
            working.state = .transcribing
            working.errorMessage = nil
            try? self.library.save(working, in: folder)
            do {
                let document = try await self.transcriber.transcribe(recording: working, folder: folder)
                let jsonURL = folder.appendingPathComponent("transcript.json")
                let textURL = folder.appendingPathComponent("transcript.txt")
                try JSONEncoder.recorder.encode(document).write(to: jsonURL, options: .atomic)
                try document.plainText(
                    trimStart: working.trimStart,
                    trimEnd: working.effectiveTrimEnd
                ).write(to: textURL, atomically: true, encoding: .utf8)
                working.state = .ready
                working.transcriptFile = textURL.lastPathComponent
                working.speakerCount = document.speakerCount
                working.errorMessage = nil
                try self.library.save(working, in: folder)
            } catch is CancellationError {
                working.state = .ready
                try? self.library.save(working, in: folder)
            } catch {
                working.state = .failed
                working.errorMessage = error.localizedDescription
                try? self.library.save(working, in: folder)
                self.presentedError = error.localizedDescription
            }
            self.transcriptionTasks[recording.id] = nil
            self.modelPhase = nil
            self.modelProgress = 0
        }
    }

    public func cancelTranscription(for id: UUID) {
        transcriptionTasks[id]?.cancel()
    }

    public func updateTrim(for recording: RecordingManifest, start: TimeInterval, end: TimeInterval) throws {
        var updated = recording
        updated.trimStart = min(max(0, start), updated.duration)
        updated.trimEnd = min(max(updated.trimStart, end), updated.duration)
        let folder = library.folderURL(for: recording.id)
        try regenerateTranscript(for: updated, folder: folder)
        try library.save(updated, in: folder)
    }

    public func exportTrimmed(_ recording: RecordingManifest, to destinationURL: URL) async throws {
        let folder = library.folderURL(for: recording.id)
        guard let source = recording.fileURL(for: recording.mediaFile, in: folder) else {
            throw RecorderError.missingMedia
        }
        try await finalizer.exportTrimmed(
            sourceURL: source,
            destinationURL: destinationURL,
            startTime: recording.trimStart,
            endTime: recording.effectiveTrimEnd
        )
        if let document = loadTranscript(for: recording) {
            let textURL = destinationURL.deletingPathExtension().appendingPathExtension("txt")
            try document.plainText(
                trimStart: recording.trimStart,
                trimEnd: recording.effectiveTrimEnd
            ).write(to: textURL, atomically: true, encoding: .utf8)
        }
    }

    public func loadTranscript(for recording: RecordingManifest) -> TranscriptDocument? {
        let url = library.folderURL(for: recording.id).appendingPathComponent("transcript.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.recorder.decode(TranscriptDocument.self, from: data)
    }

    private func regenerateTranscript(for recording: RecordingManifest, folder: URL) throws {
        let jsonURL = folder.appendingPathComponent("transcript.json")
        guard let data = try? Data(contentsOf: jsonURL),
              let document = try? JSONDecoder.recorder.decode(TranscriptDocument.self, from: data) else { return }
        let textURL = folder.appendingPathComponent("transcript.txt")
        try document.plainText(
            trimStart: recording.trimStart,
            trimEnd: recording.effectiveTrimEnd
        ).write(to: textURL, atomically: true, encoding: .utf8)
    }

    private func createThumbnailIfNeeded(for recording: inout RecordingManifest, folder: URL) async throws {
        guard recording.mode != .audio,
              let media = recording.fileURL(for: recording.mediaFile ?? "recording.mov", in: folder) else { return }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: media))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)
        let image = try generator.copyCGImage(
            at: CMTime(seconds: min(1, recording.duration / 2), preferredTimescale: 600),
            actualTime: nil
        )
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return }
        let url = folder.appendingPathComponent("thumbnail.jpg")
        try data.write(to: url, options: .atomic)
        recording.thumbnailFile = url.lastPathComponent
    }

    private func mediaDuration(_ url: URL) async throws -> TimeInterval {
        let duration = try await AVURLAsset(url: url).load(.duration)
        return max(0, duration.seconds)
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startDate = self.startDate else { return }
                self.elapsedTime = Date().timeIntervalSince(startDate)
                self.audioLevel = (self.activeCapture as? AudioLevelProviding)?.audioLevel ?? 0
                if !self.diskStopTriggered,
                   self.library.availableCapacity < 250 * 1_024 * 1_024,
                   self.activeRecording?.state == .recording {
                    self.diskStopTriggered = true
                    self.presentedError = "Recording is stopping because less than 250 MB of disk space remains."
                    Task { await self.stop() }
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func clearActiveRecording() {
        stopTimer()
        activeCapture = nil
        activeFolder = nil
        activeRecording = nil
        startDate = nil
        elapsedTime = 0
        audioLevel = 0
        diskStopTriggered = false
    }
}
