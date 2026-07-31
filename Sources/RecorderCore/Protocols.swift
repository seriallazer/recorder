import Foundation
import AVFoundation

public protocol RecordingCapturing: AnyObject {
    func start(configuration: CaptureConfiguration, workingDirectory: URL) async throws -> CaptureArtifacts
    func stop() async throws -> CaptureArtifacts
}

public protocol AudioLevelProviding: AnyObject {
    var audioLevel: Float { get }
}

/// Capture services expose failures that can happen after `start` succeeds.
/// Real-time encoders report some format/device errors only after receiving
/// their first samples, so the coordinator must keep observing this value.
public protocol CaptureHealthProviding: AnyObject {
    var captureFailureDescription: String? { get }
}

public protocol MediaFinalizing: Sendable {
    func finalize(
        artifacts: CaptureArtifacts,
        configuration: CaptureConfiguration,
        destinationDirectory: URL
    ) async throws -> FinalizedMedia

    func exportTrimmed(
        sourceURL: URL,
        destinationURL: URL,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) async throws
}

public protocol Transcribing: Sendable {
    func transcribe(recording: RecordingManifest, folder: URL) async throws -> TranscriptDocument
}

public protocol ModelManaging: Sendable {
    var modelsAreAvailable: Bool { get async }
    func prepareModels() async throws
}

public enum RecorderError: LocalizedError {
    case permissionDenied(String)
    case missingDevice(String)
    case invalidState(String)
    case captureFailed(String)
    case finalizationFailed(String)
    case missingMedia
    case insufficientDiskSpace
    case modelUnavailable(String)
    case transcriptionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied(let resource): "Permission denied for \(resource)."
        case .missingDevice(let resource): "No \(resource) is available."
        case .invalidState(let message): message
        case .captureFailed(let message): "Recording failed: \(message)"
        case .finalizationFailed(let message): "Could not finalize recording: \(message)"
        case .missingMedia: "The recording media is missing."
        case .insufficientDiskSpace: "There is not enough free disk space to start recording."
        case .modelUnavailable(let message): "Local model is unavailable: \(message)"
        case .transcriptionFailed(let message): "Transcription failed: \(message)"
        }
    }
}
