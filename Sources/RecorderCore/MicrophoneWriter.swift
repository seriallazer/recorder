import Foundation
import AVFoundation

final class MicrophoneWriter: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let queue = DispatchQueue(label: "Recorder.MicrophoneWriter")
    private let session = AVCaptureSession()
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var startedSession = false
    private var outputURL: URL?
    private let levelLock = NSLock()
    private var latestLevel: Float = 0

    var audioLevel: Float {
        levelLock.lock()
        defer { levelLock.unlock() }
        return latestLevel
    }

    func start(deviceID: String?, outputURL: URL) async throws {
        guard await PermissionManager.requestMicrophone() else {
            throw RecorderError.permissionDenied("microphone")
        }
        let device = deviceID.flatMap { AVCaptureDevice(uniqueID: $0) }
            ?? AVCaptureDevice.default(for: .audio)
        guard let device else { throw RecorderError.missingDevice("microphone") }

        var didCommitConfiguration = false
        session.beginConfiguration()
        defer {
            if !didCommitConfiguration {
                session.commitConfiguration()
            }
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw RecorderError.captureFailed("The selected microphone cannot be added to the capture session.")
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            throw RecorderError.captureFailed("Audio output could not be configured.")
        }
        session.addOutput(output)
        session.commitConfiguration()
        didCommitConfiguration = true

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000
        ]
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        writerInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(writerInput) else {
            throw RecorderError.captureFailed("Audio encoder could not be configured.")
        }
        writer.add(writerInput)
        self.writer = writer
        self.writerInput = writerInput
        self.outputURL = outputURL
        startedSession = false

        await withCheckedContinuation { continuation in
            queue.async {
                self.session.startRunning()
                continuation.resume()
            }
        }
    }

    func stop() async throws -> URL {
        guard let writer, let writerInput, let outputURL else {
            throw RecorderError.invalidState("Microphone capture is not running.")
        }
        await withCheckedContinuation { continuation in
            queue.async {
                self.session.stopRunning()
                writerInput.markAsFinished()
                continuation.resume()
            }
        }
        try await writer.finishWritingAsync()
        reset()
        return outputURL
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let level = AudioLevelMeter.normalizedLevel(from: sampleBuffer)
        levelLock.lock()
        latestLevel = level
        levelLock.unlock()
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let writer,
              let writerInput else { return }
        if !startedSession {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            startedSession = true
        }
        if writerInput.isReadyForMoreMediaData {
            writerInput.append(sampleBuffer)
        }
    }

    private func reset() {
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        writer = nil
        writerInput = nil
        outputURL = nil
        startedSession = false
        levelLock.lock()
        latestLevel = 0
        levelLock.unlock()
    }
}

extension AVAssetWriter {
    func finishWritingAsync() async throws {
        try await withCheckedThrowingContinuation { continuation in
            finishWriting {
                if self.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: self.error ?? RecorderError.finalizationFailed("The media writer did not complete."))
                }
            }
        }
    }
}
