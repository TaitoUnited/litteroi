import AVFoundation
import os

/// Writes one audio track as 16 kHz mono 16-bit PCM, the rate Whisper works at, converting
/// whatever format the source delivers. The file is CAF, which stays readable when the app
/// stops before `close()`.
public final class TrackWriter: @unchecked Sendable {
    public static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private let latestLevel = OSAllocatedUnfairLock<Float>(initialState: 0)

    public init(url: URL) throws {
        file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: Self.format.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    /// Loudness of the latest buffer, from 0 (silent) to 1.
    public var level: Float { latestLevel.withLock { $0 } }

    public func append(_ buffer: AVAudioPCMBuffer) throws {
        guard let file, buffer.frameLength > 0 else { return }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: Self.format)
            converter?.downmix = true
        }
        guard let converter else { return }

        let ratio = Self.format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return }
        var supplied = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if let conversionError { throw conversionError }

        try file.write(from: output)
        let level = Self.level(of: output)
        latestLevel.withLock { $0 = level }
    }

    /// Appends what a Core Audio IO proc delivered in `format`. A buffer list laid out otherwise,
    /// as while a device changes format, is skipped: read as `format`, it would run past its memory.
    public func append(_ input: UnsafePointer<AudioBufferList>, format: AVAudioFormat) throws {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let channelsPerBuffer = format.isInterleaved ? format.channelCount : 1
        let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
        guard buffers.count == Int(format.channelCount / channelsPerBuffer), bytesPerFrame > 0,
              let size = buffers.first?.mDataByteSize, size % bytesPerFrame == 0,
              buffers.allSatisfy({ $0.mData != nil && $0.mDataByteSize == size && $0.mNumberChannels == channelsPerBuffer }),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil)
        else { return }
        try append(buffer)
    }

    public func close() {
        if #available(macOS 15, *) {
            file?.close()
        }
        file = nil
    }

    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            sum += samples[index] * samples[index]
        }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        let decibels = 20 * log10(max(rms, 0.000_001))
        return min(max((decibels + 60) / 60, 0), 1)
    }
}
