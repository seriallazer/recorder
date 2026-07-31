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

enum MicrophoneEncodingProfile {
    static func aacSettings(for device: AVCaptureDevice?) -> [String: Any] {
        let description = device?.activeFormat.formatDescription
        let stream = description.flatMap {
            CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
        }
        let sampleRate = stream?.mSampleRate ?? 48_000
        let channelCount = max(1, Int(stream?.mChannelsPerFrame ?? 1))
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: channelCount > 1 ? 192_000 : 128_000
        ]
    }
}

private protocol MicrophoneWriting: AnyObject {
    var audioLevel: Float { get }
    var failureDescription: String? { get }
    func start(deviceID: String?, outputURL: URL) async throws
    func stop() async throws -> URL
}

final class MicrophoneWriter {
    private var backend: (any MicrophoneWriting)?
    private(set) var appliedEchoCancellation = false

    var audioLevel: Float { backend?.audioLevel ?? 0 }
    var failureDescription: String? { backend?.failureDescription }

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

    var failureDescription: String? {
        capturedWriteError()?.localizedDescription
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
    @unchecked Sendable,
    AVCaptureAudioDataOutputSampleBufferDelegate {
    private let queue = DispatchQueue(label: "Recorder.MicrophoneWriter")
    private let session = AVCaptureSession()
    private var audioOutput: AVCaptureAudioDataOutput?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var startedSession = false
    private var outputURL: URL?
    private let stateLock = NSLock()
    private var latestLevel: Float = 0
    private var appendedSampleCount = 0
    private var writerFailure: Error?

    var audioLevel: Float {
        stateLock.lock()
        defer { stateLock.unlock() }
        return latestLevel
    }

    var failureDescription: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return writerFailure?.localizedDescription
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
        // Use AVFoundation's settings for the active input format. The previous
        // fixed 48 kHz mono conversion can fail after capture has already
        // started when macOS supplies a different microphone channel layout.
        let settings = output.recommendedAudioSettingsForAssetWriter(
            writingTo: .m4a
        ) ?? MicrophoneEncodingProfile.aacSettings(for: device)
        let writerInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: settings,
            sourceFormatHint: device.activeFormat.formatDescription
        )
        writerInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(writerInput) else {
            throw RecorderError.captureFailed("Audio encoder could not be configured.")
        }
        writer.add(writerInput)
        self.writer = writer
        self.writerInput = writerInput
        self.audioOutput = output
        self.outputURL = outputURL
        startedSession = false
        setCaptureState(level: 0, appendedSampleCount: 0, failure: nil)

        do {
            await withCheckedContinuation { continuation in
                queue.async {
                    self.session.startRunning()
                    continuation.resume()
                }
            }
            try await waitUntilFirstSampleIsWritten()
        } catch {
            await stopSession()
            writer.cancelWriting()
            reset()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    func stop() async throws -> URL {
        guard let writer, let writerInput, let outputURL else {
            throw RecorderError.invalidState("Microphone capture is not running.")
        }
        await stopSession()
        defer { reset() }

        if writer.status == .writing {
            writerInput.markAsFinished()
            try await writer.finishWritingAsync()
        } else if writer.status != .completed {
            throw capturedFailure()
                ?? writer.error
                ?? RecorderError.captureFailed(
                    "The microphone encoder stopped unexpectedly."
                )
        }
        if let failure = capturedFailure() {
            throw failure
        }
        guard hasWrittenSamples(),
              (try? outputURL.resourceValues(
                forKeys: [.fileSizeKey]
              ).fileSize ?? 0) ?? 0 > 1_024 else {
            throw RecorderError.captureFailed(
                "The microphone did not produce a usable audio file."
            )
        }
        return outputURL
    }

    private func waitUntilFirstSampleIsWritten() async throws {
        for _ in 0..<100 {
            if let failure = capturedFailure() { throw failure }
            if hasWrittenSamples() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw RecorderError.captureFailed(
            "The microphone did not begin producing audio."
        )
    }

    private func stopSession() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.session.isRunning {
                    self.session.stopRunning()
                }
                continuation.resume()
            }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let level = AudioLevelMeter.normalizedLevel(from: sampleBuffer)
        stateLock.lock()
        latestLevel = level
        stateLock.unlock()
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let writer,
              let writerInput else { return }
        if writer.status == .failed {
            recordFailure(
                writer.error
                    ?? RecorderError.captureFailed(
                        "The microphone encoder stopped unexpectedly."
                    )
            )
            return
        }
        if !startedSession {
            guard writer.startWriting() else {
                recordFailure(
                    writer.error
                        ?? RecorderError.captureFailed(
                            "The microphone encoder could not start."
                        )
                )
                return
            }
            writer.startSession(
                atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            )
            startedSession = true
        }
        if writerInput.isReadyForMoreMediaData {
            if writerInput.append(sampleBuffer) {
                stateLock.lock()
                appendedSampleCount += 1
                stateLock.unlock()
            } else {
                recordFailure(
                    writer.error
                        ?? RecorderError.captureFailed(
                            "The microphone encoder rejected an audio sample."
                        )
                )
            }
        } else if writer.status == .failed {
            recordFailure(
                writer.error
                    ?? RecorderError.captureFailed(
                        "The microphone encoder stopped unexpectedly."
                    )
            )
        }
    }

    private func reset() {
        audioOutput?.setSampleBufferDelegate(nil, queue: nil)
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        audioOutput = nil
        writer = nil
        writerInput = nil
        outputURL = nil
        startedSession = false
        stateLock.lock()
        latestLevel = 0
        appendedSampleCount = 0
        writerFailure = nil
        stateLock.unlock()
    }

    private func hasWrittenSamples() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return appendedSampleCount > 0
    }

    private func capturedFailure() -> Error? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return writerFailure
    }

    private func recordFailure(_ error: Error) {
        stateLock.lock()
        if writerFailure == nil { writerFailure = error }
        stateLock.unlock()
    }

    private func setCaptureState(
        level: Float,
        appendedSampleCount: Int,
        failure: Error?
    ) {
        stateLock.lock()
        latestLevel = level
        self.appendedSampleCount = appendedSampleCount
        writerFailure = failure
        stateLock.unlock()
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
