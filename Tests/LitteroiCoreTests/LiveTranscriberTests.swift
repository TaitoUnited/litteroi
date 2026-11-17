import Testing
@testable import LitteroiCore

private let second = LiveTranscriber.sampleRate

/// Speech as a steady tone, with silence from each pause's start to its end, in seconds.
private func speech(seconds: Int, pauses: [(Double, Double)] = []) -> [Float] {
    (0..<seconds * second).map { index in
        let time = Double(index) / Double(second)
        return pauses.contains { time >= $0.0 && time < $0.1 } ? 0 : (index % 40 < 20 ? 0.3 : -0.3)
    }
}

@Test func waitsForFifteenSecondsWhileTheRecordingRuns() {
    #expect(LiveTranscriber.cut(speech(seconds: 14), final: false) == nil)
    #expect(LiveTranscriber.cut([], final: false) == nil)
}

@Test func endsAWindowInItsLastPause() {
    let cut = LiveTranscriber.cut(speech(seconds: 20, pauses: [(8, 9), (16, 17)]), final: false)
    #expect(cut.map { $0 > 16 * second && $0 < 17 * second } == true)
}

@Test func keepsAWindowWithinThirtySeconds() {
    let cut = LiveTranscriber.cut(speech(seconds: 60, pauses: [(22, 23), (40, 41)]), final: false)
    #expect(cut.map { $0 > 22 * second && $0 < 23 * second } == true)
    let unbroken = LiveTranscriber.cut(speech(seconds: 60), final: false)
    #expect(unbroken.map { $0 <= 30 * second } == true)
}

@Test func takesTheRestWhole() {
    #expect(LiveTranscriber.cut(speech(seconds: 12), final: true) == 12 * second)
    #expect(LiveTranscriber.cut(speech(seconds: 0), final: true) == nil)
    let cut = LiveTranscriber.cut(speech(seconds: 45, pauses: [(25, 26)]), final: true)
    #expect(cut.map { $0 > 25 * second && $0 < 26 * second } == true)
}

@Test func timesLinesFromTheWindowsStart() {
    #expect(LiveTranscriber.lines([(2.5, " Hyvää iltaa kaikille."), (9, "  "), (12, "Aloitetaan.")], at: 3_598) == [
        "[01:00:00] Hyvää iltaa kaikille.",
        "[01:00:10] Aloitetaan.",
    ])
}
