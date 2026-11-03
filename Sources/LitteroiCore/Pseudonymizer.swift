import Foundation

/// The people and clients whose names are hidden before a transcript goes to Claude, kept in
/// `~/Litteroi/nimet.txt`: one name per line with its other forms after commas, people first and
/// clients under a line `[asiakkaat]`.
public struct NameList: Equatable, Sendable {
    public enum Kind: Sendable {
        case person
        case client
    }

    public struct Entry: Equatable, Sendable {
        public var kind: Kind
        /// The first form is the one a restored text uses.
        public var forms: [String]
    }

    public static let defaultURL = MeetingFolder.defaultRoot.appending(path: "nimet.txt")

    public var entries: [Entry]

    public init(parsing text: String) {
        var kind = Kind.person
        var entries: [Entry] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            switch line.lowercased() {
            case "[henkilöt]": kind = .person
            case "[asiakkaat]": kind = .client
            default:
                let forms = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                entries.append(Entry(kind: kind, forms: forms))
            }
        }
        self.entries = entries
    }

    public init(contentsOf url: URL) throws {
        self.init(parsing: try String(contentsOf: url, encoding: .utf8))
    }
}

/// Replaces listed names with Henkilö A, B... and Asiakas 1, 2... in order of first mention. A
/// Finnish case ending stays after a colon, as in "Henkilö A:lle", and the key maps each
/// replacement back to the words it stood for. Only capitalised words count as names, so a name
/// that Whisper writes in lower case, or inflects in a way the stems below miss, stays visible.
public struct Pseudonymizer: Sendable {
    public struct Key: Codable, Equatable, Sendable {
        /// "Henkilö A" to the name a restored text uses.
        public var names: [String: String] = [:]
        /// A replacement as written, ending included, to the words it stood for most often.
        public var forms: [String: String] = [:]
    }

    /// A start a name's inflected forms share. `vowel` is the base form's last vowel, which the
    /// ending drops, so "Pekan" from "pek" reads "Henkilö A:n".
    private struct Stem: Sendable {
        var text: String
        var entry: Int
        var vowel: Character?
        var endingLength: ClosedRange<Int>
        var endingStartsWithVowel: Bool
    }

    private static let companyForms: Set<String> = ["oy", "oyj", "ab", "ltd", "ry", "inc", "gmbh"]
    private static let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y", "ä", "ö"]

    private let names: NameList
    private let stems: [Stem]

    public init(names: NameList) {
        self.names = names
        var stems: [Stem] = []
        for (index, entry) in names.entries.enumerated() {
            for form in entry.forms {
                for word in form.split(whereSeparator: { !$0.isLetter }).map({ $0.lowercased() }) {
                    guard word.count >= 3, !Self.companyForms.contains(word) else { continue }
                    stems.append(Stem(text: word, entry: index, vowel: nil, endingLength: 0...4, endingStartsWithVowel: false))
                    stems += Self.inflectionStems(of: word, entry: index)
                }
            }
        }
        self.stems = stems.sorted { $0.text.count > $1.text.count }
    }

    /// Meikäläinen > Meikäläisen, and consonant gradation: Matti > Matin, Pekka > Pekan,
    /// Outi > Oudin.
    private static func inflectionStems(of word: String, entry: Int) -> [Stem] {
        if word.hasSuffix("nen") {
            return [Stem(text: String(word.dropLast(3)) + "s", entry: entry, vowel: "e", endingLength: 1...5, endingStartsWithVowel: false)]
        }
        guard let vowel = word.last, vowels.contains(vowel) else { return [] }
        let stem = String(word.dropLast())
        let gradated: String
        if ["kk", "pp", "tt"].contains(String(stem.suffix(2))) {
            gradated = String(stem.dropLast())
        } else if stem.last == "t" {
            gradated = String(stem.dropLast()) + "d"
        } else {
            return []
        }
        guard gradated.count >= 3 else { return [] }
        return [Stem(text: gradated, entry: entry, vowel: vowel, endingLength: 1...5, endingStartsWithVowel: true)]
    }

    public func pseudonymize(_ text: String) -> (text: String, key: Key) {
        struct Match {
            var range: Range<String.Index>
            var entry: Int
            var ending: String
        }

        var matches: [Match] = []
        for word in text.matches(of: #/\p{L}+/#) where word.output.first?.isUppercase == true {
            let lowered = word.output.lowercased()
            guard let stem = stems.first(where: { stem in
                guard lowered.hasPrefix(stem.text) else { return false }
                let ending = lowered.dropFirst(stem.text.count)
                return stem.endingLength.contains(ending.count) && (!stem.endingStartsWithVowel || Self.vowels.contains(ending.first!))
            }) else { continue }
            var ending = word.output.dropFirst(stem.text.count)
            if let vowel = stem.vowel, ending.first?.lowercased() == String(vowel) {
                ending = ending.dropFirst()
            }
            // "Matti Meikäläisen" is one mention, so it becomes one placeholder.
            if let last = matches.last, last.entry == stem.entry, text[last.range.upperBound..<word.range.lowerBound].allSatisfy({ $0 == " " }) {
                matches[matches.count - 1] = Match(range: last.range.lowerBound..<word.range.upperBound, entry: stem.entry, ending: String(ending))
            } else {
                matches.append(Match(range: word.range, entry: stem.entry, ending: String(ending)))
            }
        }

        var key = Key()
        var placeholders: [Int: String] = [:]
        var people = 0
        var clients = 0
        func placeholder(for index: Int) -> String {
            if let placeholder = placeholders[index] { return placeholder }
            let entry = names.entries[index]
            let placeholder: String
            switch entry.kind {
            case .person:
                placeholder = "Henkilö \(Self.letters(people))"
                people += 1
            case .client:
                clients += 1
                placeholder = "Asiakas \(clients)"
            }
            placeholders[index] = placeholder
            key.names[placeholder] = entry.forms[0]
            return placeholder
        }

        var counts: [String: [String: Int]] = [:]
        var output = ""
        var cursor = text.startIndex
        for match in matches {
            let placeholder = placeholder(for: match.entry)
            let replacement = match.ending.isEmpty ? placeholder : "\(placeholder):\(match.ending)"
            output += text[cursor..<match.range.lowerBound]
            output += replacement
            counts[replacement, default: [:]][String(text[match.range]), default: 0] += 1
            cursor = match.range.upperBound
        }
        output += text[cursor...]
        key.forms = counts.mapValues { originals in
            originals.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }!.key
        }
        return (output, key)
    }

    /// Puts the names back. A form the transcript had gets its words as written; a new one, such
    /// as "Henkilö A:lle" in Claude's minutes, gets the listed name and the ending after a colon.
    public static func restore(_ text: String, with key: Key) -> String {
        text.replacing(#/(Henkilö [A-Z]+|Asiakas [0-9]+)(?::(\p{L}+))?(?!\p{L})/#) { match in
            let (whole, placeholder, ending) = match.output
            if let original = key.forms[String(whole)] { return original }
            guard let name = key.names[String(placeholder)] else { return String(whole) }
            return ending.map { "\(name):\($0)" } ?? name
        }
    }

    static func letters(_ number: Int) -> String {
        let letter = String(Character(Unicode.Scalar(UInt8(65 + number % 26))))
        return number < 26 ? letter : letters(number / 26 - 1) + letter
    }
}
