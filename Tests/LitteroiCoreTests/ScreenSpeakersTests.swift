import AppKit
import AVFoundation
import Testing
@testable import LitteroiCore
@testable import LitteroiMeetings

/// A dark screen with one tile per name, each name in white in its tile's bottom left corner as
/// Meet prints it, and Meet's outline above and below the tile of `speaking`, or with `filled`
/// that tile in the outline's colour all over, as a highlighted cell is.
private func screen(tiles: [String], speaking: String?, filled: Bool = false) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
    CVPixelBufferLockBaseAddress(buffer!, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer!, []) }
    let context = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer!), width: 640, height: 360, bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer!), space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    )!
    context.setFillColor(CGColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    defer { NSGraphicsContext.current = nil }
    for (index, name) in tiles.enumerated() {
        // Core Graphics counts rows from the bottom: the tile covers rows 40...301 from the top.
        let tile = CGRect(x: 20 + 310 * index, y: 58, width: 290, height: 262)
        let outline = CGColor(srgbRed: 0.706, green: 0.8, blue: 0.984, alpha: 1)
        context.setFillColor(name == speaking && filled ? outline : CGColor(srgbRed: 0.24, green: 0.25, blue: 0.26, alpha: 1))
        context.fill(tile)
        if name == speaking {
            context.setFillColor(outline)
            context.fill(CGRect(x: tile.minX, y: tile.maxY - 2, width: tile.width, height: 2))
            context.fill(CGRect(x: tile.minX, y: tile.minY, width: tile.width, height: 2))
        }
        NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white,
        ]).draw(at: CGPoint(x: tile.minX + 12, y: tile.minY + 14))
    }
    return buffer!
}

@Test func findsTheOutlinedTileAndReadsItsName() throws {
    let tiles = ["Clara Reichert", "Emma Hammer"]
    #expect(ScreenSpeakers.outlines(in: screen(tiles: tiles, speaking: nil)) == [])
    #expect(ScreenSpeakers.outlines(in: screen(tiles: tiles, speaking: "Emma Hammer", filled: true)) == [])

    let frame = screen(tiles: tiles, speaking: "Emma Hammer")
    let outline = ScreenSpeakers.Outline(left: 330, top: 40, right: 619, bottom: 301)
    #expect(ScreenSpeakers.outlines(in: frame) == [outline])

    let names = ScreenSpeakers.TileNames()
    #expect(try names.name(in: outline, of: frame) == "Emma Hammer")
    #expect(try names.name(in: outline, of: frame) == "Emma Hammer")
    #expect(names.recognitions == 1)

    // A layout that keeps the one speaking in the same tile swaps the name inside the outline.
    let swapped = screen(tiles: ["Clara Reichert", "Mitja Karhusaari"], speaking: "Mitja Karhusaari")
    #expect(try names.name(in: outline, of: swapped) == "Mitja Karhusaari")
    #expect(names.recognitions == 2)
}

@Test func readsWhenATileWasOutlinedFromAScreenVideo() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "litteroi-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let meeting = try MeetingFolder.create(in: root)
    #expect(try await ScreenSpeakers.read(meeting) == nil)

    let writer = try ScreenWriter(url: meeting.screen(1, from: 20), width: 640, height: 360)
    let tiles = ["Clara Reichert", "Emma Hammer"]
    for index in 0..<12 {
        writer.append(screen(tiles: tiles, speaking: index < 6 ? "Clara Reichert" : nil),
                      at: CMTime(seconds: 1000 + Double(index) / 2, preferredTimescale: 600))
        usleep(20_000)
    }
    await writer.finish(at: CMTime(seconds: 1006, preferredTimescale: 600))

    let sightings = try #require(try await ScreenSpeakers.read(meeting))
    #expect(sightings.map(\.name) == ["Clara Reichert"])
    #expect(abs(sightings[0].start - 20) < 0.1)
    #expect(abs(sightings[0].end - 23) < 0.1)
}

@Test func joinsSightingsAndCountsAMisreadNameWithItsName() {
    func sighting(_ name: String, _ start: TimeInterval, _ end: TimeInterval) -> ScreenSpeakers.Sighting {
        ScreenSpeakers.Sighting(name: name, start: start, end: end)
    }
    #expect(ScreenSpeakers.differences("Emma Hammer", "Emma Hamme") == 1)
    #expect(ScreenSpeakers.differences("Emma Hammer", "Clara Reichert") > 2)
    let sightings = [
        sighting("Emma Hammer", 10, 10.5), sighting("Emma Hamme", 10.5, 12), sighting("Emma Hammer", 12, 13),
        sighting("Clara Reichert", 12, 13), sighting("Emma Hammer", 20, 21),
    ]
    #expect(ScreenSpeakers.joined(sightings, readings: ["Emma Hammer": 3, "Emma Hamme": 1, "Clara Reichert": 1]) == [
        sighting("Emma Hammer", 10, 13), sighting("Clara Reichert", 12, 13), sighting("Emma Hammer", 20, 21),
    ])
    #expect(ScreenSpeakers.joined(sightings).first == sighting("Emma Hammer", 10, 13))
}

@Test func splitsALabelsWordsByTheTileOutlinedMeanwhile() {
    func sighting(_ name: String, _ start: TimeInterval, _ end: TimeInterval) -> ScreenSpeakers.Sighting {
        ScreenSpeakers.Sighting(name: name, start: start, end: end)
    }
    let transcript = Transcript(utterances: [
        Utterance(speaker: "Akira", start: 0, end: 10, text: "Aloitetaan."),
        Utterance(speaker: "Puhuja 1", start: 10, end: 20, text: "Mitäs? Kerron eilisestä.",
                  words: [Word(start: 10, end: 12, text: "Mitäs?"), Word(start: 14, end: 18, text: "Kerron eilisestä.")]),
        Utterance(speaker: "Puhuja 2", start: 20, end: 21, text: "Joo.", words: [Word(start: 20, end: 20.4, text: "Joo.")]),
    ])
    // The outline shows a second late, and the user's own tile says nothing about a call label.
    let report = ScreenSpeakers.report(for: transcript, from: [
        sighting("Akira Taguchi", 1, 12), sighting("Clara Reichert", 11, 17), sighting("Emma Hammer", 17, 19.5),
        sighting("Emma Hammer", 21, 21.2),
    ], fullName: "Akira Taguchi")
    #expect(report == """
    Akira\t10 s\t10 s\tAkira Taguchi 100 %
    Puhuja 1\t6 s\t6 s\tClara Reichert 67 %\tEmma Hammer 33 %
    Puhuja 2\t0 s\t0 s

    00:00:00\tAkira\t10 s\tAkira Taguchi 100 %
    00:00:10\tPuhuja 1\t6 s\tClara Reichert 67 %\tEmma Hammer 33 %

    """)
}
