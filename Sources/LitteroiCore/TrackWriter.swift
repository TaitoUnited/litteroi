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

    /// How far behind its timeline a track may fall before `append(_:at:)` fills the gap.
    public static let gapTolerance: TimeInterval = 0.5

    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var framesWritten: AVAudioFramePosition = 0
    /// The converter leaves frames it has no use for yet in the buffer it was handed and reads
    /// them when it is called again, so it gets a copy that is kept until the next one is converted.
    private var lastInput: AVAudioPCMBuffer?
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
        guard let file, buffer.frameLength > 0, let input = Self.mono(buffer) ?? Self.copy(buffer) else { return }
        if converter?.inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: Self.format)
            converter?.downmix = true
        }
        guard let converter else { return }

        let ratio = Self.format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1
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
            return input
        }
        lastInput = input
        if let conversionError { throw conversionError }

        try file.write(from: output)
        framesWritten += AVAudioFramePosition(output.frameLength)
        let level = Self.level(of: output)
        latestLevel.withLock { $0 = level }
    }

    /// Seconds of audio written so far.
    public var seconds: TimeInterval { TimeInterval(framesWritten) / Self.format.sampleRate }

    /// Appends a buffer whose first frame was heard `second` seconds into the track, after silence
    /// for a gap before it, such as while the source device changed, so the sound after the gap
    /// keeps its time.
    public func append(_ buffer: AVAudioPCMBuffer, at second: TimeInterval) throws {
        try padSilence(until: second)
        try append(buffer)
    }

    /// Fills the track with silence up to `second` when it is more than `gapTolerance` short of it.
    public func padSilence(until second: TimeInterval) throws {
        guard let file, second - seconds > Self.gapTolerance,
              let silence = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(Self.format.sampleRate))
        else { return }
        // Frames the converter held back belong before the gap, not after it.
        converter?.reset()
        silence.floatChannelData![0].update(repeating: 0, count: Int(silence.frameCapacity))
        var missing = AVAudioFramePosition((second * Self.format.sampleRate).rounded()) - framesWritten
        while missing > 0 {
            silence.frameLength = AVAudioFrameCount(min(missing, AVAudioFramePosition(silence.frameCapacity)))
            try file.write(from: silence)
            framesWritten += AVAudioFramePosition(silence.frameLength)
            missing -= AVAudioFramePosition(silence.frameLength)
        }
        latestLevel.withLock { $0 = 0 }
    }

    /// The mean of a multichannel float buffer's channels, at its own rate. AVAudioConverter's
    /// downmix turns a discrete channel layout into silence without an error, and macOS hands
    /// out the built-in mic in one, 3 channels, while a call app runs voice processing on it.
    static func mono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let channels = Int(buffer.format.channelCount)
        guard channels > 1, let samples = buffer.floatChannelData,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: buffer.format.sampleRate,
                  channels: 1,
                  interleaved: false
              ),
              let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let mixed = mono.floatChannelData?[0]
        else { return nil }
        mono.frameLength = buffer.frameLength
        let interleaved = buffer.format.isInterleaved
        let scale = 1 / Float(channels)
        for frame in 0..<Int(buffer.frameLength) {
            var sum: Float = 0
            for channel in 0..<channels {
                sum += interleaved ? samples[0][frame * buffer.stride + channel] : samples[channel][frame]
            }
            mixed[frame] = sum * scale
        }
        return mono
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        for (from, to) in zip(source, UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)) {
            guard let fromData = from.mData, let toData = to.mData else { return nil }
            memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }

    /// The format a Core Audio IO proc delivers a process tap in: the tap's channels and samples
    /// at the rate of the device the IO proc runs on, which may differ from the rate the tap reports.
    public static func ioFormat(tap: AudioStreamBasicDescription, deviceSampleRate: Double) -> AVAudioFormat? {
        var description = tap
        if deviceSampleRate > 0 {
            description.mSampleRate = deviceSampleRate
        }
        return AVAudioFormat(streamDescription: &description)
    }

    /// Appends what a Core Audio IO proc delivered in `format`. A buffer list laid out otherwise,
    /// as while a device changes format, is skipped: read as `format`, it would run past its memory.
    public func append(_ input: UnsafePointer<AudioBufferList>, format: AVAudioFormat) throws {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let channelsPerBuffer = format.isInterleaved ? format.channelCount : 1
        let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
        guard format.channelCount > 0, buffers.count == Int(format.channelCount / channelsPerBuffer), bytesPerFrame > 0,
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
