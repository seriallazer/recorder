import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import AudioToolbox

public struct RecordingMetadata: Sendable, Equatable {
    public var logicalSize: Int64
    public var allocatedSize: Int64
    public var fileCount: Int
    public var latestModificationDate: Date?
    public var media: RecordingMediaMetadata?

    public init(
        logicalSize: Int64,
        allocatedSize: Int64,
        fileCount: Int,
        latestModificationDate: Date?,
        media: RecordingMediaMetadata?
    ) {
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.fileCount = fileCount
        self.latestModificationDate = latestModificationDate
        self.media = media
    }
}

public struct RecordingMediaMetadata: Sendable, Equatable {
    public var fileSize: Int64?
    public var duration: TimeInterval?
    public var width: Int?
    public var height: Int?
    public var frameRate: Double?
    public var videoCodec: String?
    public var audioCodec: String?
    public var audioSampleRate: Double?
    public var audioChannelCount: Int?

    public init(
        fileSize: Int64? = nil,
        duration: TimeInterval? = nil,
        width: Int? = nil,
        height: Int? = nil,
        frameRate: Double? = nil,
        videoCodec: String? = nil,
        audioCodec: String? = nil,
        audioSampleRate: Double? = nil,
        audioChannelCount: Int? = nil
    ) {
        self.fileSize = fileSize
        self.duration = duration
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.audioSampleRate = audioSampleRate
        self.audioChannelCount = audioChannelCount
    }
}

public enum RecordingMetadataReader {
    public static func load(recording: RecordingManifest, folder: URL) async -> RecordingMetadata {
        var metadata = await loadStorage(folder: folder)
        let mediaURL = recording.fileURL(for: recording.mediaFile, in: folder)
        if let mediaURL, FileManager.default.fileExists(atPath: mediaURL.path) {
            metadata.media = await loadMedia(at: mediaURL)
        }
        return metadata
    }

    public static func loadStorage(folder: URL) async -> RecordingMetadata {
        let storage = await Task.detached(priority: .utility) {
            folderStorage(at: folder)
        }.value
        return RecordingMetadata(
            logicalSize: storage.logicalSize,
            allocatedSize: storage.allocatedSize,
            fileCount: storage.fileCount,
            latestModificationDate: storage.latestModificationDate,
            media: nil
        )
    }

    public static func loadMedia(at url: URL) async -> RecordingMediaMetadata {
        await mediaMetadata(at: url)
    }

    private static func folderStorage(
        at folder: URL,
        fileManager: FileManager = .default
    ) -> (logicalSize: Int64, allocatedSize: Int64, fileCount: Int, latestModificationDate: Date?) {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .contentModificationDateKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return (0, 0, 0, nil) }

        var logicalSize: Int64 = 0
        var allocatedSize: Int64 = 0
        var fileCount = 0
        var latestModificationDate: Date?
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            let logical = Int64(values.fileSize ?? 0)
            let allocated = Int64(
                values.totalFileAllocatedSize
                    ?? values.fileAllocatedSize
                    ?? values.fileSize
                    ?? 0
            )
            logicalSize += logical
            allocatedSize += allocated
            fileCount += 1
            if let modified = values.contentModificationDate,
               latestModificationDate == nil || modified > latestModificationDate! {
                latestModificationDate = modified
            }
        }
        return (logicalSize, allocatedSize, fileCount, latestModificationDate)
    }

    private static func mediaMetadata(at url: URL) async -> RecordingMediaMetadata {
        let asset = AVURLAsset(url: url)
        let fileValues = try? url.resourceValues(forKeys: [.fileSizeKey])
        var result = RecordingMediaMetadata(fileSize: fileValues?.fileSize.map(Int64.init))

        if let duration = try? await asset.load(.duration), duration.seconds.isFinite {
            result.duration = max(0, duration.seconds)
        }

        if let videoTracks = try? await asset.loadTracks(withMediaType: .video),
           let videoTrack = videoTracks.first {
            if let naturalSize = try? await videoTrack.load(.naturalSize),
               let transform = try? await videoTrack.load(.preferredTransform) {
                let transformed = naturalSize.applying(transform)
                result.width = Int(abs(transformed.width).rounded())
                result.height = Int(abs(transformed.height).rounded())
            }
            if let frameRate = try? await videoTrack.load(.nominalFrameRate), frameRate > 0 {
                result.frameRate = Double(frameRate)
            }
            if let descriptions = try? await videoTrack.load(.formatDescriptions),
               let description = descriptions.first {
                result.videoCodec = codecName(CMFormatDescriptionGetMediaSubType(description))
            }
        }

        if let audioTracks = try? await asset.loadTracks(withMediaType: .audio),
           let audioTrack = audioTracks.first,
           let descriptions = try? await audioTrack.load(.formatDescriptions),
           let description = descriptions.first {
            result.audioCodec = codecName(CMFormatDescriptionGetMediaSubType(description))
            if let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
                result.audioSampleRate = streamDescription.pointee.mSampleRate
                result.audioChannelCount = Int(streamDescription.pointee.mChannelsPerFrame)
            }
        }
        return result
    }

    private static func codecName(_ code: FourCharCode) -> String {
        switch code {
        case kCMVideoCodecType_H264: return "H.264"
        case kCMVideoCodecType_HEVC: return "HEVC"
        case kAudioFormatMPEG4AAC: return "AAC"
        case kAudioFormatLinearPCM: return "PCM"
        default:
            let characters = (0..<4).map { offset -> Character in
                let shift = UInt32((3 - offset) * 8)
                let byte = UInt8((code >> shift) & 0xff)
                return Character(UnicodeScalar(byte))
            }
            let value = String(characters)
            return value.allSatisfy({ $0.isASCII && !$0.isWhitespace }) ? value : "Unknown"
        }
    }
}
