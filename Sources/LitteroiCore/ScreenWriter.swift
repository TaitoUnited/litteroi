import AVFoundation

/// Writes one display's frames as H.265 into a QuickTime movie. A movie gets its index only when
/// it is finished, and without one it cannot be opened, so the movie is written in fragments that
/// each carry their own, and a recording cut off by a crash keeps all but its last seconds. A
/// fragment goes to disk when a later frame arrives, so a still screen's frame is repeated.
public final class ScreenWriter {
    public static let fragmentInterval: TimeInterval = 5
    public static let repeatInterval: TimeInterval = 2

    private let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var started = false
    private var last: (image: CVPixelBuffer, time: CMTime)?

    public init(url: URL, width: Int, height: Int) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: Self.fragmentInterval, preferredTimescale: 600)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
    }

    /// A frame timed at or before the one before it, as one captured just before a repeat and
    /// delivered after it, is written right after that one: the writer fails on a step back.
    public func append(_ image: CVPixelBuffer, at time: CMTime) {
        var time = time
        if let last {
            time = CMTimeMaximum(time, last.time + CMTime(value: 1, timescale: 600))
        }
        if !started {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: time)
            started = true
        }
        if input.isReadyForMoreMediaData, adaptor.append(image, withPresentationTime: time) {
            last = (image, time)
        }
    }

    /// Writes the last frame again once it is `repeatInterval` old.
    public func repeatLast(at time: CMTime) {
        guard let last, (time - last.time).seconds >= Self.repeatInterval else { return }
        append(last.image, at: time)
    }

    /// The last frame lasts until `end`. A video without a frame is deleted.
    public func finish(at end: CMTime) async {
        guard let last else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            return
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTimeMaximum(last.time, end))
        await writer.finishWriting()
    }
}
