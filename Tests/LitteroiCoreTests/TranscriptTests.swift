import SpeakerKit
import Testing
import WhisperKit
@testable import LitteroiCore

@Test func mergesConsecutivePiecesFromTheSameSpeaker() {
    let pieces = [
        Utterance(speaker: "Puhuja 1", start: 0, end: 2, text: " Hei kaikki."),
        Utterance(speaker: "Puhuja 1", start: 2, end: 4, text: "Aloitetaan."),
        Utterance(speaker: "Puhuja 2", start: 4, end: 5, text: "  "),
        Utterance(speaker: "Puhuja 2", start: 5, end: 6, text: "Joo."),
    ]
    #expect(SpeakerLabels.merged(pieces) == [
        Utterance(speaker: "Puhuja 1", start: 0, end: 4, text: "Hei kaikki. Aloitetaan."),
        Utterance(speaker: "Puhuja 2", start: 5, end: 6, text: "Joo."),
    ])
}

@Test func namesSpeakersFromOneAndFlagsOverlap() {
    #expect(SpeakerLabels.name(for: .speakerId(0), in: .fi) == "Puhuja 1")
    #expect(SpeakerLabels.name(for: .multiple([0, 1]), in: .fi) == "Päällekkäin")
    #expect(SpeakerLabels.name(for: .noMatch, in: .fi) == "Tuntematon")
}

@Test func labelsSpeakersInTheMeetingsLanguage() {
    #expect(SpeakerLabels.name(for: .speakerId(1), in: .en) == "Speaker 2")
    #expect(SpeakerLabels.name(for: .multiple([0, 1]), in: .en) == "Overlapping")
    #expect(SpeakerLabels.me(in: .fi, fullName: "Anna-Liisa Mäki") == "Anna-Liisa")
    #expect(SpeakerLabels.me(in: .en, fullName: "") == "Me")
    #expect(SpeakerLabels.me(in: .fi, fullName: "") == "Minä")
}

@Test func takesTheLanguageMostOfTheSpeechIsIn() {
    #expect(MeetingTranscriber.mainLanguage(of: [("fi", 30), ("en", 20), ("en", 15)]) == .en)
    #expect(MeetingTranscriber.mainLanguage(of: [("fi", 30), ("en", 20), ("sv", 25)]) == .fi)
    #expect(MeetingTranscriber.mainLanguage(of: [("et", 30), (nil, 5)]) == .fi)
    #expect(MeetingTranscriber.mainLanguage(of: []) == .fi)
}

@Test func cutsWindowsWhereTheSpeakerChanges() {
    let speech: [(speaker: Int, start: Float, end: Float)] = [
        (0, 0, 10), (0, 11, 20), (1, 22, 30), (0, 12, 12.5), (0, 29, 40), (1, 40.5, 41),
    ]
    #expect(MeetingTranscriber.turnStarts(of: speech) == [21, 29])
    #expect(MeetingTranscriber.turnStarts(of: []) == [])
}

@Test func keepsAWindowInTheOtherLanguageOnlyWhenWhisperCouldTell() {
    #expect(!MeetingTranscriber.needsAnotherPass("en", seconds: 20, in: .fi))
    #expect(!MeetingTranscriber.needsAnotherPass("fi", seconds: 2, in: .fi))
    #expect(MeetingTranscriber.needsAnotherPass("en", seconds: 3, in: .fi))
    #expect(MeetingTranscriber.needsAnotherPass("et", seconds: 20, in: .fi))
    #expect(MeetingTranscriber.needsAnotherPass(nil, seconds: 20, in: .en))
}

@Test func labelsWordsWithTheirSpeaker() {
    let words = [
        SpeakerWordTiming(wordTiming: WordTiming(word: " mut", tokens: [], start: 1, end: 1.2, probability: 1), speaker: .speakerId(1)),
        SpeakerWordTiming(wordTiming: WordTiming(word: " ei", tokens: [], start: 1.2, end: 1.4, probability: 1), speaker: .speakerId(1)),
    ]
    let segment = SpeakerSegment(speaker: .speakerId(1), startTime: 1, endTime: 1.4, frameRate: 100, speakerWords: words)
    #expect(SpeakerLabels.utterances(from: [segment], in: .fi) == [
        Utterance(speaker: "Puhuja 2", start: 1, end: 1.4, text: "mut ei",
                  words: [Word(start: 1, end: 1.2, text: "mut"), Word(start: 1.2, end: 1.4, text: "ei")]),
    ])
}

@Test func joinsTheWordsOfMergedPieces() {
    let pieces = [
        Utterance(speaker: "Puhuja 1", start: 0, end: 2, text: "Hei", words: [Word(start: 0, end: 1, text: "Hei")]),
        Utterance(speaker: "Puhuja 1", start: 2, end: 4, text: "kaikki.", words: [Word(start: 2, end: 3, text: "kaikki.")]),
    ]
    #expect(SpeakerLabels.merged(pieces)[0].words == [Word(start: 0, end: 1, text: "Hei"), Word(start: 2, end: 3, text: "kaikki.")])
}

@Test func addsWordTimesToAnOlderTranscriptByTrack() {
    let old = Transcript(utterances: [
        Utterance(speaker: "Puhuja 1", start: 10, end: 60, text: "Mitäs? Jes."),
        Utterance(speaker: "Minä", start: 20, end: 50, text: "Kerrotaan se."),
        Utterance(speaker: "Puhuja 2", start: 61, end: 62, text: "Joo."),
    ])
    let timed = Transcript(utterances: [
        Utterance(speaker: "Puhuja 1", start: 10, end: 60, text: "Mitäs? Jes.",
                  words: [Word(start: 10, end: 11, text: "Mitäs?"), Word(start: 59, end: 60, text: "Jes.")]),
        Utterance(speaker: "Akira", start: 20, end: 50, text: "Kerrotaan se.",
                  words: [Word(start: 20, end: 21, text: "Kerrotaan"), Word(start: 49, end: 50, text: "se.")]),
    ])
    let added = old.addingWords(from: timed, own: ["Akira", "Minä"])
    #expect(added.utterances.map(\.text) == old.utterances.map(\.text))
    #expect(added.utterances[0].words?.map(\.text) == ["Mitäs?", "Jes."])
    #expect(added.utterances[1].words?.map(\.text) == ["Kerrotaan", "se."])
    #expect(added.utterances[2].words == nil)
}

@Test func formatsTimestampsAsHoursMinutesSeconds() {
    #expect(Transcript.timestamp(3725.9) == "01:02:05")
}
