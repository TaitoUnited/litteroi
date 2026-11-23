import Foundation
import Testing
@testable import LitteroiCore

private let second = 16_000

/// A tone at `level` from `start` to `end`, in seconds, in a track of `seconds` of silence.
private func track(seconds: Int, tones: [(start: Int, end: Int, level: Float)]) -> [Float] {
    var audio = [Float](repeating: 0, count: seconds * second)
    for tone in tones {
        for index in tone.start * second..<tone.end * second {
            audio[index] = tone.level * Float(2).squareRoot() * sin(Float(index) / 10)
        }
    }
    return audio
}

@Test func takesAMeetingAsHeldInOneRoomWhenTheCallIsBriefAndTheMicHoldsTwoVoices() throws {
    let call = track(seconds: 600, tones: [(0, 40, 0.1)])
    let mic = track(seconds: 600, tones: [(0, 40, 0.02), (40, 240, 0.004), (240, 440, 0.001), (440, 460, 0.05)])
    #expect(RoomMeeting.callIsBrief(call, of: mic.count))
    #expect(!RoomMeeting.callIsBrief(track(seconds: 600, tones: [(0, 90, 0.1)]), of: mic.count))

    let room = try #require(RoomMeeting(mic: mic, call: call, speech: [(2, 0, 40), (0, 40, 240), (1, 240, 440), (3, 440, 460)]))
    #expect(room.voices == 2)
    #expect(room.own == 0)
    #expect(room.lead.rounded() == 12)
    #expect(room.callSeconds == 40)
    #expect(room.seconds == 600)
    #expect(room.note(me: "Anna").contains("ääntä vain 40 s nauhoituksen 600 s:sta"))
    #expect(room.note(me: "Anna").contains("Nimen Anna sai ääni, joka kuuluu mikrofoniin 12 dB muita kovempaa"))
}

@Test func leavesTheMicToTheUserWhenOneVoiceSpeaksWhileTheCallIsSilent() {
    let call = track(seconds: 600, tones: [(0, 40, 0.1)])
    let mic = track(seconds: 600, tones: [(0, 40, 0.02), (40, 440, 0.004), (440, 460, 0.004)])
    // The second voice speaks for 40 s under the call's sound and for 20 s outside it.
    #expect(RoomMeeting(mic: mic, call: call, speech: [(1, 0, 40), (0, 40, 440), (1, 440, 460)]) == nil)
}

@Test func namesNoVoiceAsTheUsersWhenNoneIsClearlyNearest() throws {
    let call = track(seconds: 600, tones: [(0, 40, 0.1)])
    let mic = track(seconds: 600, tones: [(40, 240, 0.004), (240, 440, 0.003)])
    let room = try #require(RoomMeeting(mic: mic, call: call, speech: [(0, 40, 240), (1, 240, 440)]))
    #expect(room.own == nil)
    #expect(room.note(me: "Anna").contains("käyttäjän omaa ääntä ei ole nimetty"))
}

@Test func givesTheNearestVoiceTheUsersNameAndKeepsTheNoteInTheTranscript() throws {
    let lines = [
        Utterance(speaker: "Puhuja 1", start: 0, end: 2, text: "Huomenta."),
        Utterance(speaker: "Puhuja 2", start: 2, end: 4, text: "Huomenta."),
        Utterance(speaker: "Puhuja 1", start: 4, end: 6, text: "Aloitetaan."),
    ]
    let renamed = SpeakerLabels.renamed(lines, from: .speakerId(1), to: "Anna", in: .fi)
    #expect(renamed.map(\.speaker) == ["Puhuja 1", "Anna", "Puhuja 1"])

    let transcript = Transcript(utterances: renamed, room: "Huonepalaveri: puhujat on eroteltu mikrofonin raidalta.")
    #expect(transcript.markdown(title: "2026-11-23-1001").hasPrefix(
        "# 2026-11-23-1001\n\nHuonepalaveri: puhujat on eroteltu mikrofonin raidalta.\n\n[00:00:00] **Puhuja 1:** Huomenta.\n"
    ))
    let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    try transcript.writeJSON(to: file)
    #expect(try Transcript.read(file) == transcript)
    try Data(#"{"utterances":[]}"#.utf8).write(to: file)
    #expect(try Transcript.read(file).room == nil)
}

