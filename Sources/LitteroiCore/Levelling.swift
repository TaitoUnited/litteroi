import Accelerate
import Foundation

/// Raises a faint mic track for the page's audio. In the room meeting of 23.11.2026 the mic heard
/// people from across a table at about -65 dB, against about -20 dB when the user talks into a
/// call, and the page played what sounded like silence.
enum Levelling {
    static let sampleRate: Float = 16_000
    static let frame = 1_600
    /// The level speech is raised to, an RMS of about -22 dB.
    static let target: Float = 0.08
    /// 40 dB, which brings the hiss of a quiet room to about -40 dB.
    static let maxGain: Float = 100
    /// The speech this many frames before and after a moment sets its gain, so the gain follows a
    /// change of speaker within 3 s and not each word.
    static let window = 30
    /// The track is raised from this many frames before a word to as many after it, and is as
    /// recorded elsewhere, where beside a call the mic holds the call's echo and no speech.
    static let reach = 10
    static let smoothing = 5

    /// The track with its speech raised to `target`, `speech` being the seconds Whisper heard
    /// words in on it. Nothing is turned down. Words under 12 dB above the track's hiss set no
    /// gain, since Whisper makes up lines in a silence: in the meeting of 16.11.2026 at 15:00, 11
    /// of the user's 16 lines sat at the hiss's level and would have raised it by `maxGain`.
    static func raised(_ audio: [Float], speech: [(start: Float, end: Float)]) -> [Float] {
        let filtered = withoutRumble(audio)
        let levels = RoomMeeting.levels(filtered)
        guard !levels.isEmpty else { return audio }
        var spoken = [Bool](repeating: false, count: levels.count)
        for words in speech {
            let first = max(0, Int(words.start * 10))
            let last = min(levels.count, Int((words.end * 10).rounded(.up)))
            if first < last { spoken.replaceSubrange(first..<last, with: repeatElement(true, count: last - first)) }
        }
        let gains = gains(levels: levels, speech: spoken, above: 4 * levels.sorted()[levels.count / 10])
        guard gains.contains(where: { $0 > 1 }) else { return audio }

        var output = filtered
        output.withUnsafeMutableBufferPointer { samples in
            for index in samples.indices {
                let position = (Float(index) + 0.5) / Float(frame) - 0.5
                let before = min(gains.count - 1, max(0, Int(position.rounded(.down))))
                let after = min(gains.count - 1, before + 1)
                let share = min(1, max(0, position - Float(before)))
                samples[index] *= gains[before] + (gains[after] - gains[before]) * share
            }
        }
        return output
    }

    /// The gain of each 100 ms: 1 with no speech within `reach`, else what brings the speech
    /// around it to `target`, from 1 to `maxGain`. Speech under `above`, or under half a second of
    /// it, takes the lower of the gains of the speech before and after it.
    static func gains(levels: [Float], speech: [Bool], above: Float = 0) -> [Float] {
        var power = [Float](repeating: 0, count: levels.count + 1)
        var count = [Int](repeating: 0, count: levels.count + 1)
        for index in levels.indices {
            power[index + 1] = power[index] + (speech[index] ? levels[index] * levels[index] : 0)
            count[index + 1] = count[index] + (speech[index] ? 1 : 0)
        }
        let around: [(gain: Float?, faint: Bool)] = levels.indices.map { index in
            guard count[min(levels.count, index + reach + 1)] > count[max(0, index - reach)] else { return (nil, false) }
            let first = max(0, index - window)
            let last = min(levels.count, index + window + 1)
            let frames = count[last] - count[first]
            let level = ((power[last] - power[first]) / Float(frames)).squareRoot()
            return frames >= 5 && level > above ? (min(maxGain, max(1, target / level)), false) : (nil, true)
        }
        var before: Float?
        let earlier = around.map { moment -> Float? in
            before = moment.gain ?? before
            return before
        }
        var after: Float?
        let later: [Float?] = around.reversed().map { moment -> Float? in
            after = moment.gain ?? after
            return after
        }.reversed()
        let filled = around.indices.map { index -> Float in
            if let gain = around[index].gain { return gain }
            guard around[index].faint else { return 1 }
            return min(earlier[index] ?? later[index] ?? 1, later[index] ?? earlier[index] ?? 1)
        }
        return filled.indices.map { index in
            vDSP.mean(filled[max(0, index - smoothing)..<min(filled.count, index + smoothing + 1)])
        }
    }

    /// Keeps the mix under `limit`: the gain comes down 10 ms ahead of a peak and back up after it.
    static func limited(_ audio: [Float], to limit: Float = 0.95) -> [Float] {
        let ahead = 160
        guard audio.count > ahead, vDSP.maximumMagnitude(audio) > limit else { return audio }
        let magnitudes = vDSP.absolute(audio) + [Float](repeating: 0, count: ahead - 1)
        var peaks = [Float](repeating: 0, count: audio.count)
        vDSP_vswmax(magnitudes, 1, &peaks, 1, vDSP_Length(audio.count), vDSP_Length(ahead))
        let needed = [Float](repeating: 1, count: ahead - 1) + peaks.map { $0 > limit ? limit / $0 : 1 }
        var gains = [Float](repeating: 0, count: audio.count)
        vDSP_vswsum(needed, 1, &gains, 1, vDSP_Length(audio.count), vDSP_Length(ahead))
        return vDSP.multiply(audio, vDSP.divide(gains, Float(ahead)))
    }

    /// A high-pass at 80 Hz, under which the built-in mic holds the table's thumps and no speech.
    static func withoutRumble(_ audio: [Float]) -> [Float] {
        let omega = 2 * Double.pi * 80 / Double(sampleRate)
        let alpha = sin(omega) / 2.squareRoot()
        let a0 = 1 + alpha
        let b = 1 + cos(omega)
        let coefficients = [b / 2 / a0, -b / a0, b / 2 / a0, -2 * cos(omega) / a0, (1 - alpha) / a0]
        guard var filter = vDSP.Biquad(coefficients: coefficients, channelCount: 1, sectionCount: 1, ofType: Float.self) else {
            return audio
        }
        return filter.apply(input: audio)
    }
}
