import AVFoundation
import Foundation
import Testing
import WhisperKit
@testable import LitteroiCore
@testable import LitteroiMeetings

private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "litteroi-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func sine(_ format: AVAudioFormat, seconds: Double, amplitude: Float = 0.5) -> AVAudioPCMBuffer {
    let frames = AVAudioFrameCount(format.sampleRate * seconds)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0..<Int(format.channelCount) {
        for frame in 0..<Int(frames) {
            buffer.floatChannelData![channel][frame] = amplitude * sin(2 * .pi * 440 * Float(frame) / Float(format.sampleRate))
        }
    }
    return buffer
}

@Test func namesMeetingFoldersByStartTimeAndNeverReusesOne() throws {
    let root = try temporaryFolder()
    let start = ISO8601DateFormatter().date(from: "2026-10-30T09:05:00Z")!
    let first = try MeetingFolder.create(in: root, startingAt: start)
    let second = try MeetingFolder.create(in: root, startingAt: start)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd-HHmm"
    #expect(first.title == formatter.string(from: start))
    #expect(second.title == first.title + "-2")
}

@Test func listsRecordingsWithoutTranscriptAsPending() throws {
    let root = try temporaryFolder()
    let done = try MeetingFolder.create(in: root, startingAt: Date(timeIntervalSince1970: 0))
    let waiting = try MeetingFolder.create(in: root, startingAt: Date(timeIntervalSince1970: 3600))
    _ = try MeetingFolder.create(in: root, startingAt: Date(timeIntervalSince1970: 7200))
    for folder in [done, waiting] {
        FileManager.default.createFile(atPath: folder.mic.path, contents: Data())
    }
    FileManager.default.createFile(atPath: done.transcript.path, contents: Data())
    #expect(MeetingFolder.pending(in: root) == [waiting])
    #expect(MeetingFolder.all(in: root) == [done, waiting])
    #expect(done.stage == .transcribed)
    #expect(MeetingFolder.unfinished(in: root) == [done, waiting])
    FileManager.default.createFile(atPath: done.minutes.path, contents: Data())
    #expect(done.stage == .finished)
    #expect(MeetingFolder.unfinished(in: root) == [waiting])
}

@Test func deletesTheAudioOfMeetingsFinishedTwoWeeksAgo() throws {
    let root = try temporaryFolder()
    let old = try MeetingFolder.create(in: root, startingAt: Date(timeIntervalSince1970: 0))
    let recent = try MeetingFolder.create(in: root, startingAt: Date(timeIntervalSince1970: 3600))
    let unfinished = try MeetingFolder.create(in: root, startingAt: Date(timeIntervalSince1970: 7200))
    for folder in [old, recent, unfinished] {
        FileManager.default.createFile(atPath: folder.mic.path, contents: Data())
        FileManager.default.createFile(atPath: folder.call.path, contents: Data())
        FileManager.default.createFile(atPath: folder.screen(1).path, contents: Data())
        FileManager.default.createFile(atPath: folder.screen(2).path, contents: Data())
        FileManager.default.createFile(atPath: folder.transcript.path, contents: Data())
    }
    #expect(old.screens == [old.screen(1), old.screen(2)])
    let now = Date.now
    let written: [(MeetingFolder, TimeInterval)] = [(old, 15), (recent, 13)]
    for (folder, daysAgo) in written {
        FileManager.default.createFile(atPath: folder.minutes.path, contents: Data())
        try FileManager.default.setAttributes(
            [.modificationDate: now - daysAgo * 24 * 60 * 60],
            ofItemAtPath: folder.minutes.path
        )
    }
    #expect(MeetingFolder.deleteOldAudio(in: root, now: now) == [old])
    #expect(!FileManager.default.fileExists(atPath: old.mic.path))
    #expect(!FileManager.default.fileExists(atPath: old.call.path))
    #expect(old.screens.isEmpty)
    #expect(FileManager.default.fileExists(atPath: old.transcript.path))
    #expect(old.stage == .finished)
    #expect(FileManager.default.fileExists(atPath: recent.mic.path))
    #expect(recent.screens.count == 2)
    #expect(FileManager.default.fileExists(atPath: unfinished.mic.path))
    #expect(MeetingFolder.deleteOldAudio(in: root, now: now).isEmpty)
}

