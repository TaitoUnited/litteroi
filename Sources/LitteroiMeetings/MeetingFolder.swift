import Foundation

/// One meeting under `~/Litteroi/<yyyy-mm-dd-hhmm>/`: the two audio tracks, a video of each
/// display, the transcript and, once Claude has finished it, the corrected transcript and the
/// minutes. `palaveri.html` shows them in a browser, with the tracks mixed into `palaveri.m4a`
/// and each video copied as `screen-<n>.mp4`, which Firefox plays.
public struct MeetingFolder: Hashable, Sendable {
    public static let defaultRoot = URL.homeDirectory.appending(path: "Litteroi")

    public enum Stage: String, Sendable {
        case recorded = "litteroimatta"
        case transcribed = "litteroitu"
        case finished = "valmis"
    }

    /// What the app is recording: the microphone and the call, and maybe the screens too. The call
    /// watcher switches the screens of a recording going on with these distributed notifications.
    public enum RecordingMode: String, Sendable {
        case audio = "ääni"
        case audioAndVideo = "ääni ja video"

        public var notification: Notification.Name {
            Notification.Name(self == .audio ? "fi.taitounited.litteroi.audio" : "fi.taitounited.litteroi.video")
        }
    }

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var title: String { url.lastPathComponent }
    /// What the meeting was, such as its calendar event's title, written by the skill.
    public var nameFile: URL { url.appending(path: "nimi.txt") }
    public var name: String? { Self.text(of: nameFile) }
    /// The kind of meeting in a word, then a short name for it, such as `daily sis-meks`, which the
    /// shared PDF is named after; written by the skill.
    public var shortNameFile: URL { url.appending(path: "lyhenne.txt") }
    public var shortName: String? { Self.text(of: shortNameFile) }
    static func text(of file: URL) -> String? {
        let text = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }
    public var mic: URL { url.appending(path: "mic.caf") }
    public var call: URL { url.appending(path: "call.caf") }
    /// How long the mic track runs, from its size at 16 kHz mono 16-bit; nil once it is deleted.
    public var duration: TimeInterval? {
        (try? mic.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map { TimeInterval($0) / 32_000 }
    }
    /// The video of display `number` from `second` of the meeting on. A recording made before the
    /// screen could be switched on and off midway has one video per display, `screen-<n>.mov`.
    public func screen(_ number: Int, from second: Int = 0) -> URL {
        url.appending(path: "screen-\(number)-\(second).mov")
    }
    /// Every screen video, earliest first.
    public var screens: [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.filter { $0.hasPrefix("screen-") && $0.hasSuffix(".mov") }
            .map { url.appending(path: $0) }
            .sorted { (Self.start(of: $0), $0.lastPathComponent) < (Self.start(of: $1), $1.lastPathComponent) }
    }
    /// The second of the meeting a screen video or its browser copy starts at.
    public static func start(of screen: URL) -> Int {
        let parts = screen.deletingPathExtension().lastPathComponent.split(separator: "-")
        return parts.count == 3 ? Int(parts[2]) ?? 0 : 0
    }
    /// Written by the app while it records the meeting, removed when it stops.
    public var recordingModeFile: URL { url.appending(path: ".nauhoitus") }
    public var recordingMode: RecordingMode? {
        (try? String(contentsOf: recordingModeFile, encoding: .utf8)).flatMap(RecordingMode.init(rawValue:))
    }
    public var transcript: URL { url.appending(path: "transcript.md") }
    public var transcriptJSON: URL { url.appending(path: "transcript.json") }
    public var corrected: URL { url.appending(path: "korjattu.md") }
    public var minutes: URL { url.appending(path: "muistio.md") }
    /// The skill's questions about who spoke, until the minutes are written.
    public var questions: URL { url.appending(path: "kysymykset.md") }
    public var page: URL { url.appending(path: "palaveri.html") }
    /// What `litteroi-cli live` heard while the meeting was being recorded, without speakers.
    public var live: URL { url.appending(path: "live.md") }
    /// The names read from the screen videos, which the skill reads in place of the videos.
    public var screenNames: URL { url.appending(path: "nimet-ruudulla.txt") }
    /// Whose tile the call app outlined while each speaker label spoke, read from the screen videos.
    public var screenSpeakers: URL { url.appending(path: "puhujat-ruudulla.txt") }
    public var listening: URL { url.appending(path: "palaveri.m4a") }
    public func browserCopy(of screen: URL) -> URL { screen.deletingPathExtension().appendingPathExtension("mp4") }

    /// The finished meeting as one Markdown file for Claude Code sessions: where it lives, the
    /// minutes, then the corrected transcript under the minutes' own heading level.
    public func markdown() throws -> String {
        let minutes = try String(contentsOf: minutes, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = try String(contentsOf: corrected, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false)
        let transcript = lines.drop { $0.hasPrefix("# ") || $0.isEmpty }.joined(separator: "\n")
        let heading = minutes.hasPrefix("# Minutes") ? "Transcript" : "Litteraatti"
        return """
        ---
        meeting: \(title)\(name.map { "\nname: \($0)" } ?? "")
        folder: \(url.path)
        page: \(page.absoluteString)
        ---

        \(minutes)

        ## \(heading)

        \(transcript)

        """
    }

    /// Nil for a folder without a recording. A finished meeting stays finished once its audio
    /// is deleted.
    public var stage: Stage? {
        let files = FileManager.default
        if files.fileExists(atPath: minutes.path) { return .finished }
        if files.fileExists(atPath: transcript.path) { return .transcribed }
        return files.fileExists(atPath: mic.path) ? .recorded : nil
    }

    /// Creates the folder for a meeting that starts at `date`. A second meeting in the same
    /// minute gets a suffix, so no recording is overwritten.
    public static func create(in root: URL = defaultRoot, startingAt date: Date = .now) throws -> MeetingFolder {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let name = formatter.string(from: date)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for number in 1...99 {
            let url = root.appending(path: number == 1 ? name : "\(name)-\(number)")
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                return MeetingFolder(url: url)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// Every meeting with a recording, oldest first.
    public static func all(in root: URL = defaultRoot) -> [MeetingFolder] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names
            .map { MeetingFolder(url: root.appending(path: $0)) }
            .filter { $0.stage != nil }
            .sorted { $0.title < $1.title }
    }

    /// Meetings that have a recording but no transcript yet, oldest first.
    public static func pending(in root: URL = defaultRoot) -> [MeetingFolder] {
        all(in: root).filter { $0.stage == .recorded }
    }

    /// Meetings the litteroi skill has not finished, transcribed or not, oldest first.
    public static func unfinished(in root: URL = defaultRoot) -> [MeetingFolder] {
        all(in: root).filter { $0.stage != .finished }
    }

    /// How long the audio and screen videos of a finished meeting are kept, counted from when its
    /// minutes were written. Transcripts and minutes are kept.
    public static let audioKept: TimeInterval = 14 * 24 * 60 * 60

    /// Deletes both tracks, the screen videos and their browser copies of every meeting whose minutes are older than
    /// `audioKept`, and returns those meetings. A meeting not finished yet keeps its recordings.
    @discardableResult
    public static func deleteOldAudio(in root: URL = defaultRoot, now: Date = .now) -> [MeetingFolder] {
        let files = FileManager.default
        return all(in: root).filter { meeting in
            guard meeting.stage == .finished,
                  files.fileExists(atPath: meeting.mic.path) || files.fileExists(atPath: meeting.call.path)
                    || !meeting.screens.isEmpty,
                  let written = try? meeting.minutes.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(written) > audioKept
            else { return false }
            try? files.removeItem(at: meeting.mic)
            try? files.removeItem(at: meeting.call)
            try? files.removeItem(at: meeting.listening)
            for screen in meeting.screens {
                try? files.removeItem(at: screen)
                try? files.removeItem(at: meeting.browserCopy(of: screen))
            }
            return true
        }
    }
}
