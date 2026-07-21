import Foundation
@preconcurrency import AVFoundation

public enum EchoCancellationPolicy {
    public static func shouldAttempt(
        configuration: CaptureConfiguration,
        defaultMicrophoneID: String?
    ) -> Bool {
        guard configuration.echoCancellationMode == .automatic,
              configuration.mode != .screen,
              configuration.capturesSystemAudio,
              configuration.capturesMicrophone,
              let defaultMicrophoneID else { return false }
        return configuration.microphoneID == nil
            || configuration.microphoneID == defaultMicrophoneID
    }
}

private protocol MicrophoneWriting: AnyObject {
    var audioLevel: Float { get }
    func start(deviceID: String?, outputURL: URL) async throws
    func stop() async throws -> URL
}

final class MicrophoneWriter {
    private var backend: (any MicrophoneWriting)?
    private(set) var appliedEchoCancellation = false

    var audioLevel: Float { backend?.audioLevel ?? 0 }

    func start(
        configuration: CaptureConfiguration,
        outputURL: URL
    ) async throws {
        let defaultMicrophoneID = AVCaptureDevice.default(for: .audio)?.uniqueID
        if EchoCancellationPolicy.shouldAttempt(
            configuration: configuration,
            defaultMicrophoneID: defaultMicrophoneID
        ) {
            let processed = VoiceProcessedMicrophoneWriter()
            do {
                try await processed.start(
                    deviceID: configuration.microphoneID,
                    outputURL: outputURL
                )
                backend = processed
                appliedEchoCancellation = true
                return
            } catch {
                // Voice processing depends on the current hardware route. A
                // failure must never prevent recording or disturb finalization.
            }
        }

        let raw = RawMicrophoneWriter()
        try await raw.start(
            deviceID: configuration.microphoneID,
            outputURL: outputURL
        )
        backend = raw
        appliedEchoCancellation = false
    }

    func stop() async throws -> URL {
        guard let backend else {
            throw RecorderError.invalidState("Microphone capture is not running.")
        }
        defer {
            self.backend = nil
            appliedEchoCancellation = false
        }
        return try await backend.stop()
    }
}

private final class VoiceProcessedMicrophoneWriter: MicrophoneWriting {
    private let levelLock = NSLock()
    private let errorLock = NSLock()
    private var latestLevel: Float = 0
    private var writeError: Error?
    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var outputURL: URL?
    private var tapInstalled = false

    var audioLevel: Float {
        levelLock.lock()
        defer { levelLock.unlock() }
        return latestLevel
    }

    func start(deviceID: String?, outputURL: URL) async throws {
        guard await PermissionManager.requestMicrophone() else {
            throw RecorderError.permissionDenied("microphone")
        }
        guard let defaultDevice = AVCaptureDevice.default(for: .audio),
              deviceID == nil || deviceID == defaultDevice.uniqueID else {
            throw RecorderError.captureFailed(
                "Echo cancellation requires the Mac's default microphone."
            )
        }

        try? FileManager.default.removeItem(at: outputURL)
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        do {
            try inputNode.setVoiceProcessingEnabled(true)
            inputNode.isVoiceProcessingAGCEnabled = false
            inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                    enableAdvancedDucking: false,
                    duckingLevel: .min
                )

            let inputFormat = inputNode.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw RecorderError.captureFailed(
                    "The voice-processed microphone format is unavailable."
                )
            }
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: inputFormat.sampleRate,
                AVNumberOfChannelsKey: Int(inputFormat.channelCount),
                AVEncoderBitRateKey: 128_000
            ]
            let audioFile = try AVAudioFile(
                forWriting: outputURL,
                settings: settings,
                commonFormat: inputFormat.commonFormat,
                interleaved: inputFormat.isInterleaved
            )
            let recordingFormat = audioFile.processingFormat

            self.engine = engine
            self.audioFile = audioFile
            self.outputURL = outputURL
            writeError = nil

            inputNode.installTap(
                onBus: 0,
                bufferSize: 1_024,
                format: recordingFormat
            ) { [weak self] buffer, _ in
                self?.consume(buffer)
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
        } catch {
            cleanup(removeOutput: true)
            throw error
        }
    }

    func stop() async throws -> URL {
        guard let engine, let outputURL else {
            throw RecorderError.invalidState(
                "Voice-processed microphone capture is not running."
            )
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        audioFile = nil // Closes and finalizes the encoded M4A container.

        let finalWriteError = capturedWriteError()
        cleanup(removeOutput: false)
        if let finalWriteError { throw finalWriteError }
        return outputURL
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        let level = AudioLevelMeter.normalizedLevel(from: buffer)
        levelLock.lock()
        latestLevel = level
        levelLock.unlock()

        do {
            try audioFile?.write(from: buffer)
        } catch {
            errorLock.lock()
            if writeError == nil { writeError = error }
            errorLock.unlock()
        }
    }

    private func capturedWriteError() -> Error? {
        errorLock.lock()
        defer { errorLock.unlock() }
        return writeError
    }

    private func cleanup(removeOutput: Bool) {
        if let engine {
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            engine.stop()
            try? engine.inputNode.setVoiceProcessingEnabled(false)
        }
        audioFile = nil
        engine = nil
        if removeOutput, let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        self.outputURL = nil
        writeError = nil
        levelLock.lock()
        latestLevel = 0
        levelLock.unlock()
    }
}

private final class RawMicrophoneWriter: NSObject, MicrophoneWriting,
    AVCaptureAudioDataOutputSampleBufferDelegate {
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
            throw RecorderError.captureFailed(
                "The selected microphone cannot be added to the capture session."
            )
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
        let writerInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: settings
        )
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

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let level = AudioLevelMeter.normalizedLevel(from: sampleBuffer)
        levelLock.lock()
        latestLevel = level
        levelLock.unlock()
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let writer,
              let writerInput else { return }
        if !startedSession {
            guard writer.startWriting() else { return }
            writer.startSession(
                atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            )
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
                    continuation.resume(
                        throwing: self.error
                            ?? RecorderError.finalizationFailed(
                                "The media writer did not complete."
                            )
                    )
                }
            }
        }
    }
}
