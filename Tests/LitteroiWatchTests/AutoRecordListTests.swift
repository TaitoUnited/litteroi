import Foundation
import Testing
@testable import LitteroiWatch

private func temporaryList() -> AutoRecordList {
    AutoRecordList(file: FileManager.default.temporaryDirectory
        .appending(path: "litteroi-\(UUID().uuidString)/automaattiset.txt"))
}

@Test func anAppOrSiteIsNewUntilItIsAdded() throws {
    let list = temporaryList()
    #expect(list.entries.isEmpty)
    #expect(!list.contains("Teams"))
    try list.add("Teams")
    try list.add("meet.google.com")
    try list.add("teams")
    #expect(list.entries == ["Teams", "meet.google.com"])
    #expect(list.contains("TEAMS"))
}

@Test func removingAnEntryKeepsTheCommentsAndTheOthers() throws {
    let list = temporaryList()
    try FileManager.default.createDirectory(at: list.file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "# Litteroidaan itsestään\nSignal\n  meet.google.com \n\nZoom\n".write(to: list.file, atomically: true, encoding: .utf8)
    #expect(list.entries == ["Signal", "meet.google.com", "Zoom"])
    #expect(!list.contains("# Litteroidaan itsestään"))
    try list.remove("Meet.Google.com")
    #expect(try String(contentsOf: list.file, encoding: .utf8) == "# Litteroidaan itsestään\nSignal\nZoom\n")
}

@Test func namesASiteByItsHostWithoutWww() {
    #expect(BrowserPage.site(of: URL(string: "https://meet.google.com/abc-defg-hij?authuser=1")!) == "meet.google.com")
    #expect(BrowserPage.site(of: URL(string: "https://www.Whereby.com/taito")!) == "whereby.com")
    #expect(BrowserPage.site(of: URL(string: "about:newtab")!) == nil)
    #expect(BrowserPage.site(of: URL(string: "file:///Users/akira/Litteroi/x/palaveri.html")!) == nil)
}

@Test func theFrontTabHoldsTheCallUnlessAnotherTabPlaysSound() {
    let front = BrowserPage.Tab(front: true, playsSound: false)
    let frontPlaying = BrowserPage.Tab(front: true, playsSound: true)
    let quiet = BrowserPage.Tab(front: false, playsSound: false)
    let playing = BrowserPage.Tab(front: false, playsSound: true)
    #expect(BrowserPage.frontTabHoldsCall([front, quiet], playingSound: false))
    #expect(BrowserPage.frontTabHoldsCall([], playingSound: false))
    #expect(!BrowserPage.frontTabHoldsCall([front, playing], playingSound: false))
    #expect(BrowserPage.frontTabHoldsCall([frontPlaying, playing], playingSound: false))
    #expect(!BrowserPage.frontTabHoldsCall([front, quiet], playingSound: true))
    #expect(BrowserPage.frontTabHoldsCall([frontPlaying], playingSound: true))
}

@Test func everyBrowserIsACallApp() {
    let names = Set(CallDetector.callApps.map(\.name))
    #expect(Set(BrowserPage.browsers.keys).isSubset(of: names))
}
