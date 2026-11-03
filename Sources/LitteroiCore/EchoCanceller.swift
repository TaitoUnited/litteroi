import Accelerate
import CSpeexDSP
import Foundation

/// Removes from the mic track the call that the mic picked up from the speakers, with SpeexDSP's
/// echo canceller and the call track as its reference.
enum EchoCanceller {
    static let sampleRate = 16_000
    static let frame = 160
    /// 256 ms of echo path after the measured delay.
    static let filterLength = 4_096
    /// The delay is measured again every 30 s, since the mic's and the speakers' clocks drift.
    static let block = 30 * sampleRate
    /// The two recorders start up to this far apart.
    static let maxDelay = 2 * sampleRate
    /// The echo path starts this long after the measured delay, so the filter sees all of it.
    static let margin = 320

    /// Nil when the mic never picked up the call, as with headphones.
    static func cancel(mic: [Float], call: [Float]) -> [Float]? {
        let measured = delays(mic: mic, call: call)
        guard let first = measured.compactMap({ $0 }).first else { return nil }
        var delay = first
        let shifts = measured.map { measuredDelay in
            delay = measuredDelay ?? delay
            return delay - margin
        }

        let echo = speex_echo_state_init(Int32(frame), Int32(filterLength))
        let preprocess = speex_preprocess_state_init(Int32(frame), Int32(sampleRate))
        defer {
            speex_preprocess_state_destroy(preprocess)
            speex_echo_state_destroy(echo)
        }
        var rate = Int32(sampleRate)
        speex_echo_ctl(echo, SPEEX_ECHO_SET_SAMPLING_RATE, &rate)
        speex_preprocess_ctl(preprocess, SPEEX_PREPROCESS_SET_ECHO_STATE, UnsafeMutableRawPointer(echo))
        var off: Int32 = 0
        speex_preprocess_ctl(preprocess, SPEEX_PREPROCESS_SET_DENOISE, &off)

        var output = mic
        var recorded = [Int16](repeating: 0, count: frame)
        var played = [Int16](repeating: 0, count: frame)
        var cleaned = [Int16](repeating: 0, count: frame)
        var start = 0
        while start + frame <= mic.count {
            let shift = shifts[start / block]
            for i in 0..<frame {
                recorded[i] = pcm(mic[start + i])
                let j = start + i - shift
                played[i] = j >= 0 && j < call.count ? pcm(call[j]) : 0
            }
            speex_echo_cancellation(echo, recorded, played, &cleaned)
            speex_preprocess_run(preprocess, &cleaned)
            for i in 0..<frame {
                output[start + i] = Float(cleaned[i]) / 32_768
            }
            start += frame
        }
        return output
    }

    /// How many samples after the call track each 30 s block of the mic track hears it, or nil
    /// for a block where the mic did not pick up the call. GCC-PHAT: the cross-correlation of the
    /// two with every frequency weighted alike, which peaks sharply at the echo's delay.
    static func delays(mic: [Float], call: [Float]) -> [Int?] {
        let log2n = vDSP_Length(log2(Double(2 * (block + maxDelay))).rounded(.up))
        let n = 1 << Int(log2n)
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else { return [] }
        return stride(from: 0, to: mic.count, by: block).map { blockStart in
            let heard = mic[blockStart..<min(blockStart + block, mic.count)]
            let window = (blockStart - maxDelay..<blockStart + heard.count + maxDelay).map { j in
                j >= 0 && j < call.count ? call[j] : 0
            }
            let (heardReal, heardImag) = spectrum(Array(heard), count: n, fft: fft)
            var (real, imag) = spectrum(window, count: n, fft: fft)
            real[0] = 0
            imag[0] = 0
            for k in 1..<n / 2 {
                let crossReal = heardReal[k] * real[k] + heardImag[k] * imag[k]
                let crossImag = heardReal[k] * imag[k] - heardImag[k] * real[k]
                let magnitude = (crossReal * crossReal + crossImag * crossImag).squareRoot() + 1e-12
                real[k] = crossReal / magnitude
                imag[k] = crossImag / magnitude
            }
            let correlation = Array(signal(real: real, imag: imag, fft: fft).prefix(2 * maxDelay + 1))
            guard let best = correlation.indices.max(by: { correlation[$0] < correlation[$1] }) else { return nil }
            let mean = vDSP.mean(correlation)
            let spread = vDSP.rootMeanSquare(vDSP.add(-mean, correlation))
            guard spread > 0, (correlation[best] - mean) / spread > 10 else { return nil }
            return maxDelay - best
        }
    }

