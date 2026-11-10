import AppKit
import ArgumentParser
import LitteroiCore

@main
struct LitteroiCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "litteroi-cli",
        abstract: "Litteroi suomenkielisen palaverin äänitiedostoista.",
        subcommands: [Transcribe.self, TranscribePending.self, Names.self, Status.self, Page.self, Export.self, PDF.self],
        defaultSubcommand: Transcribe.self
    )
}

struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Litteroi palaverikansion tai äänitiedostot.")

    @Argument(help: "Litteroin palaverikansio tai mikrofonin äänitiedosto. Ilman --call-raitaa puhujat erotellaan mikrofonista.")
    var input: String

    @Option(help: "Puhelun äänitiedosto (Teams, Meet, Slack). Mikrofoni merkitään silloin käyttäjän etunimellä.")
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
        var screenMeeting: MeetingFolder?
        if isFolder.boolValue {
            let meeting = MeetingFolder(url: inputURL)
            mic = meeting.mic
            if callURL == nil, FileManager.default.fileExists(atPath: meeting.call.path) {
                callURL = meeting.call
            }
            folder = output.map { URL(filePath: $0) } ?? meeting.url
            title = meeting.title
            if output == nil { screenMeeting = meeting }
        } else {
            guard let output else { throw ValidationError("Anna --output, kun litteroit äänitiedoston.") }
            mic = inputURL
            folder = URL(filePath: output)
            title = inputURL.deletingPathExtension().lastPathComponent
        }

        try await transcribe(mic: mic, call: callURL, into: folder, title: title, models: models)
        if let screenMeeting { try await readScreenNames(screenMeeting) }
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
        if appRunning {
            meetings = Array(meetings.dropLast())
        }
        var failed = false
        for meeting in meetings {
            let call = FileManager.default.fileExists(atPath: meeting.call.path) ? meeting.call : nil
            do {
                try await transcribe(mic: meeting.mic, call: call, into: meeting.url, title: meeting.title, models: models)
                try await readScreenNames(meeting)
            } catch {
                FileHandle.standardError.write(Data("\(meeting.title): \(error.localizedDescription)\n".utf8))
                failed = true
            }
        }
        if failed { throw ExitCode.failure }
    }
}

private var appRunning: Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: "fi.taitounited.litteroi").isEmpty
}

private func transcribe(mic: URL, call: URL?, into folder: URL, title: String, models: String?) async throws {
    let transcriber = models.map { MeetingTranscriber(modelsFolder: URL(filePath: $0)) } ?? MeetingTranscriber()
    let started = Date()
    let transcript = try await transcriber.transcribe(mic: mic, call: call) { step in
        FileHandle.standardError.write(Data("\(step)...\n".utf8))
    } warning: { warning in
        FileHandle.standardError.write(Data("Varoitus, \(title): \(warning)\n".utf8))
    }
    try transcript.write(to: folder, title: title)
    let seconds = Int(Date().timeIntervalSince(started))
    print("\(transcript.utterances.count) puheenvuoroa, \(seconds) s: \(folder.appending(path: "transcript.md").path)")
}

struct Names: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Lukee näyttövideoista osallistujien nimet tällä Macilla ja kirjoittaa ne tiedostoon nimet-ruudulla.txt: nimi, ensimmäinen ja viimeinen kerta ruudulla sekä luettujen kuvien määrä. Litteroi tekee tämän itse."
    )

    @Argument(help: "Palaverikansio.")
    var folder: String

    mutating func run() async throws {
        try await readScreenNames(MeetingFolder(url: URL(filePath: folder)))
    }
}

