import Foundation
import Testing
@testable import LitteroiCore

/// Noise in syllable-long bursts of random loudness, which is enough like speech for the
/// canceller and the delay measurement.
private func speechLike(seconds: Int, seed: UInt64) -> [Float] {
    var state = seed
    func random() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(state >> 40) / Float(1 << 24)
    }
    var audio: [Float] = []
    while audio.count < seconds * 16_000 {
        let loudness = random() < 0.3 ? 0 : 0.05 + 0.25 * random()
        for _ in 0..<1_600 + Int(random() * 4_800) {
            audio.append(loudness * (random() * 2 - 1))
        }
    }
    return Array(audio.prefix(seconds * 16_000))
}

private func energy(_ audio: [Float], from: Int, to: Int) -> Float {
    audio[from * 16_000..<to * 16_000].reduce(0) { $0 + $1 * $1 }
}

/// 10 s of the call played on speakers, then 5 s of the user talking alone.
private func meetingOnSpeakers() -> (mic: [Float], call: [Float]) {
    let call = speechLike(seconds: 10, seed: 1) + [Float](repeating: 0, count: 5 * 16_000)
    let own = [Float](repeating: 0, count: 10 * 16_000) + speechLike(seconds: 5, seed: 2)
    var mic = own
    for i in mic.indices {
        if i >= 600 { mic[i] += 0.6 * call[i - 600] }
        if i >= 640 { mic[i] += 0.2 * call[i - 640] }
    }
    return (mic, call)
}

@Test func measuresHowLateTheMicHearsTheCall() {
    let (mic, call) = meetingOnSpeakers()
    let delay = EchoCanceller.delays(mic: mic, call: call).first!!
    #expect(abs(delay - 600) <= 32)
}

@Test func removesTheCallFromTheMicAndKeepsTheUsersVoice() throws {
    let (mic, call) = meetingOnSpeakers()
    let cleaned = try #require(EchoCanceller.cancel(mic: mic, call: call))
    let echoLeft = energy(cleaned, from: 3, to: 10) / energy(mic, from: 3, to: 10)
    #expect(10 * log10(echoLeft) < -10)
    let voiceKept = energy(cleaned, from: 11, to: 15) / energy(mic, from: 11, to: 15)
    #expect(voiceKept > 0.5)
}

@Test func leavesTheMicAloneWhenItNeverHeardTheCall() {
    let call = speechLike(seconds: 10, seed: 1)
    let mic = speechLike(seconds: 10, seed: 2)
    #expect(EchoCanceller.cancel(mic: mic, call: call) == nil)
}

@Test func dropsOwnLinesThatRepeatTheCall() {
    let mine = [
        Utterance(speaker: "Minä", start: 1, end: 3, text: "hei kaikki tervetuloa palaveriin"),
        Utterance(speaker: "Minä", start: 5, end: 6, text: "mä otan sen"),
    ]
    let theirs = [Utterance(speaker: "Puhuja 1", start: 1.2, end: 3.1, text: "Hei kaikki, tervetuloa palaveriin!")]
    #expect(EchoCanceller.droppingEcho(mine, heardIn: theirs) == [mine[1]])
}
