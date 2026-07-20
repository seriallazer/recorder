import Foundation
import CoreGraphics

public enum RecordingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case audio
    case camera
    case screen

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .audio: "Audio"
        case .camera: "Movie"
        case .screen: "Screen"
        }
    }
}

public enum RecordingState: String, Codable, Sendable {
    case idle
    case previewing
    case recording
    case finalizing
    case ready
    case transcribing
    case failed
}

public enum ScreenTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    case display
    case window
    case region

    public var id: Self { self }
}

public enum TranscriptSource: String, Codable, Sendable {
    case microphone
    case system
    case mixed
}

public enum SpeakerAttribution: String, Codable, Sendable {
    case singleTrack
    case channelSeparated
    case enhancedDiarization
    case stableFallback

    public var displayName: String {
        switch self {
        case .singleTrack: "Single-speaker label"
        case .channelSeparated: "Separate audio channels"
        case .enhancedDiarization: "Enhanced model diarization"
        case .stableFallback: "Stable fallback labels"
        }
    }
}

public enum DiarizationMode: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case stable
    case enhanced

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .automatic: "Auto"
        case .stable: "Stable"
        case .enhanced: "Enhanced"
        }
    }
}

public enum EchoCancellationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case off

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .automatic: "Auto"
        case .off: "Off"
        }
    }
}

public struct DiarizationOptions: Hashable, Sendable {
    public var mode: DiarizationMode
    public var expectedSpeakerCount: Int

    public init(mode: DiarizationMode = .automatic, expectedSpeakerCount: Int = 2) {
        self.mode = mode
        self.expectedSpeakerCount = min(max(expectedSpeakerCount, 2), 6)
    }

    public init(isEnabled: Bool, expectedSpeakerCount: Int = 2) {
        self.init(mode: isEnabled ? .enhanced : .stable, expectedSpeakerCount: expectedSpeakerCount)
    }

    public static let automatic = DiarizationOptions(mode: .automatic)
    public static let stable = DiarizationOptions(mode: .stable)
}

public enum RecorderPreferences {
    public static let diarizationModeKey = "SpeakerDiarizationMode"
    public static let expectedSpeakerCountKey = "ExpectedSpeakerCount"
    public static let echoCancellationModeKey = "EchoCancellationMode"

    public static func diarizationOptions(defaults: UserDefaults = .standard) -> DiarizationOptions {
        let count = defaults.integer(forKey: expectedSpeakerCountKey)
        let mode = defaults.string(forKey: diarizationModeKey)
            .flatMap(DiarizationMode.init(rawValue:))
            ?? .automatic
        return DiarizationOptions(
            mode: mode,
            expectedSpeakerCount: count == 0 ? 2 : count
        )
    }

    public static func echoCancellationMode(
        defaults: UserDefaults = .standard
    ) -> EchoCancellationMode {
        defaults.string(forKey: echoCancellationModeKey)
            .flatMap(EchoCancellationMode.init(rawValue:))
            ?? .automatic
    }
}

public struct CaptureRegion: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

public struct CaptureConfiguration: Codable, Hashable, Sendable {
    public var mode: RecordingMode
    public var microphoneID: String?
    public var cameraID: String?
    public var displayID: UInt32?
    public var windowID: UInt32?
    public var screenTarget: ScreenTarget
    public var region: CaptureRegion?
    public var capturesSystemAudio: Bool
    public var capturesMicrophone: Bool
    public var echoCancellationMode: EchoCancellationMode?
    public var width: Int
    public var height: Int
    public var framesPerSecond: Int

    public init(
        mode: RecordingMode,
        microphoneID: String? = nil,
        cameraID: String? = nil,
        displayID: UInt32? = nil,
        windowID: UInt32? = nil,
        screenTarget: ScreenTarget = .display,
        region: CaptureRegion? = nil,
        capturesSystemAudio: Bool = true,
        capturesMicrophone: Bool = true,
        echoCancellationMode: EchoCancellationMode? = nil,
        width: Int = 1920,
        height: Int = 1080,
        framesPerSecond: Int = 30
    ) {
        self.mode = mode
        self.microphoneID = microphoneID
        self.cameraID = cameraID
        self.displayID = displayID
        self.windowID = windowID
        self.screenTarget = screenTarget
        self.region = region
        self.capturesSystemAudio = capturesSystemAudio
        self.capturesMicrophone = capturesMicrophone
        self.echoCancellationMode = echoCancellationMode
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
    }
}

