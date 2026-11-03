import AppKit
import ArgumentParser
import LitteroiCore

@main
struct LitteroiCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "litteroi-cli",
        abstract: "Litteroi suomenkielisen palaverin äänitiedostoista.",
        subcommands: [Transcribe.self, TranscribePending.self, Status.self, Pseudonymize.self, Restore.self],
        defaultSubcommand: Transcribe.self
    )
}

struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Litteroi palaverikansion tai äänitiedostot.")

    @Argument(help: "Litteroin palaverikansio tai mikrofonin äänitiedosto. Ilman --call-raitaa puhujat erotellaan mikrofonista.")
    var input: String

    @Option(help: "Puhelun äänitiedosto (Teams, Meet, Slack). Mikrofoni merkitään silloin puhujaksi Minä.")
    var call: String?

    @Option(help: "Kansio, johon transcript.md ja transcript.json kirjoitetaan. Palaverikansiolle kansio itse.")
    var output: String?

    @Option(help: "Kansio, johon mallit ladataan.")
    var models: String?

    mutating func run() async throws {
        let inputURL = URL(filePath: input)
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: inputURL.path, isDirectory: &isFolder)
        let mic: URL
        var callURL = call.map { URL(filePath: $0) }
        let folder: URL
        let title: String
        if isFolder.boolValue {
            let meeting = MeetingFolder(url: inputURL)
            mic = meeting.mic
            if callURL == nil, FileManager.default.fileExists(atPath: meeting.call.path) {
                callURL = meeting.call
            }
            folder = output.map { URL(filePath: $0) } ?? meeting.url
            title = meeting.title
        } else {
            guard let output else { throw ValidationError("Anna --output, kun litteroit äänitiedoston.") }
            mic = inputURL
            folder = URL(filePath: output)
            title = inputURL.deletingPathExtension().lastPathComponent
        }

        try await transcribe(mic: mic, call: callURL, into: folder, title: title, models: models)
    }
}

struct TranscribePending: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe-pending",
        abstract: "Litteroi litteroimattomat palaverit yksi kerrallaan. Käynnissä olevaa nauhoitusta ei kosketa."
    )

    @Option(help: "Litteroin kansio.")
    var root: String?

    @Option(help: "Kansio, johon mallit ladataan.")
    var models: String?

    mutating func run() async throws {
        var meetings = MeetingFolder.pending(in: root.map { URL(filePath: $0) } ?? MeetingFolder.defaultRoot)
        // While the app runs, it is recording the newest meeting.
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "fi.taitounited.litteroi").isEmpty {
            meetings = Array(meetings.dropLast())
        }
        var failed = false
        for meeting in meetings {
            let call = FileManager.default.fileExists(atPath: meeting.call.path) ? meeting.call : nil
            do {
                try await transcribe(mic: meeting.mic, call: call, into: meeting.url, title: meeting.title, models: models)
            } catch {
                FileHandle.standardError.write(Data("\(meeting.title): \(error.localizedDescription)\n".utf8))
                failed = true
            }
        }
        if failed { throw ExitCode.failure }
    }
}

private func transcribe(mic: URL, call: URL?, into folder: URL, title: String, models: String?) async throws {
    let transcriber = models.map { MeetingTranscriber(modelsFolder: URL(filePath: $0)) } ?? MeetingTranscriber()
    let started = Date()
    let transcript = try await transcriber.transcribe(mic: mic, call: call) { step in
        FileHandle.standardError.write(Data("\(step)...\n".utf8))
    }
    try transcript.write(to: folder, title: title)
    let seconds = Int(Date().timeIntervalSince(started))
    print("\(transcript.utterances.count) puheenvuoroa, \(seconds) s: \(folder.appending(path: "transcript.md").path)")
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Listaa palaverit vaiheineen: litteroimatta, litteroitu (odottaa Claudea) tai valmis."
    )

    @Option(help: "Litteroin kansio.")
    var root: String?

    func run() {
        for meeting in MeetingFolder.all(in: root.map { URL(filePath: $0) } ?? MeetingFolder.defaultRoot) {
            print("\(meeting.stage!.rawValue)\t\(meeting.url.path)")
        }
    }
}

struct Pseudonymize: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Peittää nimilistan nimet litteroinnista Claudelle kansioon claude/. Avain jää tiedostoon avain.json."
    )

    @Argument(help: "Palaverikansio.")
    var folder: String

    @Option(help: "Nimilista: yksi henkilö riville, muut muodot pilkun jälkeen, asiakkaat rivin [asiakkaat] alle.")
    var names: String?

    func run() throws {
        let meeting = MeetingFolder(url: URL(filePath: folder))
        let listURL = names.map { URL(filePath: $0) } ?? NameList.defaultURL
        guard FileManager.default.fileExists(atPath: listURL.path) else {
            FileHandle.standardError.write(Data("Nimilista puuttuu: \(listURL.path). Mitään ei peitetty.\n".utf8))
            throw ExitCode.failure
        }
        let transcript = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: meeting.transcriptJSON))
        let (text, key) = Pseudonymizer(names: try NameList(contentsOf: listURL)).pseudonymize(transcript.markdown(title: meeting.title))

        try FileManager.default.createDirectory(at: meeting.claudeFolder, withIntermediateDirectories: true)
        let hidden = meeting.claudeFolder.appending(path: "transcript.md")
        try text.write(to: hidden, atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(key).write(to: meeting.key)
        let people = key.names.keys.filter { $0.hasPrefix("Henkilö") }.count
        print("\(people) henkilöä ja \(key.names.count - people) asiakasta peitetty: \(hidden.path)")
    }
}

struct Restore: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Palauttaa nimet Clauden kirjoittamiin claude/-kansion tiedostoihin ja kirjoittaa ne palaverikansioon."
    )

    @Argument(help: "Palaverikansio.")
    var folder: String

    func run() throws {
        let meeting = MeetingFolder(url: URL(filePath: folder))
        let key = try JSONDecoder().decode(Pseudonymizer.Key.self, from: Data(contentsOf: meeting.key))
        let written = try FileManager.default.contentsOfDirectory(at: meeting.claudeFolder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" && $0.lastPathComponent != "transcript.md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in written {
            let restored = meeting.url.appending(path: file.lastPathComponent)
            try Pseudonymizer.restore(try String(contentsOf: file, encoding: .utf8), with: key)
                .write(to: restored, atomically: true, encoding: .utf8)
            print(restored.path)
        }
    }
}
