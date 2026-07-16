import Foundation
@preconcurrency import AVFoundation

public final class CameraCaptureService: NSObject, RecordingCapturing, AudioLevelProviding, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    public let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "Recorder.CameraCapture", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private var audioOutput: AVCaptureAudioDataOutput?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var writerStarted = false
    private var writerSessionStartTime: CMTime?
    private var writerStartError: Error?
    private let stateLock = NSLock()
    private var latestLevel: Float = 0

    public override init() {
        super.init()
    }

    public var audioLevel: Float {
        stateLock.lock()
        defer { stateLock.unlock() }
        return latestLevel
    }

    public func start(configuration: CaptureConfiguration, workingDirectory: URL) async throws -> CaptureArtifacts {
        guard await PermissionManager.requestCamera() else {
            throw RecorderError.permissionDenied("camera")
        }
        if configuration.capturesMicrophone, !(await PermissionManager.requestMicrophone()) {
            throw RecorderError.permissionDenied("microphone")
        }

        let camera = configuration.cameraID.flatMap { AVCaptureDevice(uniqueID: $0) }
            ?? AVCaptureDevice.default(for: .video)
        guard let camera else { throw RecorderError.missingDevice("camera") }
        let microphone = configuration.microphoneID.flatMap { AVCaptureDevice(uniqueID: $0) }
            ?? AVCaptureDevice.default(for: .audio)

        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let url = workingDirectory.appendingPathComponent("camera-source.mov")
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
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
        guard writer.canAdd(videoInput) else {
            throw RecorderError.captureFailed("Camera video encoder is unavailable.")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if configuration.capturesMicrophone {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw RecorderError.captureFailed("Camera audio encoder is unavailable.")
            }
            writer.add(input)
            audioInput = input
        }

        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.outputURL = url
        setWriterState(started: false, error: nil)

        do {
            try await configureAndStartSession(
                camera: camera,
                microphone: microphone,
                configuration: configuration
            )
            try await waitUntilWriterStarts()
        } catch {
            await stopSessionAndRemoveConnections()
            writer.cancelWriting()
            resetWriterState()
            throw error
        }
        return CaptureArtifacts(primaryMediaURL: url)
    }

    public func stop() async throws -> CaptureArtifacts {
        guard let writer, let outputURL else {
            throw RecorderError.invalidState("Movie recording is not active.")
        }
        let (started, startError) = currentWriterState()
        guard started else {
            await stopSessionAndRemoveConnections()
            writer.cancelWriting()
            resetWriterState()
            throw startError ?? RecorderError.captureFailed("The camera did not produce a video frame.")
        }

        await stopSessionAndFinishInputs()
        guard writer.status == .writing || writer.status == .completed else {
            let error = writer.error ?? RecorderError.captureFailed("The camera writer stopped unexpectedly.")
            resetWriterState()
            throw error
        }
        if writer.status != .completed {
            try await writer.finishWritingAsync()
        }
        guard writer.status == .completed else {
            let error = writer.error ?? RecorderError.captureFailed("The movie could not be finalized.")
            resetWriterState()
            throw error
        }
        resetWriterState()
        return CaptureArtifacts(primaryMediaURL: outputURL)
    }

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer),
              let writer else { return }

        if output === videoOutput {
            if !writerStarted {
                guard writer.startWriting() else {
                    setWriterState(started: false, error: writer.error ?? RecorderError.captureFailed("Camera writer could not start."))
                    return
                }
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                writerSessionStartTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                setWriterState(started: true, error: nil)
            }
            if videoInput?.isReadyForMoreMediaData == true,
               videoInput?.append(sampleBuffer) == false {
                setWriterState(started: true, error: writer.error)
            }
        } else if output === audioOutput {
            let level = AudioLevelMeter.normalizedLevel(from: sampleBuffer)
            stateLock.lock()
            latestLevel = level
            stateLock.unlock()
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if writerStarted,
               let writerSessionStartTime,
               CMTimeCompare(presentationTime, writerSessionStartTime) >= 0,
               audioInput?.isReadyForMoreMediaData == true,
               audioInput?.append(sampleBuffer) == false {
                setWriterState(started: true, error: writer.error)
            }
        }
    }

    private func configureAndStartSession(
        camera: AVCaptureDevice,
        microphone: AVCaptureDevice?,
        configuration: CaptureConfiguration
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                var configurationBegun = false
                do {
                    try camera.lockForConfiguration()
                    let requestedFPS = Double(configuration.framesPerSecond)
                    if camera.activeFormat.videoSupportedFrameRateRanges.contains(where: {
                        $0.minFrameRate <= requestedFPS && $0.maxFrameRate >= requestedFPS
                    }) {
                        let duration = CMTime(value: 1, timescale: CMTimeScale(configuration.framesPerSecond))
                        camera.activeVideoMinFrameDuration = duration
                        camera.activeVideoMaxFrameDuration = duration
                    }
                    camera.unlockForConfiguration()

                    self.session.beginConfiguration()
                    configurationBegun = true
                    self.session.sessionPreset = configuration.width >= 1920 ? .hd1920x1080 : .hd1280x720

                    let cameraInput = try AVCaptureDeviceInput(device: camera)
                    guard self.session.canAddInput(cameraInput) else {
                        throw RecorderError.captureFailed("The selected camera cannot be used.")
                    }
                    self.session.addInput(cameraInput)

                    self.videoOutput.videoSettings = [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                    ]
                    self.videoOutput.alwaysDiscardsLateVideoFrames = true
                    self.videoOutput.setSampleBufferDelegate(self, queue: self.sessionQueue)
                    guard self.session.canAddOutput(self.videoOutput) else {
                        throw RecorderError.captureFailed("Camera video output could not be configured.")
                    }
                    self.session.addOutput(self.videoOutput)

                    if configuration.capturesMicrophone {
                        guard let microphone else { throw RecorderError.missingDevice("microphone") }
                        let microphoneInput = try AVCaptureDeviceInput(device: microphone)
                        guard self.session.canAddInput(microphoneInput) else {
                            throw RecorderError.captureFailed("The selected microphone cannot be used with the camera.")
                        }
                        self.session.addInput(microphoneInput)
                        let audioOutput = AVCaptureAudioDataOutput()
                        audioOutput.setSampleBufferDelegate(self, queue: self.sessionQueue)
                        guard self.session.canAddOutput(audioOutput) else {
                            throw RecorderError.captureFailed("Camera audio output could not be configured.")
                        }
                        self.session.addOutput(audioOutput)
                        self.audioOutput = audioOutput
                    }

                    self.session.commitConfiguration()
                    configurationBegun = false
                    self.session.startRunning()
                    continuation.resume()
                } catch {
                    if configurationBegun { self.session.commitConfiguration() }
                    self.session.inputs.forEach(self.session.removeInput)
                    self.session.outputs.forEach(self.session.removeOutput)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func waitUntilWriterStarts() async throws {
        for _ in 0..<100 {
            let (started, error) = currentWriterState()
            if let error { throw error }
            if started { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw RecorderError.captureFailed("The camera did not produce a video frame.")
    }

    private func stopSessionAndFinishInputs() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                self.session.stopRunning()
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                self.session.inputs.forEach(self.session.removeInput)
                self.session.outputs.forEach(self.session.removeOutput)
                continuation.resume()
            }
        }
    }

    private func stopSessionAndRemoveConnections() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                if self.session.isRunning { self.session.stopRunning() }
                self.session.inputs.forEach(self.session.removeInput)
                self.session.outputs.forEach(self.session.removeOutput)
                continuation.resume()
            }
        }
    }

    private func setWriterState(started: Bool, error: Error?) {
        stateLock.lock()
        writerStarted = started
        writerStartError = error
        stateLock.unlock()
    }

    private func currentWriterState() -> (Bool, Error?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (writerStarted, writerStartError)
    }

    private func resetWriterState() {
        stateLock.lock()
        writerStarted = false
        writerStartError = nil
        latestLevel = 0
        stateLock.unlock()
        writer = nil
        videoInput = nil
        audioInput = nil
        audioOutput = nil
        writerSessionStartTime = nil
        outputURL = nil
    }
}