@Test func raisesFaintSpeechToTheTargetAndLeavesLoudSpeechAlone() {
    let faint = track(seconds: 60, tones: [(10, 30, 0.001), (40, 50, 0.0005)])
    let raised = Levelling.raised(faint, speech: [(10, 30), (40, 50)])
    func level(_ audio: [Float], _ from: Int, _ to: Int) -> Float {
        (audio[from * second..<to * second].reduce(0) { $0 + $1 * $1 } / Float((to - from) * second)).squareRoot()
    }
    #expect(abs(level(raised, 15, 25) - Levelling.target) < 0.01)
    // 0.0005 would need a gain of 160, over the most the track is raised by.
    #expect(abs(level(raised, 43, 47) - 0.0005 * Levelling.maxGain) < 0.005)
    #expect(level(raised, 0, 5) == 0)

    let loud = track(seconds: 60, tones: [(10, 30, 0.2)])
    #expect(Levelling.raised(loud, speech: [(10, 30)]) == loud)
    #expect(Levelling.raised(faint, speech: []) == faint)
}

@Test func raisesOnlyAroundSpeechAndFaintSpeechNoMoreThanTheSpeechAroundIt() {
    var levels = [Float](repeating: 0.0001, count: 600)
    var speech = [Bool](repeating: false, count: 600)
    for index in 100..<150 {
        levels[index] = 0.004
        speech[index] = true
    }
    for index in 250..<260 {
        speech[index] = true
    }
    for index in 400..<450 {
        levels[index] = 0.016
        speech[index] = true
    }
    let gains = Levelling.gains(levels: levels, speech: speech, above: 0.0004)
    #expect(gains[..<84].allSatisfy { $0 == 1 })
    #expect(gains[96..<154].allSatisfy { abs($0 - 20) < 0.01 })
    #expect(gains[166..<234].allSatisfy { $0 == 1 })
    #expect(gains[246..<264].allSatisfy { abs($0 - 5) < 0.01 })
    #expect(gains[276..<384].allSatisfy { $0 == 1 })
    #expect(gains[396..<454].allSatisfy { abs($0 - 5) < 0.01 })
    #expect(gains[466...].allSatisfy { $0 == 1 })
    #expect(Levelling.gains(levels: levels, speech: [Bool](repeating: false, count: 600)).allSatisfy { $0 == 1 })
}

@Test func raisesNoHissAroundALineWhisperMadeUpInASilence() {
    var state: UInt64 = 7
    let hiss = (0..<60 * second).map { _ -> Float in
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return 0.0002 * (Float(state >> 40) / Float(1 << 24) * 2 - 1)
    }
    #expect(Levelling.raised(hiss, speech: [(20, 23)]) == hiss)
}

@Test func keepsTheMixUnderTheLimit() {
    let loud = track(seconds: 4, tones: [(1, 2, 1.2)])
    let limited = Levelling.limited(loud)
    #expect(limited.map(abs).max()! <= 0.951)
    #expect(limited[second + second / 2] != 0)
    #expect(Array(limited[3 * second..<4 * second]) == Array(loud[3 * second..<4 * second]))
    let quiet = track(seconds: 4, tones: [(1, 2, 0.2)])
    #expect(Levelling.limited(quiet) == quiet)
}

@Test func takesTheUsersLinesAsTheMicsBesideACallAndEveryLineInARoomMeeting() {
    let me = SpeakerLabels.me(in: .fi)
    let lines = [
        Utterance(speaker: me, start: 0, end: 2, text: "Huomenta.", words: [Word(start: 0.5, end: 1, text: "Huomenta.")]),
        Utterance(speaker: "Puhuja 1", start: 2, end: 4, text: "Huomenta."),
    ]
    let call = track(seconds: 60, tones: [(0, 20, 0.1)])
    #expect(MeetingMedia.micSpeech(of: Transcript(utterances: lines), call: call).map(\.start) == [0.5])
    #expect(MeetingMedia.micSpeech(of: Transcript(utterances: lines, room: "Huonepalaveri"), call: call).map(\.start) == [0.5, 2])
    #expect(MeetingMedia.micSpeech(of: Transcript(utterances: lines), call: nil).map(\.start) == [0.5, 2])
    #expect(MeetingMedia.micSpeech(of: Transcript(utterances: lines), call: track(seconds: 60, tones: [])).map(\.start) == [0.5, 2])
}
