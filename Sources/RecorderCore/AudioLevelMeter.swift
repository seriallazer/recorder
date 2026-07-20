import AVFoundation
import Accelerate

enum AudioLevelMeter {
    static func normalizedLevel(from buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return 0 }

        var sumSquares: Double = 0
        var sampleCount = 0
        if let floatChannels = buffer.floatChannelData {
            for channel in 0..<channels {
                var local: Float = 0
                vDSP_svesq(
                    floatChannels[channel],
                    1,
                    &local,
                    vDSP_Length(frames)
                )
                sumSquares += Double(local)
                sampleCount += frames
            }
        } else if let integerChannels = buffer.int16ChannelData {
            for channel in 0..<channels {
                for index in 0..<frames {
                    let value = Double(integerChannels[channel][index])
                        / Double(Int16.max)
                    sumSquares += value * value
                }
                sampleCount += frames
            }
        }
        return normalizedLevel(sumSquares: sumSquares, sampleCount: sampleCount)
    }

    static func normalizedLevel(from sampleBuffer: CMSampleBuffer) -> Float {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return 0
        }

        var requiredSize = 0
        let sizingStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &requiredSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard sizingStatus == noErr, requiredSize > 0 else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: requiredSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var retainedBlock: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: list,
            bufferListSize: requiredSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &retainedBlock
        )
        guard status == noErr else { return 0 }

        var sumSquares: Double = 0
        var sampleCount = 0
        for buffer in UnsafeMutableAudioBufferListPointer(list) {
            guard let data = buffer.mData else { continue }
            if stream.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0,
               stream.pointee.mBitsPerChannel == 32 {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let samples = data.assumingMemoryBound(to: Float.self)
                var local: Float = 0
                vDSP_svesq(samples, 1, &local, vDSP_Length(count))
                sumSquares += Double(local)
                sampleCount += count
            } else if stream.pointee.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0,
                      stream.pointee.mBitsPerChannel == 16 {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                let samples = data.assumingMemoryBound(to: Int16.self)
                for index in 0..<count {
                    let value = Double(samples[index]) / Double(Int16.max)
                    sumSquares += value * value
                }
                sampleCount += count
            }
        }
        return normalizedLevel(sumSquares: sumSquares, sampleCount: sampleCount)
    }

    private static func normalizedLevel(
        sumSquares: Double,
        sampleCount: Int
    ) -> Float {
        guard sampleCount > 0 else { return 0 }
        let rms = sqrt(sumSquares / Double(sampleCount))
        let decibels = 20 * log10(max(rms, 0.000_001))
        return Float(min(1, max(0, (decibels + 60) / 60)))
    }
}