public struct RecordingManifest: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var tag: String?
    public var organizationPath: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var mode: RecordingMode
    public var state: RecordingState
    public var duration: TimeInterval
    public var trimStart: TimeInterval
    public var trimEnd: TimeInterval?
    public var mediaFile: String?
    public var audioFile: String?
    public var microphoneStemFile: String?
    public var systemStemFile: String?
    public var transcriptFile: String?
    public var thumbnailFile: String?
    public var speakerCount: Int?
    public var echoCancellationApplied: Bool?
    public var errorMessage: String?
    public var configuration: CaptureConfiguration

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        mode: RecordingMode,
        state: RecordingState = .idle,
        configuration: CaptureConfiguration
    ) {
        self.id = id
        self.title = title
        self.tag = nil
        self.organizationPath = nil
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.mode = mode
        self.state = state
        self.duration = 0
        self.trimStart = 0
        self.echoCancellationApplied = nil
        self.configuration = configuration
    }

    public var effectiveTrimEnd: TimeInterval {
        min(max(trimEnd ?? duration, trimStart), duration)
    }

    public func fileURL(for relativePath: String?, in folder: URL) -> URL? {
        relativePath.map { folder.appendingPathComponent($0) }
    }
}

public struct TranscriptSegment: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var speaker: String
    public var text: String
    public var confidence: Double?
    public var source: TranscriptSource
    public var isOverlapping: Bool

    public init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        speaker: String,
        text: String,
        confidence: Double? = nil,
        source: TranscriptSource = .mixed,
        isOverlapping: Bool = false
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.speaker = speaker
        self.text = text
        self.confidence = confidence
        self.source = source
        self.isOverlapping = isOverlapping
    }
}

public struct TranscriptDocument: Codable, Hashable, Sendable {
    public var recordingID: UUID
    public var generatedAt: Date
    public var speakerCount: Int
    public var speakerAttribution: SpeakerAttribution?
    public var attributionNote: String?
    public var segments: [TranscriptSegment]

    public init(
        recordingID: UUID,
        generatedAt: Date = Date(),
        speakerCount: Int,
        speakerAttribution: SpeakerAttribution? = nil,
        attributionNote: String? = nil,
        segments: [TranscriptSegment]
    ) {
        self.recordingID = recordingID
        self.generatedAt = generatedAt
        self.speakerCount = speakerCount
        self.speakerAttribution = speakerAttribution
        self.attributionNote = attributionNote
        self.segments = segments.sorted { $0.startTime < $1.startTime }
    }

    public func plainText(trimStart: TimeInterval = 0, trimEnd: TimeInterval? = nil) -> String {
        let end = trimEnd ?? .greatestFiniteMagnitude
        let visible = segments.filter { $0.endTime >= trimStart && $0.startTime <= end }
        let body = visible.map { segment in
            let shifted = max(0, segment.startTime - trimStart)
            let overlap = segment.isOverlapping ? " [overlapping speech]" : ""
            return "[\(Self.timestamp(shifted))] \(segment.speaker): \(segment.text)\(overlap)"
        }.joined(separator: "\n")
        var header = ["Speakers detected: \(speakerCount)"]
        if let speakerAttribution {
            header.append("Speaker attribution: \(speakerAttribution.displayName)")
        }
        if let attributionNote, !attributionNote.isEmpty {
            header.append("Note: \(attributionNote)")
        }
        return "\(header.joined(separator: "\n"))\n\n\(body)\n"
    }

    public static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

public struct CaptureArtifacts: Sendable {
    public var primaryMediaURL: URL
    public var microphoneStemURL: URL?
    public var systemStemURL: URL?
    public var echoCancellationApplied: Bool?

    public init(
        primaryMediaURL: URL,
        microphoneStemURL: URL? = nil,
        systemStemURL: URL? = nil,
        echoCancellationApplied: Bool? = nil
    ) {
        self.primaryMediaURL = primaryMediaURL
        self.microphoneStemURL = microphoneStemURL
        self.systemStemURL = systemStemURL
        self.echoCancellationApplied = echoCancellationApplied
    }
}

public struct FinalizedMedia: Sendable {
    public var mediaURL: URL
    public var audioURL: URL
    public var microphoneStemURL: URL?
    public var systemStemURL: URL?
    public var duration: TimeInterval

    public var echoCancellationApplied: Bool?

    public init(
        mediaURL: URL,
        audioURL: URL,
        microphoneStemURL: URL?,
        systemStemURL: URL?,
        duration: TimeInterval,
        echoCancellationApplied: Bool? = nil
    ) {
        self.mediaURL = mediaURL
        self.audioURL = audioURL
        self.microphoneStemURL = microphoneStemURL
        self.systemStemURL = systemStemURL
        self.duration = duration
        self.echoCancellationApplied = echoCancellationApplied
    }
}

public struct MediaDevice: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct ScreenSource: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case display, window }
    public var id: UInt32
    public var name: String
    public var kind: Kind

    public init(id: UInt32, name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}
