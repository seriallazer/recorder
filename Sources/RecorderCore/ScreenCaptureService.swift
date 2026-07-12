import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

public final class ScreenCaptureService: NSObject, RecordingCapturing, AudioLevelProviding, SCStreamOutput, SCStreamDelegate {
    private let queue = DispatchQueue(label: "Recorder.ScreenCapture", qos: .userInitiated)
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var microphoneWriter: MicrophoneWriter?
    private var artifacts: CaptureArtifacts?
    private var writerStarted = false
    private let lock = NSLock()

    public override init() {
        super.init()
    }

    public var audioLevel: Float { microphoneWriter?.audioLevel ?? 0 }

    public func start(configuration: CaptureConfiguration, workingDirectory: URL) async throws -> CaptureArtifacts {
        guard PermissionManager.requestScreenCapture() else {
            throw RecorderError.permissionDenied("screen recording")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let filter: SCContentFilter

        switch configuration.screenTarget {
        case .window:
            guard let window = content.windows.first(where: { $0.windowID == configuration.windowID }) else {
                throw RecorderError.missingDevice("selected window")
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
        case .display, .region:
            let display = configuration.displayID.flatMap { id in content.displays.first { $0.displayID == id } }
                ?? content.displays.first
            guard let display else { throw RecorderError.missingDevice("display") }
            filter = SCContentFilter(display: display, excludingWindows: [])
        }

        let sourceURL = workingDirectory.appendingPathComponent("screen-source.mov")
        try? FileManager.default.removeItem(at: sourceURL)
        let writer = try AVAssetWriter(outputURL: sourceURL, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: configuration.width,
            AVVideoHeightKey: configuration.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoExpectedSourceFrameRateKey: configuration.framesPerSecond,
                AVVideoMaxKeyFrameIntervalKey: configuration.framesPerSecond * 2
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw RecorderError.captureFailed("Screen video encoder is unavailable.") }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if configuration.capturesSystemAudio {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecorderError.captureFailed("System audio encoder is unavailable.") }
            writer.add(input)
            audioInput = input
        }

        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = configuration.width
        streamConfiguration.height = configuration.height
        streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(configuration.framesPerSecond))
        streamConfiguration.queueDepth = 6
        streamConfiguration.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfiguration.showsCursor = true
        streamConfiguration.capturesAudio = configuration.capturesSystemAudio
        streamConfiguration.excludesCurrentProcessAudio = true
        streamConfiguration.sampleRate = 48_000
        streamConfiguration.channelCount = 2
        if configuration.screenTarget == .region, let region = configuration.region {
            streamConfiguration.sourceRect = region.cgRect
        }

        let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if configuration.capturesSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }

        var micURL: URL?
        if configuration.capturesMicrophone {
            let url = workingDirectory.appendingPathComponent("microphone.m4a")
            let microphoneWriter = MicrophoneWriter()
            try await microphoneWriter.start(deviceID: configuration.microphoneID, outputURL: url)
            self.microphoneWriter = microphoneWriter
            micURL = url
        }

        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.stream = stream
        self.writerStarted = false
        let artifacts = CaptureArtifacts(primaryMediaURL: sourceURL, microphoneStemURL: micURL)
        self.artifacts = artifacts
        try await stream.startCapture()
        return artifacts
    }

    public func stop() async throws -> CaptureArtifacts {
        guard let stream, let writer, var artifacts else {
            throw RecorderError.invalidState("Screen recording is not running.")
        }
        try await stream.stopCapture()
        if let microphoneWriter {
            artifacts.microphoneStemURL = try await microphoneWriter.stop()
        }

        lock.lock()
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        lock.unlock()
        try await writer.finishWritingAsync()

        self.stream = nil
        self.writer = nil
        self.videoInput = nil
        self.audioInput = nil
        self.microphoneWriter = nil
        self.artifacts = nil
        return artifacts
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        // The coordinator observes writer failure when stop/finalization is attempted.
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let writer else { return }

        if !writerStarted, outputType == .screen {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            writerStarted = true
        }
        guard writerStarted else { return }
        switch outputType {
        case .screen where videoInput?.isReadyForMoreMediaData == true:
            videoInput?.append(sampleBuffer)
        case .audio where audioInput?.isReadyForMoreMediaData == true:
            audioInput?.append(sampleBuffer)
        default:
            break
        }
    }
}
