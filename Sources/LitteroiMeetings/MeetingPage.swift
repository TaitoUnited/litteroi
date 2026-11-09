import Foundation

/// A meeting as one page to open in a browser: the skill's questions about who spoke, each with a
/// field for its answer, the minutes and the whole transcript. Each timestamp plays the meeting
/// from that moment and shows the screens as they were, each video only while it was recorded, and
/// `#t-hh-mm-ss` in the address opens the page at that transcript line.
public struct MeetingPage {
    public var title: String
    /// The meeting folder as the answers' prompt names it.
    public var folder: String
    public var name: String?
    public var questions: String?
    public var minutes: String?
    public var transcript: String
    /// File names next to the page.
    public var audio: String?
    public var screens: [String]

    public init(title: String, folder: String? = nil, name: String? = nil, questions: String? = nil,
                minutes: String? = nil, transcript: String, audio: String? = nil, screens: [String] = []) {
        self.title = title
        self.folder = folder ?? "~/Litteroi/\(title)"
        self.name = name
        self.questions = questions
        self.minutes = minutes
        self.transcript = transcript
        self.audio = audio
        self.screens = screens
    }

    /// Reads the corrected transcript where there is one, else Whisper's.
    public init(meeting: MeetingFolder) throws {
        let files = FileManager.default
        func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
        self.init(
            title: meeting.title,
            folder: (meeting.url.path as NSString).abbreviatingWithTildeInPath,
            name: meeting.name,
            questions: read(meeting.questions),
            minutes: read(meeting.minutes),
            transcript: try read(meeting.corrected) ?? String(contentsOf: meeting.transcript, encoding: .utf8),
            audio: files.fileExists(atPath: meeting.listening.path) ? meeting.listening.lastPathComponent : nil,
            screens: meeting.screens.map(meeting.browserCopy(of:)).filter { files.fileExists(atPath: $0.path) }
                .map(\.lastPathComponent)
        )
    }

    public var html: String {
        var sections: [(id: String, heading: String, body: String)] = []
        if let questions {
            sections.append(("kysymykset", "Kysymykset", Self.form(questions, folder: folder, name: name, audio: audio != nil)))
        }
        if let minutes { sections.append(("muistio", "Muistio", Self.blocks(minutes))) }
        sections.append(("litteraatti", "Litteraatti", Self.lines(transcript)))
        let player = audio.map { "<audio id=\"audio\" controls preload=\"metadata\" src=\"\(Self.escape($0))\"></audio>" } ?? ""
        let videos = screens.map {
            "<video class=\"screen\" muted preload=\"auto\" data-start=\"\(MeetingFolder.start(of: URL(filePath: $0)))\" src=\"\(Self.escape($0))\"></video>"
        }
        return """
        <!doctype html>
        <html lang="fi">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(Self.escape(name ?? "Palaveri \(title)"))</title>
        <style>\(Self.style)</style>
        </head>
        <body class="\(videos.isEmpty ? "" : "with-screens")">
        <header>
        <h1>Palaveri \(Self.escape(title))\(name.map { ": " + Self.escape($0) } ?? "")</h1>
        <nav>\(sections.map { "<a href=\"#\($0.id)\">\($0.heading)</a>" }.joined(separator: " "))</nav>
        \(player)
        </header>
        <main>
        \(sections.map { "<section id=\"\($0.id)\"><h2>\($0.heading)</h2>\n\($0.body)</section>" }.joined(separator: "\n"))
        </main>
        \(videos.isEmpty ? "" : "<aside>\(videos.joined())</aside>")
        <script>\(Self.script)</script>
        </body>
        </html>

        """
    }