@Test func writesSixteenKilohertzMonoThatWhisperCanRead() throws {
    let folder = try temporaryFolder()
    let url = folder.appending(path: "mic.caf")
    let writer = try TrackWriter(url: url)
    let stereo = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    for _ in 0..<20 {
        try writer.append(sine(stereo, seconds: 0.1))
    }
    let unclosed = folder.appending(path: "unclosed.caf")
    try FileManager.default.copyItem(at: url, to: unclosed)
    writer.close()

    let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
    #expect(abs(audio.count - 32_000) < 400)
    #expect(writer.level > 0.5)
    let partial = try AudioProcessor.loadAudioAsFloatArray(fromPath: unclosed.path)
    #expect(partial.count > 16_000)
}

@Test func readsATapAtTheRateItsDeviceRunsAt() throws {
    let url = try temporaryFolder().appending(path: "call.caf")
    let writer = try TrackWriter(url: url)
    let tap = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let format = try #require(TrackWriter.ioFormat(tap: tap.streamDescription.pointee, deviceSampleRate: 24_000))
    let delivered = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 2)!
    for _ in 0..<100 {
        let cycle = sine(delivered, seconds: 0.01)
        try withExtendedLifetime(cycle) {
            try writer.append(cycle.audioBufferList, format: format)
        }
    }
    writer.close()
    let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
    #expect(abs(audio.count - 16_000) < 400)
}

@Test func skipsABufferListLaidOutForAnotherFormat() throws {
    let writer = try TrackWriter(url: try temporaryFolder().appending(path: "call.caf"))
    let mono = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let stereo = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let interleaved = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
    var noChannels = AudioStreamBasicDescription()
    noChannels.mSampleRate = 48_000
    let empty = AVAudioFormat(streamDescription: &noChannels)!
    let buffer = sine(mono, seconds: 0.1)
    try writer.append(buffer.audioBufferList, format: stereo)
    try writer.append(buffer.audioBufferList, format: interleaved)
    try writer.append(buffer.audioBufferList, format: empty)
    #expect(writer.level == 0)
    try writer.append(buffer.audioBufferList, format: mono)
    #expect(writer.level > 0.5)
    writer.close()
}

@Test func treatsACallTrackAsSilentUnlessItHoldsTenSecondsOfSound() {
    let second = 16_000
    let silence = [Float](repeating: 0, count: 60 * second)
    var ding = silence
    for index in 0..<(2 * second) {
        ding[index] = 0.3 * sin(Float(index) / 10)
    }
    var speech = silence
    for index in 0..<(20 * second) {
        speech[index] = 0.3 * sin(Float(index) / 10)
    }
    #expect(!MeetingTranscriber.hasSound(silence))
    #expect(!MeetingTranscriber.hasSound(ding))
    #expect(MeetingTranscriber.hasSound(speech))
}

@Test func warnsWhenTheCallTrackIsFarFromTheMicTracksLength() {
    let second = 16_000
    #expect(MeetingTranscriber.lengthWarning(mic: 512 * second, call: 509 * second) == nil)
    #expect(MeetingTranscriber.lengthWarning(mic: 30 * second, call: 22 * second) == nil)
    #expect(MeetingTranscriber.lengthWarning(mic: 512 * second, call: 256 * second)?.hasPrefix("Puhelun raita on 256 s ja mikrofonin 512 s.") == true)
    #expect(MeetingTranscriber.lengthWarning(mic: 512 * second, call: 1024 * second) != nil)
}

