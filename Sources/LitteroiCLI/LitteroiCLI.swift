import ArgumentParser
import Foundation
import LitteroiCore

@main
struct LitteroiCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "litteroi-cli",
        abstract: "Litteroi suomenkielisen palaverin äänitiedostoista."
    )

    @Argument(help: "Mikrofonin äänitiedosto. Ilman --call-raitaa puhujat erotellaan tästä.")
    var mic: String

    @Option(help: "Puhelun äänitiedosto (Teams, Meet, Slack). Mikrofoni merkitään silloin puhujaksi Minä.")
    var call: String?

    @Option(help: "Kansio, johon transcript.md ja transcript.json kirjoitetaan.")
    var output: String

    @Option(help: "Kansio, johon mallit ladataan.")
    var models: String?

    mutating func run() async throws {
        let micURL = URL(filePath: mic)
        let transcriber = models.map { MeetingTranscriber(modelsFolder: URL(filePath: $0)) } ?? MeetingTranscriber()
        let started = Date()
        let transcript = try await transcriber.transcribe(mic: micURL, call: call.map { URL(filePath: $0) }) { step in
            FileHandle.standardError.write(Data("\(step)...\n".utf8))
        }
        let folder = URL(filePath: output)
        try transcript.write(to: folder, title: micURL.deletingPathExtension().lastPathComponent)
        let seconds = Int(Date().timeIntervalSince(started))
        print("\(transcript.utterances.count) puheenvuoroa, \(seconds) s: \(folder.appending(path: "transcript.md").path)")
    }
}
