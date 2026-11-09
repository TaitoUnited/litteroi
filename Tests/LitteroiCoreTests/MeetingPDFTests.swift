import Foundation
import PDFKit
import Testing
@testable import LitteroiMeetings

@Test func writesTheTranscriptAsAPDFNamedAfterTheMeeting() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let meeting = MeetingFolder(url: root.appending(path: "2026-11-05-0844"))
    try FileManager.default.createDirectory(at: meeting.url, withIntermediateDirectories: true)
    try "Sisäinen: meks daily\n".write(to: meeting.nameFile, atomically: true, encoding: .utf8)
    try """
    # Muistio 2026-11-05-0844: Sisäinen: meks daily

    ## Puhujat

    - Emma: Emma Hammer.

    ## Tiivistelmä

    Käytiin läpi **testit**.

    """.write(to: meeting.minutes, atomically: true, encoding: .utf8)
    let lines = (1...200).map { "[00:\(String(format: "%02d", $0 / 60)):\(String(format: "%02d", $0 % 60))] **Emma:** Rivi \($0) kertoo jotain." }
    try "# 2026-11-05-0844\n\n\(lines.joined(separator: "\n\n"))\n".write(to: meeting.corrected, atomically: true, encoding: .utf8)

    let speakers = MeetingPDF(meeting: meeting)
    #expect(speakers.fileName == "thu-5-nov-2026-sisainen-meks-daily-transcription.pdf")
    try "daily sis-meks\n".write(to: meeting.shortNameFile, atomically: true, encoding: .utf8)
    #expect(speakers.fileName == "daily-thu-5-nov-2026-sis-meks-transcription.pdf")
    let document = try #require(PDFDocument(data: try speakers.data()))
    let text = try #require(document.string)
    #expect(document.pageCount > 1)
    #expect(text.contains("Litterointi: Sisäinen: meks daily 5.11.2026"))
    #expect(text.contains("Emma: Emma Hammer."))
    #expect(text.contains("00:03:20 Emma: Rivi 200 kertoo jotain."))
    #expect(!text.contains("Tiivistelmä"))

    let whole = try #require(PDFDocument(data: try MeetingPDF(meeting: meeting, withMinutes: true).data())?.string)
    #expect(whole.contains("Käytiin läpi testit."))
}
