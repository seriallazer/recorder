import Foundation
import AVFoundation

public final class CameraCaptureService: NSObject, RecordingCapturing, AudioLevelProviding, AVCaptureFileOutputRecordingDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    public let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "Recorder.CameraCapture")
    private let levelLock = NSLock()
    private var latestLevel: Float = 0
    private var outputURL: URL?
    private var stopContinuation: CheckedContinuation<Result<URL, Error>, Never>?

    public override init() {
        super.init()
    }

    public var audioLevel: Float {
        levelLock.lock()
        defer { levelLock.unlock() }
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

        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                do {
                    try camera.lockForConfiguration()
                    let requestedFPS = Double(configuration.framesPerSecond)
                    if camera.activeFormat.videoSupportedFrameRateRanges.contains(where: {
                        $0.minFrameRate <= requestedFPS && $0.maxFrameRate >= requestedFPS
                    }) {
                        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(configuration.framesPerSecond))
                        camera.activeVideoMinFrameDuration = frameDuration
                        camera.activeVideoMaxFrameDuration = frameDuration
                    }
                    camera.unlockForConfiguration()

                    self.session.beginConfiguration()
                    self.session.sessionPreset = configuration.width >= 1920 ? .hd1920x1080 : .hd1280x720
                    let cameraInput = try AVCaptureDeviceInput(device: camera)
                    guard self.session.canAddInput(cameraInput) else {
                        throw RecorderError.captureFailed("The selected camera cannot be used.")
                    }
                    self.session.addInput(cameraInput)
                    if configuration.capturesMicrophone, let microphone {
                        let microphoneInput = try AVCaptureDeviceInput(device: microphone)
                        if self.session.canAddInput(microphoneInput) { self.session.addInput(microphoneInput) }
                    }
                    guard self.session.canAddOutput(self.movieOutput) else {
                        throw RecorderError.captureFailed("Movie output could not be configured.")
                    }
                    self.session.addOutput(self.movieOutput)
                    self.movieOutput.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
                    self.movieOutput.minFreeDiskSpaceLimit = 500 * 1_024 * 1_024
                    if configuration.capturesMicrophone {
                        let meterOutput = AVCaptureAudioDataOutput()
                        meterOutput.setSampleBufferDelegate(self, queue: self.sessionQueue)
                        if self.session.canAddOutput(meterOutput) { self.session.addOutput(meterOutput) }
                    }
                    self.session.commitConfiguration()
                    self.session.startRunning()
                    continuation.resume()
                } catch {
                    self.session.commitConfiguration()
                    continuation.resume(throwing: error)
                }
            }
        }

        let url = workingDirectory.appendingPathComponent("camera-source.mov")
        try? FileManager.default.removeItem(at: url)
        outputURL = url
        movieOutput.startRecording(to: url, recordingDelegate: self)
        return CaptureArtifacts(primaryMediaURL: url)
    }

    public func stop() async throws -> CaptureArtifacts {
        guard movieOutput.isRecording, let outputURL else {
            throw RecorderError.invalidState("Movie recording is not running.")
        }
        let result = await withCheckedContinuation { continuation in
            stopContinuation = continuation
            movieOutput.stopRecording()
        }
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                self.session.stopRunning()
                self.session.inputs.forEach(self.session.removeInput)
                self.session.outputs.forEach(self.session.removeOutput)
                continuation.resume()
            }
        }
        levelLock.lock()
        latestLevel = 0
        levelLock.unlock()
        self.outputURL = nil
        return CaptureArtifacts(primaryMediaURL: try result.get())
    }

    public func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        if let error {
            stopContinuation?.resume(returning: .failure(error))
        } else {
            stopContinuation?.resume(returning: .success(outputFileURL))
        }
        stopContinuation = nil
    }

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let value = AudioLevelMeter.normalizedLevel(from: sampleBuffer)
        levelLock.lock()
        latestLevel = value
        levelLock.unlock()
    }
}