/// A meeting recorded without its screens gets no names file.
private func readScreenNames(_ meeting: MeetingFolder) async throws {
    guard !meeting.screens.isEmpty else { return }
    FileHandle.standardError.write(Data("Luetaan nimiä näytöiltä...\n".utf8))
    let seen = try await ScreenNames.read(meeting)
    try ScreenNames.write(seen, to: meeting)
    print("\(seen.count) nimeä ruudulla: \(meeting.screenNames.path)")
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Listaa palaverit vaiheineen: nauhoitetaan (ääni tai ääni ja video), litteroimatta, litteroitu (odottaa Claudea) tai valmis, sitten kansio, nauhoituksen pituus, kun ääni on tallessa, ja palaverin nimi, kun se tiedetään."
    )

    @Option(help: "Litteroin kansio.")
    var root: String?

    func run() {
        let meetings = MeetingFolder.all(in: root.map { URL(filePath: $0) } ?? MeetingFolder.defaultRoot)
        // While the app runs, it is recording the newest meeting.
        let recorded = appRunning ? meetings.last : nil
        for meeting in meetings {
            let stage = meeting == recorded ? meeting.recordingMode.map { "nauhoitetaan (\($0.rawValue))" } : nil
            print([stage ?? meeting.stage!.rawValue, meeting.url.path, meeting.duration.map(length), meeting.name]
                .compactMap { $0 }.joined(separator: "\t"))
        }
    }

    private func length(_ duration: TimeInterval) -> String {
        duration < 60 ? "\(Int(duration)) s" : "\(Int((duration / 60).rounded())) min"
    }
}

struct Page: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Kirjoittaa palaverin sivun palaveri.html: kysymykset, muistio ja koko litteraatti, jonka aikaleimat soittavat palaverin äänen. Tulostaa sivun osoitteen."
    )

    @Argument(help: "Palaverikansio.")
    var folder: String

    mutating func run() async throws {
        let meeting = MeetingFolder(url: URL(filePath: folder))
        try await MeetingMedia.export(meeting)
        try MeetingPage(meeting: meeting).html.write(to: meeting.page, atomically: true, encoding: .utf8)
        print(meeting.page.absoluteString)
    }
}

struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Kirjoittaa valmiin palaverin muistion ja korjatun litteraatin yhdeksi Markdown-tiedostoksi <palaveri>.md kansioon, josta Claude Code -istunnot lukevat sen. Tulostaa tiedoston polun."
    )

    @Argument(help: "Palaverikansio.")
    var folder: String

    @Argument(help: "Kansio, johon tiedosto kirjoitetaan, kuten ~/.claude/projects/<projekti>/meetings.")
    var destination: String

    func run() throws {
        let meeting = MeetingFolder(url: URL(filePath: folder))
        guard meeting.stage == .finished, FileManager.default.fileExists(atPath: meeting.corrected.path) else {
            throw ValidationError("Palaveri ei ole valmis: siltä puuttuu muistio.md tai korjattu.md.")
        }
        let target = URL(filePath: destination)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let file = target.appending(path: "\(meeting.title).md")
        try meeting.markdown().write(to: file, atomically: true, encoding: .utf8)
        print(file.path)
    }
}

struct PDF: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Kirjoittaa valmiin palaverin korjatun litteraatin A4-PDF:ksi jaettavaksi, kuten Slackiin: otsikko, huomautus konelitteroinnista, puhujat muistiosta ja jokainen rivi aikaleimoineen. Tulostaa tiedoston polun."
    )

    @Argument(help: "Palaverikansio.")
    var folder: String

    @Argument(help: "Kansio, johon PDF kirjoitetaan, kuten ~/Downloads/litteroi.")
    var destination: String

    @Flag(help: "Ottaa mukaan koko muistion, ei vain puhujia.")
    var minutes = false

    func run() throws {
        let meeting = MeetingFolder(url: URL(filePath: folder))
        guard meeting.stage == .finished, FileManager.default.fileExists(atPath: meeting.corrected.path) else {
            throw ValidationError("Palaveri ei ole valmis: siltä puuttuu muistio.md tai korjattu.md.")
        }
        let pdf = MeetingPDF(meeting: meeting, withMinutes: minutes)
        let target = URL(filePath: destination)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let file = target.appending(path: pdf.fileName)
        try pdf.data().write(to: file, options: .atomic)
        print(file.path)
    }
}
