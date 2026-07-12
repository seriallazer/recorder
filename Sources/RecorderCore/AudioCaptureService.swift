import Foundation

public final class AudioCaptureService: RecordingCapturing, AudioLevelProviding {
    private let microphoneWriter = MicrophoneWriter()
    private var artifacts: CaptureArtifacts?

    public init() {}

    public var audioLevel: Float { microphoneWriter.audioLevel }

    public func start(configuration: CaptureConfiguration, workingDirectory: URL) async throws -> CaptureArtifacts {
        guard artifacts == nil else { throw RecorderError.invalidState("Audio recording is already running.") }
        let url = workingDirectory.appendingPathComponent("microphone.m4a")
        try await microphoneWriter.start(deviceID: configuration.microphoneID, outputURL: url)
        let artifacts = CaptureArtifacts(primaryMediaURL: url, microphoneStemURL: url)
        self.artifacts = artifacts
        return artifacts
    }

    public func stop() async throws -> CaptureArtifacts {
        guard var artifacts else { throw RecorderError.invalidState("Audio recording is not running.") }
        artifacts.primaryMediaURL = try await microphoneWriter.stop()
        self.artifacts = nil
        return artifacts
    }
}
