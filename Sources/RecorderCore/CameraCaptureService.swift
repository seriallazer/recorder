import Foundation
import AVFoundation

public final class CameraCaptureService: NSObject, RecordingCapturing, AudioLevelProviding, AVCaptureFileOutputRecordingDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    public let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "Recorder.CameraCapture")
    private let levelLock = NSLock()
    private var latestLevel: Float = 0
    private var outputURL: URL?
    private let recordingStateLock = NSLock()
    private var stopContinuation: CheckedContinuation<Result<URL, Error>, Never>?
    private var completedRecordingResult: Result<URL, Error>?

    public override init() {
        super.init()
    }

    public var audioLevel: Float {
        levelLock.lock()
        defer { levelLock.unlock() }
        return latestLevel
    }

    public func start(configuration: CaptureConfiguration, workingDirectory: URL) async throws -> CaptureArtifacts {
        guard !movieOutput.isRecording else {
            throw RecorderError.invalidState("Camera recording is already running.")
        }
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
                var sessionConfigurationBegun = false
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
                    sessionConfigurationBegun = true
                    self.session.sessionPreset = configuration.width >= 1920 ? .hd1920x1080 : .hd1280x720
                    let cameraInput = try AVCaptureDeviceInput(device: camera)
                    guard self.session.canAddInput(cameraInput) else {
                        throw RecorderError.captureFailed("The selected camera cannot be used.")
                    }
                    self.session.addInput(cameraInput)
                    if configuration.capturesMicrophone, let microphone {
                        let microphoneInput = try AVCaptureDeviceInput(device: microphone)
                        guard self.session.canAddInput(microphoneInput) else {
                            throw RecorderError.captureFailed("The selected microphone cannot be used with the camera.")
                        }
                        self.session.addInput(microphoneInput)
                    }
                    guard self.session.canAddOutput(self.movieOutput) else {
                        throw RecorderError.captureFailed("Movie output could not be configured.")
                    }
                    self.session.addOutput(self.movieOutput)
                    self.movieOutput.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
                    self.movieOutput.minFreeDiskSpaceLimit = 500 * 1_024 * 1_024
                    self.session.commitConfiguration()
                    sessionConfigurationBegun = false
                    self.session.startRunning()
                    continuation.resume()
                } catch {
                    if sessionConfigurationBegun {
                        self.session.commitConfiguration()
                    }
                    self.session.inputs.forEach(self.session.removeInput)
                    self.session.outputs.forEach(self.session.removeOutput)
                    continuation.resume(throwing: error)
                }
            }
        }

        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let url = workingDirectory.appendingPathComponent("camera-source.mov")
        try? FileManager.default.removeItem(at: url)
        outputURL = url
        resetCompletedRecordingResult()
        movieOutput.startRecording(to: url, recordingDelegate: self)
        do {
            try await waitUntilRecordingStarts()
        } catch {
            await stopSession()
            self.outputURL = nil
            throw error
        }
        return CaptureArtifacts(primaryMediaURL: url)
    }

    public func stop() async throws -> CaptureArtifacts {
        guard let outputURL else {
            throw RecorderError.invalidState("Movie recording is not running.")
        }
        // AVCaptureMovieFileOutput can finish asynchronously before the UI's
        // stop action observes `isRecording == false`. If the file is complete,
        // it is still a valid capture and should proceed to finalization.
        if !movieOutput.isRecording {
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                if movieOutput.isRecording { break }
            }
        }
        if !movieOutput.isRecording {
            guard FileManager.default.fileExists(atPath: outputURL.path) else {
                throw RecorderError.invalidState("Movie recording is not running.")
            }
            await stopSession()
            self.outputURL = nil
            return CaptureArtifacts(primaryMediaURL: outputURL)
        }
        let result = await withCheckedContinuation { continuation in
            recordingStateLock.lock()
            if let completedRecordingResult {
                self.completedRecordingResult = nil
                recordingStateLock.unlock()
                continuation.resume(returning: completedRecordingResult)
            } else {
                stopContinuation = continuation
                recordingStateLock.unlock()
                movieOutput.stopRecording()
            }
        }
        await stopSession()
        resetAudioLevel()
        self.outputURL = nil
        return CaptureArtifacts(primaryMediaURL: try result.get())
    }

    private func waitUntilRecordingStarts() async throws {
        for _ in 0..<100 {
            if movieOutput.isRecording { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw RecorderError.captureFailed("The camera did not start recording.")
    }

    private func stopSession() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                self.session.stopRunning()
                self.session.inputs.forEach(self.session.removeInput)
                self.session.outputs.forEach(self.session.removeOutput)
                continuation.resume()
            }
        }
    }

    private func resetCompletedRecordingResult() {
        recordingStateLock.lock()
        completedRecordingResult = nil
        recordingStateLock.unlock()
    }

    private func resetAudioLevel() {
        levelLock.lock()
        latestLevel = 0
        levelLock.unlock()
    }

    public func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        let recordingFinishedSuccessfully = (error as NSError?)?
            .userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true
        let result: Result<URL, Error>
        if let error, !recordingFinishedSuccessfully {
            result = .failure(error)
        } else {
            result = .success(outputFileURL)
        }

        recordingStateLock.lock()
        if let stopContinuation {
            self.stopContinuation = nil
            recordingStateLock.unlock()
            stopContinuation.resume(returning: result)
        } else {
            completedRecordingResult = result
            recordingStateLock.unlock()
        }
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