    /// The transcript, one paragraph per line, each with an id from its timestamp.
    static func lines(_ markdown: String) -> String {
        let line = #/^\[(\d\d):(\d\d):(\d\d)\] \*\*(.+?):\*\* ?(.*)$/#
        var speakers: [String] = []
        var ids: Set<String> = []
        var html: [String] = []
        for text in markdown.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let match = text.wholeMatch(of: line) else {
                if !text.hasPrefix("# ") { html.append("<p>\(inline(String(text)))</p>") }
                continue
            }
            let speaker = String(match.4)
            if !speakers.contains(speaker) { speakers.append(speaker) }
            let time = "\(match.1):\(match.2):\(match.3)"
            var id = "t-\(match.1)-\(match.2)-\(match.3)"
            var number = 2
            while ids.contains(id) {
                id = "t-\(match.1)-\(match.2)-\(match.3)-\(number)"
                number += 1
            }
            ids.insert(id)
            let speakerClass = speakers.firstIndex(of: speaker)! % 8
            html.append("<p class=\"line s\(speakerClass)\" id=\"\(id)\">\(timeLink(time)) <b>\(escape(speaker)):</b> \(inline(String(match.5)))</p>")
        }
        return html.joined(separator: "\n")
    }

    /// The questions, each numbered one with a field for its answer, and a button that copies the
    /// answers as a prompt for the litteroi skill. A question left blank stays open in the prompt.
    /// The keys are the pull request review page's where they fit: the selected question lists them.
    static func form(_ markdown: String, folder: String, name: String?, audio: Bool = false) -> String {
        var preamble: [String] = []
        var questions: [(number: Substring, lines: [String])] = []
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let number = line.prefixMatch(of: #/(\d+)\. /#)?.1 {
                questions.append((number, [line]))
            } else if questions.isEmpty {
                preamble.append(line)
            } else {
                questions[questions.count - 1].lines.append(line)
            }
        }
        let fields = questions.map {
            """
            <div class="question">\(blocks($0.lines.joined(separator: "\n")))
            <textarea class="answer" data-q="\($0.number)" rows="2" placeholder="\(answerHint)"></textarea></div>
            """
        }
        return """
        <form id="answers" data-folder="\(escape(folder))" data-name="\(escape(name ?? ""))">
        \(blocks(preamble.joined(separator: "\n")))
        \(fields.joined(separator: "\n"))
        <div class="keys" id="keys" hidden>\(keys(audio: audio))</div>
        <label>Sanastoon: termit ja nimet oikein kirjoitettuina, yksi riville
        <textarea id="glossary" rows="3"></textarea></label>
        <label>Muuta, kuten että osa jonkun rivistä on toisen puhetta
        <textarea id="notes" rows="3"></textarea></label>
        <p><button type="button" id="make-prompt">Kopioi vastaukset kehotteeksi</button> <span id="prompt-status"></span></p>
        <textarea id="prompt" rows="8" readonly hidden></textarea>
        </form>
        """
    }

    static let answerHint = "Nimi, sama kuin toinen puhuja, kahden sekoitus, epäselvä, en tiedä tai muu vastaus"

    /// The keys outside a field, then the one inside it; the page shows one set or the other.
    static func keys(audio: Bool) -> String {
        let browsing = [("j", "seuraava"), ("k", "edellinen"), ("Enter", "vastaa")]
            + (audio ? [("välilyönti", "toista tai pysäytä")] : []) + [("c", "kopioi vastaukset")]
        return (browsing.map { "<span class=\"browse\"><kbd>\($0.0)</kbd> \($0.1)</span>" }
            + ["<span class=\"type\"><kbd>Esc</kbd> pois kentästä</span>"]).joined()
    }

    /// The Markdown the skill writes: headings, paragraphs and lists nested one level. The
    /// document's own `#` heading is left out, since each section has its own.
    static func blocks(_ markdown: String) -> String {
        let item = #/^( *)([-*]|(\d+)\.) +(.*)$/#
        var html: [String] = []
        var paragraph: [String] = []
        var lists: [(tag: String, indent: Int)] = []

        func closeParagraph() {
            if !paragraph.isEmpty { html.append("<p>\(inline(paragraph.joined(separator: " ")))</p>") }
            paragraph = []
        }
        func closeLists(deeperThan indent: Int = -1) {
            while let last = lists.last, last.indent > indent {
                html.append("</li></\(last.tag)>")
                lists.removeLast()
            }
        }

        for text in markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                closeParagraph()
                continue
            }
            if let heading = trimmed.firstMatch(of: #/^(#{1,4}) +(.*)$/#) {
                closeParagraph()
                closeLists()
                if heading.1.count > 1 {
                    html.append("<h\(heading.1.count + 1)>\(inline(String(heading.2)))</h\(heading.1.count + 1)>")
                }
                continue
            }
            if let match = text.wholeMatch(of: item) {
                closeParagraph()
                let indent = match.1.count
                let tag = match.3 == nil ? "ul" : "ol"
                if let last = lists.last, last.indent >= indent {
                    closeLists(deeperThan: indent)
                    html.append("</li><li>")
                } else {
                    html.append(match.3.map { "<ol start=\"\($0)\"><li>" } ?? "<ul><li>")
                    lists.append((tag, indent))
                }
                html.append(inline(String(match.4)))
                continue
            }
            if lists.isEmpty {
                paragraph.append(trimmed)
            } else {
                html.append("<br>\(inline(trimmed))")
            }
        }
        closeParagraph()
        closeLists()
        return html.joined(separator: "\n")
    }

    static func inline(_ text: String) -> String {
        escape(text)
            .replacing(#/\*\*(.+?)\*\*/#) { "<b>\($0.1)</b>" }
            .replacing(#/`([^`]+)`/#) { "<code>\($0.1)</code>" }
            .replacing(#/\[?\b(\d\d):(\d\d):(\d\d)\b\]?/#) { timeLink("\($0.1):\($0.2):\($0.3)") }
    }

    static func timeLink(_ time: String) -> String {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        let seconds = parts[0] * 3600 + parts[1] * 60 + parts[2]
        return "<a class=\"t\" href=\"#t-\(time.replacing(":", with: "-"))\" data-t=\"\(seconds)\">\(time)</a>"
    }

    static func escape(_ text: String) -> String {
        text.replacing("&", with: "&amp;").replacing("<", with: "&lt;").replacing(">", with: "&gt;")
            .replacing("\"", with: "&quot;")
    }

    static let style = """
    :root { color-scheme: light dark; --bg: #fbfbf8; --fg: #1d1d1b; --muted: #6b6b66; --line: #e4e3dc;
      --now: #fff2b3; --link: #2357b5;
      --s0: #b4361f; --s1: #1f6fb4; --s2: #2f8a3a; --s3: #8a3fb0; --s4: #b07a10; --s5: #0f8a8a; --s6: #b0306a; --s7: #55606e; }
    @media (prefers-color-scheme: dark) { :root { --bg: #18181a; --fg: #e8e8e3; --muted: #9a9a94; --line: #2c2c30;
      --now: #4a4120; --link: #8ab4ff;
      --s0: #ff8a70; --s1: #7ab8ff; --s2: #7fd68a; --s3: #d3a0ff; --s4: #f0c060; --s5: #6fdcdc; --s6: #ff8ac0; --s7: #b4bcc8; } }
    * { box-sizing: border-box; }
    body { margin: 0; background: var(--bg); color: var(--fg); font: 16px/1.5 -apple-system, "Helvetica Neue", sans-serif; }
    header { position: sticky; top: 0; z-index: 1; display: flex; flex-wrap: wrap; align-items: center; gap: 8px 20px;
      padding: 10px 24px; background: var(--bg); border-bottom: 1px solid var(--line); }
    header h1 { font-size: 18px; margin: 0; }
    nav a { margin-right: 12px; }
    audio { flex: 1 1 320px; min-width: 0; height: 36px; }
    main { max-width: 900px; padding: 8px 24px 40vh; }
    body.with-screens main { margin-right: 46vw; }
    aside { position: fixed; top: 64px; right: 16px; width: 44vw; max-height: calc(100vh - 80px); overflow: auto; }
    aside video { width: 100%; margin-bottom: 8px; border: 1px solid var(--line); background: #000; }
    a { color: var(--link); }
    a.t { font: 13px ui-monospace, Menlo, monospace; text-decoration: none; }
    a.t::before { content: "\\25B6\\FE0E "; font-size: 10px; }
    h2 { margin-top: 32px; border-bottom: 1px solid var(--line); padding-bottom: 4px; scroll-margin-top: 70px; }
    section { scroll-margin-top: 70px; }
    .line { margin: 0; padding: 4px 8px; border-radius: 6px; scroll-margin-top: 90px; }
    .line:target, .line.now { background: var(--now); }
    \((0..<8).map { ".s\($0) b { color: var(--s\($0)); }" }.joined(separator: " "))
    li { margin: 4px 0; }
    code { font: 14px ui-monospace, Menlo, monospace; }
    .question { margin: 0 -10px 10px; padding: 4px 10px 8px; border-radius: 8px; }
    .question.selected { box-shadow: 0 0 0 2px var(--link); }
    .question ol { margin-bottom: 4px; }
    .keys { display: flex; flex-wrap: wrap; gap: 4px 14px; margin: 8px 0 0 40px; font-size: 13px; color: var(--muted); }
    .keys:not(.typing) .type, .keys.typing .browse { display: none; }
    kbd { font: 12px ui-monospace, Menlo, monospace; padding: 0 5px; border: 1px solid var(--line); border-bottom-width: 2px; border-radius: 5px; }
    textarea { display: block; width: 100%; margin-top: 4px; padding: 6px 8px; font-family: inherit;
      font-size: 15px; line-height: 1.4; color: var(--fg); background: var(--bg); border: 1px solid var(--line); border-radius: 6px; }
    textarea.answer { margin-left: 40px; width: calc(100% - 40px); }
    form label { display: block; margin-top: 16px; font-weight: 600; }
    form label textarea { font-weight: normal; }
    button { font: inherit; padding: 6px 14px; color: var(--bg); background: var(--link); border: 0; border-radius: 6px; cursor: pointer; }
    @media (max-width: 800px) { body.with-screens main { margin-right: 0; } aside { position: static; width: auto; padding: 0 24px; } }
    """

    static let script = """
    const audio = document.getElementById("audio");
    const screens = [...document.querySelectorAll("video.screen")];
    const lines = [...document.querySelectorAll(".line")].map(line => [Number(line.querySelector("a.t").dataset.t), line]);
    let current;
    function show(seconds) {
      for (const video of screens) {
        const local = seconds - Number(video.dataset.start);
        video.hidden = local < 0 || local > video.duration;
        if (!video.hidden && Math.abs(video.currentTime - local) > 0.6) video.currentTime = local;
      }
      let hit;
      for (const [start, line] of lines) { if (start <= seconds) hit = line; else break; }
      if (hit !== current) { current?.classList.remove("now"); hit?.classList.add("now"); current = hit; }
    }
    function seek(seconds, play) {
      if (audio) { audio.currentTime = Math.max(0, seconds - 1); if (play) audio.play(); }
      show(seconds);
    }
    document.addEventListener("click", event => {
      const link = event.target.closest("a.t");
      if (!link) return;
      event.preventDefault();
      if (event.detail) link.blur();
      history.replaceState(null, "", link.getAttribute("href"));
      seek(Number(link.dataset.t), true);
    });
    audio?.addEventListener("timeupdate", () => show(audio.currentTime));
    const target = location.hash ? document.getElementById(location.hash.slice(1)) : null;
    if (target?.classList.contains("line")) seek(Number(target.querySelector("a.t").dataset.t), false);
    const answers = document.getElementById("answers");
    if (answers) {
      const fields = [...answers.querySelectorAll("textarea:not(#prompt)")];
      const id = field => field.dataset.q || field.id;
      const key = "litteroi " + answers.dataset.folder;
      try {
        const saved = JSON.parse(localStorage.getItem(key) || "{}");
        for (const field of fields) field.value = saved[id(field)] || "";
      } catch {}
      answers.addEventListener("input", () => {
        try { localStorage.setItem(key, JSON.stringify(Object.fromEntries(fields.map(field => [id(field), field.value])))); } catch {}
      });
      document.getElementById("make-prompt").addEventListener("click", async () => {
        const one = text => text.trim().replace(/\\s*\\n\\s*/g, "; ");
        const name = answers.dataset.name ? " (" + answers.dataset.name + ")" : "";
        const lines = ["litteroi, vastaukset palaveriin " + answers.dataset.folder + name + ":"];
        for (const field of answers.querySelectorAll("textarea[data-q]")) {
          lines.push(field.dataset.q + ". " + (one(field.value) || "ei vastausta, jää auki"));
        }
        const glossary = one(document.getElementById("glossary").value);
        if (glossary) lines.push("Sanastoon: " + glossary);
        const notes = one(document.getElementById("notes").value);
        if (notes) lines.push("Muuta: " + notes);
        const prompt = document.getElementById("prompt");
        prompt.value = lines.join("\\n");
        prompt.rows = lines.length + 1;
        prompt.hidden = false;
        prompt.select();
        const status = document.getElementById("prompt-status");
        status.textContent = "Kopioi valittu teksti Cmd+C:llä ja liitä se Claude Codeen.";
        try {
          await navigator.clipboard.writeText(prompt.value);
          status.textContent = "Kopioitu. Liitä se Claude Codeen.";
        } catch {}
      });
    }
    const questions = [...document.querySelectorAll(".question")];
    const keys = document.getElementById("keys");
    const header = document.querySelector("header");
    let selected = -1;
    function select(index, scroll) {
      if (!questions.length) return;
      selected = Math.max(0, Math.min(questions.length - 1, index));
      questions.forEach((question, i) => question.classList.toggle("selected", i === selected));
      questions[selected].append(keys);
      keys.hidden = false;
      if (!scroll) return;
      const top = selected === 0 ? questions[0].closest("section") : questions[selected];
      const smooth = !matchMedia("(prefers-reduced-motion: reduce)").matches;
      scrollTo({ top: top.getBoundingClientRect().top + scrollY - header.offsetHeight - 8, behavior: smooth ? "smooth" : "auto" });
    }
    function answer() {
      const field = questions[selected]?.querySelector("textarea.answer");
      field?.focus();
      field?.setSelectionRange(field.value.length, field.value.length);
    }
    document.addEventListener("click", event => {
      const question = event.target.closest(".question");
      if (question) select(questions.indexOf(question), false);
    });
    document.addEventListener("focusin", event => {
      keys?.classList.toggle("typing", Boolean(event.target.closest("input, textarea, select, [contenteditable]")));
      const question = event.target.closest(".question");
      if (question) select(questions.indexOf(question), false);
    });
    document.addEventListener("focusout", () => keys?.classList.remove("typing"));
    // Chrome's player keeps every key from the page while it has focus.
    for (const type of ["play", "pause", "seeked", "volumechange", "ratechange"]) audio?.addEventListener(type, () => audio.blur());
    document.addEventListener("keydown", event => {
      if (event.metaKey || event.ctrlKey || event.altKey || event.isComposing) return;
      const field = event.target.closest("input, textarea, select, [contenteditable]");
      if (field) {
        if (event.key === "Escape") { field.blur(); event.preventDefault(); }
        return;
      }
      switch (event.key) {
        case "j":
        case "k":
          if (document.activeElement !== document.body) document.activeElement.blur();
          select(event.key === "j" ? selected + 1 : Math.max(0, selected - 1), true);
          break;
        case "Enter":
          if (event.target.closest("a, button, audio, video") || selected < 0) return;
          answer();
          break;
        case " ":
          if (!audio || event.target.closest("audio, video")) return;
          if (!event.repeat) { if (audio.paused) audio.play(); else audio.pause(); }
          break;
        case "c":
          if (!answers) return;
          document.getElementById("make-prompt").click();
          break;
        default:
          return;
      }
      event.preventDefault();
    });
    const unanswered = questions.findIndex(question => !question.querySelector("textarea.answer").value.trim());
    select(unanswered < 0 ? 0 : unanswered, unanswered > 0 && !location.hash);
    """
}
