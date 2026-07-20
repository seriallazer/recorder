import Foundation

public final class AudioCaptureService: RecordingCapturing, AudioLevelProviding {
    private var microphoneWriter: MicrophoneWriter?
    private var systemAudioWriter: SystemAudioWriter?
    private var artifacts: CaptureArtifacts?

    public init() {}

    public var audioLevel: Float { microphoneWriter?.audioLevel ?? 0 }

    public func start(configuration: CaptureConfiguration, workingDirectory: URL) async throws -> CaptureArtifacts {
        guard artifacts == nil else { throw RecorderError.invalidState("Audio recording is already running.") }
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        var microphoneURL: URL?
        var systemURL: URL?
        var echoCancellationApplied: Bool?

        if configuration.capturesSystemAudio {
            let url = workingDirectory.appendingPathComponent("system.m4a")
            let writer = SystemAudioWriter()
            try await writer.start(displayID: configuration.displayID, outputURL: url)
            systemAudioWriter = writer
            systemURL = url
        }
        do {
            if configuration.capturesMicrophone {
                let url = workingDirectory.appendingPathComponent("microphone.m4a")
                let writer = MicrophoneWriter()
                try await writer.start(configuration: configuration, outputURL: url)
                microphoneWriter = writer
                microphoneURL = url
                echoCancellationApplied = writer.appliedEchoCancellation
            }
        } catch {
            _ = try? await systemAudioWriter?.stop()
            systemAudioWriter = nil
            throw error
        }

        guard let primaryURL = microphoneURL ?? systemURL else {
            throw RecorderError.invalidState("Select microphone or system audio recording.")
        }
        let artifacts = CaptureArtifacts(
            primaryMediaURL: primaryURL,
            microphoneStemURL: microphoneURL,
            systemStemURL: systemURL,
            echoCancellationApplied: echoCancellationApplied
        )
        self.artifacts = artifacts
        return artifacts
    }

    public func stop() async throws -> CaptureArtifacts {
        guard var artifacts else { throw RecorderError.invalidState("Audio recording is not running.") }
        var firstError: Error?
        if let microphoneWriter {
            do {
                let url = try await microphoneWriter.stop()
                artifacts.microphoneStemURL = url
                artifacts.primaryMediaURL = url
            } catch {
                firstError = error
            }
        }
        if let systemAudioWriter {
            do {
                artifacts.systemStemURL = try await systemAudioWriter.stop()
                if artifacts.microphoneStemURL == nil, let system = artifacts.systemStemURL {
                    artifacts.primaryMediaURL = system
                }
            } catch {
                firstError = firstError ?? error
            }
        }
        microphoneWriter = nil
        systemAudioWriter = nil
        self.artifacts = nil
        if artifacts.microphoneStemURL == nil, artifacts.systemStemURL == nil, let firstError {
            throw firstError
        }
        return artifacts
    }
}
