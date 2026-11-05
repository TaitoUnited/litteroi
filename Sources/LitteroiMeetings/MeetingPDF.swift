import AppKit

/// A finished meeting's corrected transcript as an A4 PDF to share, such as in Slack, which cuts a
/// message long before an hour of transcript: the title, a note on how the text was made, the
/// speakers from the minutes, or the whole minutes, and every line with its time.
public struct MeetingPDF {
    public let meeting: MeetingFolder
    public let withMinutes: Bool

    public init(meeting: MeetingFolder, withMinutes: Bool = false) {
        self.meeting = meeting
        self.withMinutes = withMinutes
    }

    static let page = CGSize(width: 595.28, height: 841.89)
    static let margin: CGFloat = 56

    var english: Bool {
        ((try? String(contentsOf: meeting.minutes, encoding: .utf8)) ?? "").hasPrefix("# Minutes")
    }

    var date: Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.date(from: String(meeting.title.prefix(15)))
    }

    /// Such as `litterointi-sisainen-meks-daily-5-nov.pdf`.
    public var fileName: String {
        let name = (meeting.name ?? (english ? "meeting" : "palaveri"))
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
            .joined(separator: "-")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d-MMM"
        let day = date.map { "-" + formatter.string(from: $0).lowercased() } ?? ""
        return "\(english ? "transcript" : "litterointi")-\(name)\(day).pdf"
    }

    public func data() throws -> Data {
        let storage = NSTextStorage(attributedString: try text())
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let body = CGSize(width: Self.page.width - 2 * Self.margin, height: Self.page.height - 2 * Self.margin)
        var containers: [NSTextContainer] = []
        repeat {
            let container = NSTextContainer(size: body)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            layout.ensureLayout(for: container)
            containers.append(container)
        } while NSMaxRange(layout.glyphRange(for: containers.last!)) < layout.numberOfGlyphs && containers.count < 1000

        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: Self.page)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let pdf = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle: title] as CFDictionary)
        else { throw CocoaError(.fileWriteUnknown) }
        let previous = NSGraphicsContext.current
        defer { NSGraphicsContext.current = previous }
        for (index, container) in containers.enumerated() {
            pdf.beginPDFPage(nil)
            pdf.translateBy(x: 0, y: Self.page.height)
            pdf.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: true)
            layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: container), at: CGPoint(x: Self.margin, y: Self.margin))
            let footer = NSAttributedString(string: "\(index + 1) / \(containers.count)", attributes: Self.style(.time))
            footer.draw(at: CGPoint(
                x: (Self.page.width - footer.size().width) / 2,
                y: Self.page.height - Self.margin / 2 - footer.size().height
            ))
            pdf.endPDFPage()
        }
        pdf.closePDF()
        return data as Data
    }

    var title: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: english ? "en_GB" : "fi_FI")
        formatter.dateStyle = .medium
        let parts = [meeting.name ?? meeting.title, date.map(formatter.string(from:))].compactMap { $0 }
        return "\(english ? "Transcript" : "Litterointi"): \(parts.joined(separator: " "))"
    }

    func text() throws -> NSAttributedString {
        let out = NSMutableAttributedString()
        func add(_ string: String, _ kind: Kind) { out.append(NSAttributedString(string: string, attributes: Self.style(kind))) }

        add(title + "\n", .title)
        add(english
            ? "Machine transcript of a recording, corrected for reading by the AI Claude, so the wording is not verbatim. [?] marks a guess and [unclear] a passage that could not be made out.\n"
            : "Konelitterointi nauhoitteesta. Claude-tekoäly on korjannut sen luettavaksi, joten sanamuoto ei ole sanatarkka. [?] merkitsee arvattua kohtaa ja [epäselvä] kohtaa, josta ei saatu selvää.\n",
            .body)

        let minutes = (try? String(contentsOf: meeting.minutes, encoding: .utf8)) ?? ""
        var section = ""
        for line in minutes.split(separator: "\n").map(String.init) {
            if line.hasPrefix("# ") { continue }
            if line.hasPrefix("## ") {
                section = String(line.dropFirst(3))
                if withMinutes || Self.speakerHeadings.contains(section) { add(section + "\n", .heading) }
                continue
            }
            guard withMinutes || Self.speakerHeadings.contains(section) else { continue }
            if line.hasPrefix("- ") {
                let item = String(line.dropFirst(2))
                let (label, rest) = Self.speakerHeadings.contains(section) ? Self.split(item) : (nil, item)
                add("•\t", .bullet)
                if let label { add(label + ": ", .bulletLabel) }
                out.append(Self.inline(rest, .bullet))
                add("\n", .bullet)
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append(Self.inline(line, .body))
                add("\n", .body)
            }
        }

        add((english ? "Transcript" : "Litterointi") + "\n", .heading)
        let corrected = try String(contentsOf: meeting.corrected, encoding: .utf8)
        for line in corrected.split(separator: "\n").map(String.init) where !line.hasPrefix("# ") {
            if let match = line.wholeMatch(of: #/\[(\d\d:\d\d:\d\d)\] \*\*(.+?):\*\* ?(.*)/#) {
                add(String(match.1) + " ", .time)
                add(String(match.2) + ": ", .label)
                out.append(Self.inline(String(match.3) + "\n", .line))
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append(Self.inline(line + "\n", .line))
            }
        }
        return out
    }

    static let speakerHeadings: Set<String> = ["Puhujat", "Speakers"]

    static func split(_ item: String) -> (String?, String) {
        guard let colon = item.range(of: ": ") else { return (nil, item) }
        return (String(item[..<colon.lowerBound]), String(item[colon.upperBound...]))
    }

    /// The text with Markdown's `**bold**` in bold and its backticks dropped.
    static func inline(_ text: String, _ kind: Kind) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (index, part) in text.replacingOccurrences(of: "`", with: "").components(separatedBy: "**").enumerated() {
            var attributes = style(kind)
            if index % 2 == 1 { attributes[.font] = font(size: (attributes[.font] as? NSFont)?.pointSize ?? 10, bold: true) }
            out.append(NSAttributedString(string: part, attributes: attributes))
        }
        return out
    }

    enum Kind { case title, heading, body, bullet, bulletLabel, time, label, line }

    static func font(size: CGFloat, bold: Bool) -> NSFont {
        NSFont(name: bold ? "HelveticaNeue-Bold" : "HelveticaNeue", size: size)
            ?? (bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size))
    }

    static func style(_ kind: Kind) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.15
        var size: CGFloat = 10
        var bold = false
        var color = NSColor.black
        switch kind {
        case .title:
            size = 15; bold = true; paragraph.paragraphSpacing = 6
        case .heading:
            size = 12; bold = true; paragraph.paragraphSpacingBefore = 12; paragraph.paragraphSpacing = 4
        case .body:
            paragraph.paragraphSpacing = 5
        case .bullet, .bulletLabel:
            bold = kind == .bulletLabel
            paragraph.headIndent = 14
            paragraph.firstLineHeadIndent = 2
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 14)]
            paragraph.paragraphSpacing = 3
        case .time:
            color = .darkGray; paragraph.paragraphSpacing = 5
        case .label:
            bold = true; paragraph.paragraphSpacing = 5
        case .line:
            paragraph.paragraphSpacing = 5
        }
        return [.font: font(size: size, bold: bold), .foregroundColor: color, .paragraphStyle: paragraph]
    }
}
