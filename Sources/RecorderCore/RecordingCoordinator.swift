import Foundation
import Combine
import AVFoundation

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
    private let captureFactory: (RecordingMode) -> any RecordingCapturing
    private var activeCapture: (any RecordingCapturing)?
    private var activeFolder: URL?
    private var timer: Timer?
    private var startDate: Date?
    private var transcriptionTasks: [UUID: Task<Void, Never>] = [:]
    private var diskStopTriggered = false
    private var stopInProgress = false

    private lazy var transcriber = LocalTranscriptionService { [weak self] phase, fraction in
        Task { @MainActor in
            self?.modelPhase = phase
            self?.modelProgress = fraction
        }
    }

    public init(
        library: RecordingLibrary,
        finalizer: any MediaFinalizing = NativeMediaFinalizer(),
        captureFactory: @escaping (RecordingMode) -> any RecordingCapturing = { mode in
            switch mode {
            case .audio: AudioCaptureService()
            case .camera: CameraCaptureService()
            case .screen: ScreenCaptureService()
            }
        }
    ) {
        self.library = library
        self.finalizer = finalizer
        self.captureFactory = captureFactory
        library.recoverInterruptedRecordings()
    }

    public var cameraSession: AVCaptureSession? {
        (activeCapture as? CameraCaptureService)?.session
    }

    public func start(configuration: CaptureConfiguration) async {
        guard activeCapture == nil, !stopInProgress else {
            presentedError = "Stop the current recording before starting another."
            return
        }
        do {
            let (manifest, folder) = try library.create(configuration: configuration)
            var recording = manifest
            recording.state = .recording
            recording.errorMessage = nil
            try library.save(recording, in: folder)

            let capture = captureFactory(configuration.mode)
            let working = folder.appendingPathComponent("working", isDirectory: true)
            do {
                _ = try await capture.start(configuration: configuration, workingDirectory: working)
            } catch {
                // A capture can fail after opening a device or writer. Give it a
                // chance to release those resources before showing the error.
                try? await capture.stop()
                recording.state = .failed
                recording.errorMessage = error.localizedDescription
                try? library.save(recording, in: folder)
                throw error
            }
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
        guard !stopInProgress else { return }
        guard let capture = activeCapture,
              let folder = activeFolder,
              var recording = activeRecording,
              recording.state == .recording else { return }
        stopInProgress = true
        defer { stopInProgress = false }
        stopTimer()
        recording.state = .finalizing
        try? library.save(recording, in: folder)
        activeRecording = recording

        do {
            let artifacts: CaptureArtifacts
            do {
                artifacts = try await capture.stop()
            } catch {
                // AVCapture may report a late stop error after it has already
                // closed the movie file. Preserve and finalize that source when
                // it exists instead of discarding an otherwise usable movie.
                let fallback = folder
                    .appendingPathComponent("working", isDirectory: true)
                    .appendingPathComponent("camera-source.mov")
                guard recording.mode == .camera,
                      FileManager.default.fileExists(atPath: fallback.path) else {
                    throw error
                }
                artifacts = CaptureArtifacts(primaryMediaURL: fallback)
            }
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
            let hasSeparateAudio = finalized.audioURL != finalized.mediaURL
            let hasCapturedAudio = recording.mode == .audio
                || finalized.microphoneStemURL != nil
                || finalized.systemStemURL != nil
            // Movie recordings keep the movie itself as the transcription source
            // when extracting a separate M4A companion was not possible. This
            // prevents a valid camera recording from being discarded before ASR.
            let audioReferenceIsPresent = FileManager.default.fileExists(atPath: finalized.audioURL.path)
            recording.audioFile = audioReferenceIsPresent && (hasSeparateAudio || hasCapturedAudio || recording.mode == .camera)
                ? finalized.audioURL.lastPathComponent
                : nil
            recording.microphoneStemFile = finalized.microphoneStemURL?.lastPathComponent
            recording.systemStemFile = finalized.systemStemURL?.lastPathComponent
            recording.errorMessage = nil
            // Thumbnail generation is cosmetic. A decoder failure must never
            // turn a successfully finalized recording into a failed one.
            try? await createThumbnailIfNeeded(for: &recording, folder: folder)
            try library.save(recording, in: folder)
            removeWorkingDirectoryIfSafe(in: folder, finalized: finalized)
            clearActiveRecording()
            if recording.audioFile != nil {
                transcribe(recording)
            }
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
            let (manifest, _) = try library.create(configuration: configuration)
            let fileExtension = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
            let title = sourceURL.deletingPathExtension().lastPathComponent
            var imported = try library.rename(manifest, title: title, tag: nil)
            let destinationFolder = library.folderURL(for: manifest.id)
            let mediaURL = destinationFolder.appendingPathComponent("recording").appendingPathExtension(fileExtension)
            try? FileManager.default.removeItem(at: mediaURL)
            try FileManager.default.copyItem(at: sourceURL, to: mediaURL)

            imported.state = .ready
            imported.duration = try await mediaDuration(mediaURL)
            imported.trimStart = 0
            imported.trimEnd = imported.duration
            imported.mediaFile = mediaURL.lastPathComponent
            imported.audioFile = mediaURL.lastPathComponent
            imported.microphoneStemFile = mediaURL.lastPathComponent
            imported.systemStemFile = nil
            imported.errorMessage = nil
            try library.save(imported, in: destinationFolder)
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
        let data = try await ThumbnailGenerator.jpegData(for: media)
        let url = folder.appendingPathComponent("thumbnail.jpg")
        try data.write(to: url, options: .atomic)
        recording.thumbnailFile = url.lastPathComponent
    }

    private func removeWorkingDirectoryIfSafe(in folder: URL, finalized: FinalizedMedia) {
        let working = folder.appendingPathComponent("working", isDirectory: true).standardizedFileURL
        let retainedFiles = [
            finalized.mediaURL,
            finalized.audioURL,
            finalized.microphoneStemURL,
            finalized.systemStemURL
        ].compactMap { $0?.standardizedFileURL }
        let workingPrefix = working.path.hasSuffix("/") ? working.path : working.path + "/"
        guard retainedFiles.allSatisfy({ file in
            file.path != working.path && !file.path.hasPrefix(workingPrefix)
        }) else { return }
        try? FileManager.default.removeItem(at: working)
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
