import AVFoundation
import Vision

/// Reads from the screen videos whose tile the call app outlined as speaking, on this Mac, so the
/// skill can tell which participant a speaker label is without opening the videos. Google Meet
/// draws a light outline around the tile its sound comes from and prints that participant's name
/// in the tile's bottom left corner; other call apps are not read yet.
public enum ScreenSpeakers {
    /// A stretch of the meeting during which the tile with `name` on it was outlined.
    public struct Sighting: Equatable, Sendable {
        public var name: String
        public var start: TimeInterval
        public var end: TimeInterval
    }

    /// An outlined tile in a frame, in pixels from the top left.
    struct Outline: Equatable {
        var left: Int
        var top: Int
        var right: Int
        var bottom: Int
    }

    /// Every frame of each video. An outlined tile with no name to read in it is left out. A
    /// video that cannot be opened is passed to `unreadable` and left out; nil when none could be
    /// opened.
    public static func read(_ meeting: MeetingFolder, unreadable: (URL) -> Void = { _ in }) async throws -> [Sighting]? {
        var sightings: [Sighting] = []
        var readings: [String: Int] = [:]
        var opened = false
        for screen in meeting.screens {
            let asset = AVURLAsset(url: screen)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let duration = try? await asset.load(.duration).seconds,
                  let reader = try? AVAssetReader(asset: asset)
            else {
                unreadable(screen)
                continue
            }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            reader.add(output)
            guard reader.startReading() else {
                unreadable(screen)
                continue
            }
            opened = true
            let start = TimeInterval(MeetingFolder.start(of: screen))
            let tiles = TileNames()
            var frames: [(time: TimeInterval, names: [String])] = []
            while let sample = output.copyNextSampleBuffer() {
                guard let frame = CMSampleBufferGetImageBuffer(sample) else { continue }
                let names = try outlines(in: frame).compactMap { try tiles.name(in: $0, of: frame) }
                frames.append((CMSampleBufferGetPresentationTimeStamp(sample).seconds, names))
            }
            for (index, frame) in frames.enumerated() {
                let next = index + 1 < frames.count ? frames[index + 1].time : duration
                let end = min(next, frame.time + frameLasts)
                for name in Set(frame.names) {
                    sightings.append(Sighting(name: name, start: start + frame.time, end: start + end))
                }
            }
            readings.merge(tiles.readings, uniquingKeysWith: +)
        }
        return opened ? joined(sightings, readings: readings) : nil
    }

    /// A still screen's frame is repeated every `ScreenWriter.repeatInterval`, so a frame with no
    /// other for longer than this is where the recording stood still or the video was cut.
    static let frameLasts: TimeInterval = ScreenWriter.repeatInterval + 1

    /// Sightings of one name that follow each other without a gap as one, after a misread name,
    /// such as "Emma Hamme", is counted with the name it is closest to. A misreading stays for as
    /// long as its tile looks the same, so of two spellings the one read more times in `readings`
    /// is the name, and the one seen for longer when both were read as often.
    static func joined(_ sightings: [Sighting], readings: [String: Int] = [:]) -> [Sighting] {
        var seconds: [String: TimeInterval] = [:]
        for sighting in sightings { seconds[sighting.name, default: 0] += sighting.end - sighting.start }
        var spelling: [String: String] = [:]
        var names: [String] = []
        for name in seconds.keys.sorted(by: { (readings[$0] ?? 0, seconds[$0]!, $0) > (readings[$1] ?? 0, seconds[$1]!, $1) }) {
            spelling[name] = names.first { differences($0, name) <= 2 } ?? name
            if spelling[name] == name { names.append(name) }
        }
        var result: [Sighting] = []
        var last: [String: Int] = [:]
        for var sighting in sightings.sorted(by: { $0.start < $1.start }) {
            sighting.name = spelling[sighting.name] ?? sighting.name
            if let index = last[sighting.name], result[index].end >= sighting.start - 0.01 {
                result[index].end = max(result[index].end, sighting.end)
            } else {
                last[sighting.name] = result.count
                result.append(sighting)
            }
        }
        return result
    }

    /// How many letters must be changed, added or dropped to turn one name into the other.
    static func differences(_ name: String, _ other: String) -> Int {
        let a = Array(name), b = Array(other)
        var row = Array(0...b.count)
        for i in 0..<a.count {
            var corner = row[0]
            row[0] = i + 1
            for j in 0..<b.count {
                let above = row[j + 1]
                row[j + 1] = min(corner + (a[i] == b[j] ? 0 : 1), above + 1, row[j] + 1)
                corner = above
            }
        }
        return row[b.count]
    }