    /// Drops lines of the user's own track that repeat what the call said at the same time: the
    /// echo the canceller left.
    static func droppingEcho(_ mine: [Utterance], heardIn theirs: [Utterance]) -> [Utterance] {
        mine.filter { utterance in
            let own = words(utterance.text)
            guard own.count >= 2 else { return true }
            let heard = Set(theirs
                .filter { $0.start < utterance.end + 1 && $0.end > utterance.start - 1 }
                .flatMap { words($0.text) })
            let repeated = own.filter(heard.contains).count
            return Float(repeated) / Float(own.count) < 0.6
        }
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func pcm(_ sample: Float) -> Int16 {
        Int16(max(-32_768, min(32_767, (sample * 32_768).rounded())))
    }

    /// The real FFT of `samples` padded with zeros to `count`, in vDSP's packed layout.
    private static func spectrum(_ samples: [Float], count n: Int, fft: vDSP.FFT<DSPSplitComplex>) -> ([Float], [Float]) {
        var padded = samples + [Float](repeating: 0, count: n - samples.count)
        var inReal = [Float](repeating: 0, count: n / 2)
        var inImag = [Float](repeating: 0, count: n / 2)
        var outReal = [Float](repeating: 0, count: n / 2)
        var outImag = [Float](repeating: 0, count: n / 2)
        inReal.withUnsafeMutableBufferPointer { inR in
            inImag.withUnsafeMutableBufferPointer { inI in
                outReal.withUnsafeMutableBufferPointer { outR in
                    outImag.withUnsafeMutableBufferPointer { outI in
                        var input = DSPSplitComplex(realp: inR.baseAddress!, imagp: inI.baseAddress!)
                        var output = DSPSplitComplex(realp: outR.baseAddress!, imagp: outI.baseAddress!)
                        padded.withUnsafeMutableBytes { bytes in
                            vDSP_ctoz(bytes.bindMemory(to: DSPComplex.self).baseAddress!, 2, &input, 1, vDSP_Length(n / 2))
                        }
                        fft.forward(input: input, output: &output)
                    }
                }
            }
        }
        return (outReal, outImag)
    }

    /// The inverse of `spectrum`, up to a constant factor.
    private static func signal(real: [Float], imag: [Float], fft: vDSP.FFT<DSPSplitComplex>) -> [Float] {
        var inReal = real
        var inImag = imag
        var outReal = [Float](repeating: 0, count: real.count)
        var outImag = [Float](repeating: 0, count: real.count)
        var samples = [Float](repeating: 0, count: 2 * real.count)
        inReal.withUnsafeMutableBufferPointer { inR in
            inImag.withUnsafeMutableBufferPointer { inI in
                outReal.withUnsafeMutableBufferPointer { outR in
                    outImag.withUnsafeMutableBufferPointer { outI in
                        let input = DSPSplitComplex(realp: inR.baseAddress!, imagp: inI.baseAddress!)
                        var output = DSPSplitComplex(realp: outR.baseAddress!, imagp: outI.baseAddress!)
                        fft.inverse(input: input, output: &output)
                        samples.withUnsafeMutableBytes { bytes in
                            vDSP_ztoc(&output, 1, bytes.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(real.count))
                        }
                    }
                }
            }
        }
        return samples
    }
}
