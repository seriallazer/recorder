import Foundation
@preconcurrency import AVFoundation
import ScreenCaptureKit
import CoreMedia

final class SystemAudioWriter: NSObject, SCStreamOutput, SCStreamDelegate {
    private let queue = DispatchQueue(label: "Recorder.SystemAudio", qos: .userInitiated)
    private let lock = NSLock()
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var writerStarted = false

    func start(displayID: UInt32?, outputURL: URL) async throws {
        guard stream == nil else {
            throw RecorderError.invalidState("System audio recording is already running.")
        }
        guard PermissionManager.hasScreenCaptureAccess else {
            throw RecorderError.permissionDenied("screen and system audio recording")
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let display = displayID.flatMap { selected in
            content.displays.first { $0.displayID == selected }
        } ?? content.displays.first
        guard let display else { throw RecorderError.missingDevice("display") }

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw RecorderError.captureFailed("System audio encoder is unavailable.")
        }
        writer.add(input)

        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.queueDepth = 3
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)

        self.stream = stream
        self.writer = writer
        self.writerInput = input
        self.outputURL = outputURL
        writerStarted = false
        do {
            try await stream.startCapture()
        } catch {
            clearState()
            writer.cancelWriting()
            throw error
        }
    }

    func stop() async throws -> URL? {
        guard let stream, let writer, let outputURL else {
            throw RecorderError.invalidState("System audio recording is not running.")
        }
        try? await stream.stopCapture()

        let didStart = await finishInputIfNeeded()
        guard didStart else {
            writer.cancelWriting()
            clearState()
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }

        try await writer.finishWritingAsync()
        defer { clearState() }
        guard writer.status == .completed else {
            throw writer.error ?? RecorderError.captureFailed("System audio could not be finalized.")
        }
        return outputURL
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {}

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio,
              CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let writer, let writerInput else { return }
        if !writerStarted {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            writerStarted = true
        }
        if writerInput.isReadyForMoreMediaData {
            _ = writerInput.append(sampleBuffer)
        }
    }

    private func finishInputIfNeeded() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                self.lock.lock()
                let didStart = self.writerStarted
                if didStart { self.writerInput?.markAsFinished() }
                self.lock.unlock()
                continuation.resume(returning: didStart)
            }
        }
    }

    private func clearState() {
        stream = nil
        writer = nil
        writerInput = nil
        outputURL = nil
        writerStarted = false
    }
}