    // MARK: - The outline

    private struct Colour {
        var red: Int
        var green: Int
        var blue: Int

        init(_ pixel: UnsafePointer<UInt8>) {
            blue = Int(pixel[0])
            green = Int(pixel[1])
            red = Int(pixel[2])
        }

        /// A light tint, as Meet's outline is: #b4ccfb around a tile that shows a camera, and a
        /// tint of the tile's own colour around one that shows a picture, such as #feb9ca around
        /// a dark red one. A darker outline, #888cdc, likely that of Teams, stays out: its small
        /// tiles cut the names short, and in the one such meeting recorded by 17.11.2026 the four
        /// lines with a name to read had another speaker in the minutes.
        var isTint: Bool {
            let most = max(red, green, blue), least = min(red, green, blue)
            return most >= 200 && least >= 145 && most - least >= 40
        }

        var light: Int { red + green + blue }

        func near(_ other: Colour) -> Bool {
            abs(red - other.red) <= 40 && abs(green - other.green) <= 40 && abs(blue - other.blue) <= 40
        }
    }

    /// Tiles at least 100 by 50 pixels between a thin top and a thin bottom line of one light
    /// tint over the same columns, with something else than that tint between them, which a
    /// highlighted cell of a shared spreadsheet has not. The sides are not looked for: where a
    /// tile shows a camera, the video keeps none of the outline at the tile's left and right edge.
    static func outlines(in frame: CVPixelBuffer) -> [Outline] {
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        guard let address = CVPixelBufferGetBaseAddress(frame) else { return [] }
        let width = CVPixelBufferGetWidth(frame), height = CVPixelBufferGetHeight(frame)
        let rowBytes = CVPixelBufferGetBytesPerRow(frame)
        let base = address.assumingMemoryBound(to: UInt8.self)
        func colour(_ x: Int, _ y: Int) -> Colour { Colour(base + y * rowBytes + x * 4) }

        // Horizontal runs of one tint, a few pixels of something else allowed inside, joined over
        // the rows of a line's thickness. An edge keeps the colour of its lightest row.
        var edges: [(box: Outline, colour: Colour)] = []
        for y in 0..<height {
            var x = 0
            while x < width {
                let first = colour(x, y)
                guard first.isTint else {
                    x += 1
                    continue
                }
                let left = x
                var right = x, gap = 0
                x += 1
                while x < width, gap <= 4 {
                    let next = colour(x, y)
                    if next.isTint, next.near(first) {
                        right = x
                        gap = 0
                    } else {
                        gap += 1
                    }
                    x += 1
                }
                guard right - left >= 100 else { continue }
                let middle = colour((left + right) / 2, y)
                if let index = edges.lastIndex(where: {
                    $0.box.bottom >= y - 2 && abs($0.box.left - left) <= 6 && abs($0.box.right - right) <= 6
                }) {
                    edges[index].box.bottom = y
                    edges[index].box.left = min(edges[index].box.left, left)
                    edges[index].box.right = max(edges[index].box.right, right)
                    if middle.light > edges[index].colour.light { edges[index].colour = middle }
                } else {
                    edges.append((Outline(left: left, top: y, right: right, bottom: y), middle))
                }
            }
        }
        edges = edges.filter { $0.box.bottom - $0.box.top < 10 }

        func filled(_ tile: Outline, with tint: Colour) -> Bool {
            var alike = 0
            for row in 1...3 {
                for column in 1...3 {
                    let x = tile.left + (tile.right - tile.left) * column / 4
                    let y = tile.top + (tile.bottom - tile.top) * row / 4
                    if colour(x, y).near(tint) { alike += 1 }
                }
            }
            return alike >= 5
        }
        var found: [Outline] = []
        var used = Set<Int>()
        for (index, top) in edges.enumerated() where !used.contains(index) {
            guard let pair = edges.indices.first(where: {
                $0 > index && !used.contains($0) && abs(edges[$0].box.left - top.box.left) <= 8
                    && abs(edges[$0].box.right - top.box.right) <= 8 && edges[$0].box.top - top.box.bottom >= 50
                    && edges[$0].colour.near(top.colour)
            }) else { continue }
            let tile = Outline(left: top.box.left, top: top.box.top, right: top.box.right, bottom: edges[pair].box.bottom)
            guard !filled(tile, with: top.colour) else { continue }
            used.insert(index)
            used.insert(pair)
            found.append(tile)
        }
        return found
    }

