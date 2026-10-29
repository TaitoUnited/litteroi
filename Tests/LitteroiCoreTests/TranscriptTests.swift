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
    #expect(SpeakerLabels.name(for: .speakerId(0)) == "Puhuja 1")
    #expect(SpeakerLabels.name(for: .multiple([0, 1])) == "Päällekkäin")
    #expect(SpeakerLabels.name(for: .noMatch) == "Tuntematon")
}

@Test func labelsWordsWithTheirSpeaker() {
    let words = [
        SpeakerWordTiming(wordTiming: WordTiming(word: " mut", tokens: [], start: 1, end: 1.2, probability: 1), speaker: .speakerId(1)),
        SpeakerWordTiming(wordTiming: WordTiming(word: " ei", tokens: [], start: 1.2, end: 1.4, probability: 1), speaker: .speakerId(1)),
    ]
    let segment = SpeakerSegment(speaker: .speakerId(1), startTime: 1, endTime: 1.4, frameRate: 100, speakerWords: words)
    #expect(SpeakerLabels.utterances(from: [segment]) == [
        Utterance(speaker: "Puhuja 2", start: 1, end: 1.4, text: "mut ei"),
    ])
}

@Test func formatsTimestampsAsHoursMinutesSeconds() {
    #expect(Transcript.timestamp(3725.9) == "01:02:05")
}