@Test func rendersAPageWhoseTimestampsPlayTheMeeting() {
    let page = MeetingPage(
        title: "2026-11-04-0845",
        questions: "# Kysymykset\n\n15. **Puhuja 1: Clara?**\n   - [00:04:05] **Puhuja 4:** Kiitos Klara.\n16. Kuka <muu>?\n",
        transcript: "# 2026-11-04-0845\n\n[00:00:06] **Minä:** Huomenta.\n\n[00:00:06] **Puhuja 4:** Huomenta [?].\n",
        audio: "palaveri.m4a"
    ).html
    #expect(page.contains(##"<p class="line s0" id="t-00-00-06"><a class="t" href="#t-00-00-06" data-t="6">00:00:06</a> <b>Minä:</b> Huomenta.</p>"##))
    #expect(page.contains(##"id="t-00-00-06-2""##))
    #expect(page.contains(##"<ol start="15"><li>"##))
    #expect(page.contains(##"<a class="t clip" href="#t-00-04-05" data-t="245">00:04:05</a> <b>Puhuja 4:</b> Kiitos Klara."##))
    #expect(page.contains("Kuka &lt;muu&gt;?"))
    #expect(page.contains(##"<form id="answers" data-folder="~/Litteroi/2026-11-04-0845" data-name="">"##))
    #expect(page.contains(##"<textarea class="answer" data-q="15""##))
    #expect(page.contains(##"<textarea class="answer" data-q="16""##))
    #expect(page.contains(##"<ol start="16"><li>"##))
    #expect(page.contains(##"id="make-prompt""##))
    #expect(page.contains(##"<div class="keys" id="keys" hidden><span class="browse"><kbd>j</kbd> seuraava</span><span class="browse"><kbd>k</kbd> edellinen</span>"##))
    #expect(page.contains(##"<kbd>välilyönti</kbd> toista tai pysäytä</span><span class="browse"><kbd>l</kbd> kysytty kohta</span><span class="browse"><kbd>n</kbd> seuraava pätkä"##))
    #expect(page.contains("function nextClip()") && page.contains("function askedClip()"))
    #expect(page.contains(##"<span class="type"><kbd>Enter</kbd> seuraava kysymys, tyhjä kenttä on kyllä</span><span class="type"><kbd>Shift+Enter</kbd> uusi rivi</span>"##))
    #expect(page.contains(##"field.value = "kyllä";"##))
    #expect(page.contains(##"<span class="type"><kbd>Ctrl+P</kbd> toista tai pysäytä</span><span class="type"><kbd>Ctrl+L</kbd> kysytty kohta</span><span class="type"><kbd>Ctrl+N</kbd> seuraava pätkä</span><span class="type"><kbd>Esc</kbd> pois kentästä</span></div>"##))
    #expect(!page.contains("glossary") && !page.contains("Sanastoon") && !page.contains("Muuta"))
    #expect(page.contains("if (!location.hash) answer(true);"))
    #expect(page.contains(##"<audio id="audio" controls preload="metadata" src="palaveri.m4a">"##))
    #expect(!page.contains("muistio\""))
    #expect(!page.contains("<video"))

    let silent = MeetingPage(title: "2026-11-04-0845", questions: "1. Kuka?\n", transcript: "").html
    #expect(silent.contains(##"<kbd>c</kbd> kopioi vastaukset"##))
    #expect(!silent.contains("välilyönti") && !silent.contains("Ctrl+P"))
}

@Test func startsAQuotedLineWhereItsQuotedPartIsSaid() {
    let heard = ["Mitäs?", "Onko", "jotain", "akuuttia?", "Jännittävää!", "Ja", "Mitja,", "jääksää", "vähän", "sekuntiksi", "tähän", "vielä,"]
    let line = TimedLine(start: 600, end: 640, words: heard.enumerated().map {
        TimedLine.Word(start: 600 + Double($0.offset) * 3, end: 602.5 + Double($0.offset) * 3, text: $0.element)
    })
    let page = MeetingPage(
        title: "2026-11-10-0841",
        questions: "1. **Puhuja 1**: Emma? Other line: 00:10:00.\n    - [00:10:00] **Puhuja 1:** ... Ja Mitja, jääksä vähän sekunniksi tähän [epäselvä] vielä,\n    - [00:09:00] **Akira:** Joo.\n",
        transcript: "",
        lines: [TimedLine(start: 600.4, end: 601), line]
    ).html
    #expect(page.contains(##"Other line: <a class="t" href="#t-00-10-00" data-t="600">00:10:00</a>."##))
    #expect(page.contains(##"<a class="t clip asked" href="#t-00-10-00" data-t="615" data-end="635.5">00:10:00</a> <b>Puhuja 1:</b>"##))
    #expect(page.contains(##"<a class="t clip" href="#t-00-09-00" data-t="540">00:09:00</a> <b>Akira:</b> Joo."##))
    #expect(line.clip(of: "Aivan muuta puhetta tässä")?.clip == nil)
    #expect(line.clip(of: "Mitäs? Onko jotain akuuttia? ... vähän sekunniksi ...")?.clip == Clip(start: 600, end: 629.5))
}

