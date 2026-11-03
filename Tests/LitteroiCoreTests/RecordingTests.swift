import AVFoundation
import Foundation
import Testing
import WhisperKit
@testable import LitteroiCore

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
    FileManager.default.createFile(atPath: done.minutes.path, contents: Data())
    #expect(done.stage == .finished)
}

@Test func deletesTheAudioOfMeetingsFinishedTwoWeeksAgo() throws {
    let root = try temporaryFolder()
    let old = try MeetingFolder.create(in: root, startingAt: Date(timeIntervalSince1970: 0))
    let recent = try MeetingFolder.create(in: root, startingAt: Date(timeIntervalSince1970: 3600))
    let unfinished = try MeetingFolder.create(in: root, startingAt: Date(timeIntervalSince1970: 7200))
    for folder in [old, recent, unfinished] {
        FileManager.default.createFile(atPath: folder.mic.path, contents: Data())
        FileManager.default.createFile(atPath: folder.call.path, contents: Data())
        FileManager.default.createFile(atPath: folder.transcript.path, contents: Data())
    }
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
    #expect(FileManager.default.fileExists(atPath: old.transcript.path))
    #expect(old.stage == .finished)
    #expect(FileManager.default.fileExists(atPath: recent.mic.path))
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