    // MARK: - The name in a tile

    /// Reads the name in the bottom left corner of an outlined tile. Text recognition takes far
    /// longer than finding the outline, and the same tile stays outlined for many frames, so a
    /// name is read again only when the white pixels where it was read have changed: Meet prints
    /// names in white, and a layout that shows the one speaking in a fixed place swaps the name
    /// while the outline stays.
    final class TileNames {
        private struct Known {
            var tile: Outline
            var name: String?
            var area: Outline
            var marks: [Int]
        }

        private var known: [Known] = []
        /// How many times each name was read.
        private(set) var readings: [String: Int] = [:]
        private(set) var recognitions = 0

        func name(in tile: Outline, of frame: CVPixelBuffer) throws -> String? {
            let index = known.firstIndex {
                abs($0.tile.left - tile.left) <= 4 && abs($0.tile.right - tile.right) <= 4
                    && abs($0.tile.top - tile.top) <= 4 && abs($0.tile.bottom - tile.bottom) <= 4
            }
            if let index, Self.alike(known[index].marks, Self.marks(in: known[index].area, of: frame)) {
                return known[index].name
            }
            let height = tile.bottom - tile.top
            let corner = Outline(left: tile.left, top: tile.bottom - min(height, max(70, height / 4)),
                                 right: tile.right, bottom: tile.bottom)
            let (name, area) = try recognised(in: corner, of: frame)
            let entry = Known(tile: tile, name: name, area: area ?? corner, marks: Self.marks(in: area ?? corner, of: frame))
            if let index {
                known[index] = entry
            } else {
                known.append(entry)
                if known.count > 24 { known.removeFirst() }
            }
            return name
        }

        /// The name that starts in the left third of `corner`, and where it stands.
        private func recognised(in corner: Outline, of frame: CVPixelBuffer) throws -> (String?, Outline?) {
            recognitions += 1
            let width = Double(CVPixelBufferGetWidth(frame)), height = Double(CVPixelBufferGetHeight(frame))
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["fi-FI", "en-US"]
            request.usesLanguageCorrection = false
            // Vision counts from the bottom left, in fractions of the frame.
            let region = CGRect(x: Double(corner.left) / width, y: 1 - Double(corner.bottom) / height,
                                width: Double(corner.right - corner.left) / width,
                                height: Double(corner.bottom - corner.top) / height)
            request.regionOfInterest = region
            try VNImageRequestHandler(cvPixelBuffer: frame).perform([request])
            for line in request.results ?? [] where line.boundingBox.minX < 1 / 3 {
                guard let text = line.topCandidates(1).first?.string, let name = ScreenNames.personName(text) else { continue }
                readings[name, default: 0] += 1
                let box = line.boundingBox
                let area = Outline(
                    left: Int((region.minX + box.minX * region.width) * width),
                    top: Int((1 - region.minY - box.maxY * region.height) * height),
                    right: Int((region.minX + box.maxX * region.width) * width),
                    bottom: Int((1 - region.minY - box.minY * region.height) * height)
                )
                return (name, area)
            }
            return (nil, nil)
        }

        /// How many near-white pixels each strip of four columns of `area` holds.
        static func marks(in area: Outline, of frame: CVPixelBuffer) -> [Int] {
            CVPixelBufferLockBaseAddress(frame, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
            guard let address = CVPixelBufferGetBaseAddress(frame) else { return [] }
            let rowBytes = CVPixelBufferGetBytesPerRow(frame)
            let base = address.assumingMemoryBound(to: UInt8.self)
            let left = max(0, area.left), right = min(CVPixelBufferGetWidth(frame) - 1, area.right)
            let top = max(0, area.top), bottom = min(CVPixelBufferGetHeight(frame) - 1, area.bottom)
            guard left <= right, top <= bottom else { return [] }
            var marks = [Int](repeating: 0, count: (right - left) / 4 + 1)
            for y in top...bottom {
                for x in left...right {
                    let pixel = base + y * rowBytes + x * 4
                    if min(pixel[0], pixel[1], pixel[2]) >= 200 { marks[(x - left) / 4] += 1 }
                }
            }
            return marks
        }

        static func alike(_ marks: [Int], _ other: [Int]) -> Bool {
            guard marks.count == other.count else { return false }
            let difference = zip(marks, other).reduce(0) { $0 + abs($1.0 - $1.1) }
            return difference * 8 <= marks.reduce(0, +) + other.reduce(0, +)
        }
    }