@Test func ordersScreenVideosByTheSecondTheyStartAt() throws {
    let meeting = try MeetingFolder.create(in: try temporaryFolder())
    let older = meeting.url.appending(path: "screen-1.mov")
    for url in [meeting.screen(1, from: 130), meeting.screen(1, from: 20), older] {
        FileManager.default.createFile(atPath: url.path, contents: Data())
    }
    #expect(meeting.screens == [older, meeting.screen(1, from: 20), meeting.screen(1, from: 130)])
    #expect(MeetingFolder.start(of: meeting.browserCopy(of: meeting.screen(1, from: 130))) == 130)
    #expect(MeetingFolder.start(of: older) == 0)
    #expect(meeting.recordingMode == nil)
    try MeetingFolder.RecordingMode.audioAndVideo.rawValue.write(to: meeting.recordingModeFile, atomically: true, encoding: .utf8)
    #expect(meeting.recordingMode == .audioAndVideo)

    let page = MeetingPage(title: meeting.title, transcript: "", screens: ["screen-1-0.mp4", "screen-1-130.mp4"]).html
    #expect(page.contains(##"data-start="130" src="screen-1-130.mp4""##))
    #expect(page.contains(##"data-start="0" src="screen-1-0.mp4""##))
}

@Test func keepsOnlyNamesLongOnTheScreen() {
    #expect(ScreenNames.personName("Mitja Karhusaari (Guest)") == "Mitja Karhusaari")
    #expect(ScreenNames.personName("Anna-Liisa Mäki") == "Anna-Liisa Mäki")
    for line in ["Akira", "Enter Password", "Viral Vegans x Taito United", "SPRINT Review", "Tiistai 4.11."] {
        #expect(ScreenNames.personName(line) == nil)
    }
    let seen = [
        ScreenNames.Seen(name: "Mitja Karhusaari", first: 90, last: 1410, samples: 113),
        ScreenNames.Seen(name: "Mitia Karhusaari", first: 190, last: 1070, samples: 3),
        ScreenNames.Seen(name: "Clara Reichert", first: 60, last: 1410, samples: 118),
        ScreenNames.Seen(name: "Kickoff Notes", first: 450, last: 830, samples: 9),
        ScreenNames.Seen(name: "Ohi Menevä", first: 0, last: 60, samples: 7),
    ]
    #expect(ScreenNames.kept(seen, interval: 10) == [
        ScreenNames.Seen(name: "Clara Reichert", first: 60, last: 1410, samples: 118),
        ScreenNames.Seen(name: "Mitja Karhusaari", first: 90, last: 1410, samples: 116),
    ])
}

@Test func copiesAFinishedMeetingAsOneMarkdownFile() throws {
    let meeting = try MeetingFolder.create(in: try temporaryFolder())
    try "# Muistio \(meeting.title)\n\n## Puhujat\n\n- Puhuja 1: Clara.\n"
        .write(to: meeting.minutes, atomically: true, encoding: .utf8)
    try "# \(meeting.title)\n\n[00:00:06] **Clara:** Huomenta.\n\n[00:00:08] **Minä:** [ei puhetta]\n"
        .write(to: meeting.corrected, atomically: true, encoding: .utf8)
    let markdown = try meeting.markdown()
    #expect(markdown.hasPrefix("---\nmeeting: \(meeting.title)\nfolder: \(meeting.url.path)\n"))
    #expect(markdown.contains("\n# Muistio \(meeting.title)\n\n## Puhujat\n"))
    #expect(markdown.contains("\n## Litteraatti\n\n[00:00:06] **Clara:** Huomenta.\n\n[00:00:08] **Minä:** [ei puhetta]\n"))
    #expect(!markdown.contains("\n# \(meeting.title)\n"))
}

@Test func mixesBothTracksIntoOneFileForTheBrowser() async throws {
    let meeting = try MeetingFolder.create(in: try temporaryFolder())
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    for url in [meeting.mic, meeting.call] {
        let writer = try TrackWriter(url: url)
        try writer.append(sine(format, seconds: 2))
        writer.close()
    }
    try await MeetingMedia.export(meeting)
    let duration = try await AVURLAsset(url: meeting.listening).load(.duration)
    #expect(abs(duration.seconds - 2) < 0.2)
    let written = try meeting.listening.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    try await MeetingMedia.export(meeting)
    #expect(try meeting.listening.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == written)
}