    // MARK: - Whose tile was outlined while a label spoke

    /// How long a speaker label's words ran, for how much of that an outlined tile was on screen,
    /// and how those seconds split between the names on the tiles.
    public struct Evidence: Equatable, Sendable {
        public var speech: TimeInterval = 0
        public var outlined: TimeInterval = 0
        public var names: [String: TimeInterval] = [:]

        mutating func add(_ other: Evidence) {
            speech += other.speech
            outlined += other.outlined
            names.merge(other.names, uniquingKeysWith: +)
        }

        /// The names by their share of the outlined seconds, those under `least` left out, and
        /// none for under half a second of outline.
        func shares(least: Double) -> [String] {
            guard outlined >= 0.5 else { return [] }
            return names.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
                .filter { $0.value >= least * outlined }
                .map { "\($0.key) \(Int(($0.value / outlined * 100).rounded())) %" }
        }
    }

    /// Meet outlines a tile a moment after its sound starts and keeps it a moment after it ends.
    /// The meetings up to 17.11.2026 matched their named speakers best with the outline taken as
    /// this much late.
    static let outlineDelay: TimeInterval = 1

    /// The evidence for each line of the transcript, by the times of its words. The Mac never
    /// plays the user's own microphone, so the tile named `ownName` cannot be whose voice a label
    /// of the call track is: it is outlined while the user talks over that label, and is left out
    /// for every label but the user's own, `own`.
    static func evidence(for transcript: Transcript, from sightings: [Sighting], own: Set<String>, ownName: String?) -> [Evidence] {
        transcript.utterances.map { utterance in
            let skipped = own.contains(utterance.speaker) ? nil : ownName
            let near = sightings.filter {
                $0.end - outlineDelay > TimeInterval(utterance.start) && $0.start - outlineDelay < TimeInterval(utterance.end)
                    && (skipped == nil || $0.name.split(separator: " ").first.map(String.init) != skipped)
            }
            var evidence = Evidence()
            let spans = utterance.words?.map { (start: $0.start, end: $0.end) } ?? [(start: utterance.start, end: utterance.end)]
            for span in spans {
                let start = TimeInterval(span.start), end = TimeInterval(span.end)
                evidence.speech += max(0, end - start)
                for sighting in near {
                    let seconds = min(end, sighting.end - outlineDelay) - max(start, sighting.start - outlineDelay)
                    guard seconds > 0 else { continue }
                    evidence.outlined += seconds
                    evidence.names[sighting.name, default: 0] += seconds
                }
            }
            return evidence
        }
    }

    /// `puhujat-ruudulla.txt`. First a line for each speaker label: the label, the seconds of its
    /// words, the seconds of those with an outlined tile on screen, then each name with its share
    /// of the outlined seconds. After an empty line, the same for each line of the transcript with
    /// half a second or more of outline: its timestamp, its label, the outlined seconds and the
    /// names.
    public static func report(for transcript: Transcript, from sightings: [Sighting],
                              fullName: String = NSFullUserName()) -> String {
        let firstName = fullName.split(separator: " ").first.map(String.init)
        let own = Set(["Minä", "Me"] + [firstName].compactMap { $0 })
        let ownName = transcript.utterances.contains { own.contains($0.speaker) } ? firstName : nil
        let lines = evidence(for: transcript, from: sightings, own: own, ownName: ownName)
        var labels: [String] = []
        var byLabel: [String: Evidence] = [:]
        for (utterance, evidence) in zip(transcript.utterances, lines) {
            if byLabel[utterance.speaker] == nil { labels.append(utterance.speaker) }
            byLabel[utterance.speaker, default: Evidence()].add(evidence)
        }
        func seconds(_ seconds: TimeInterval) -> String { "\(Int(seconds.rounded())) s" }
        var rows = labels.map { label -> String in
            let evidence = byLabel[label]!
            return ([label, seconds(evidence.speech), seconds(evidence.outlined)] + evidence.shares(least: 0.05))
                .joined(separator: "\t")
        }
        rows.append("")
        for (utterance, evidence) in zip(transcript.utterances, lines) where evidence.outlined >= 0.5 {
            rows.append(([Transcript.timestamp(utterance.start), utterance.speaker, seconds(evidence.outlined)]
                    + evidence.shares(least: 0.2)).joined(separator: "\t"))
        }
        return rows.joined(separator: "\n") + "\n"
    }
}
