# Litteroi

Litteroi turns Finnish and English meetings into text on your own Mac. Nothing is sent to the cloud.

- `Litteroi.app`: open it with Cmd+Space "litteroi" and it starts recording your mic and the call
  audio into `~/Litteroi/<date-time>/`, with a small window you can close. From the install on, a
  watcher runs all the time. Its menu bar icon shows only while meetings wait for `litteroi` in
  Claude Code, and Control-Option-H hides or shows it. When a call starts, a small window offers to
  record the audio, the screens too or nothing; it never records on its own. Control-Option-T starts
  or stops a recording from any app, with no window or Dock icon, Control-Option-V records every
  screen too and Control-Option-A only the audio again, from the start or midway, and when a call
  ends, a recording started for it is offered to stop. When the screens were recorded, the names on
  the call's tiles are read from them on the Mac to help tell who spoke.
- `LitteroiCore`: Whisper large-v3 in Finnish or English (WhisperKit) and speaker labels
  (SpeakerKit, pyannote community-1).
- `litteroi-cli`, inside the app: transcribes a mic recording, optionally with a separate call
  recording, into `transcript.md` and `transcript.json`. On speakers, it first removes the call's
  echo from the mic. The watcher deletes a meeting's audio 14 days after its minutes are written.
- The `litteroi` skill for Claude Code: type litteroi in any session and Litteroi updates itself
  from this repository's releases, Whisper transcribes the new recordings, then Claude asks you who
  each speaker is, fixes the transcript and writes `muistio.md`. Each meeting gets a page,
  `palaveri.html`, to open in Firefox: the questions, which you answer on the page and paste back as
  the prompt its button copies, the minutes and the whole transcript, where a click on a timestamp
  plays the meeting from there. The names and terms you confirm go into `~/Litteroi/sanasto.txt`, so
  the next meetings start from them. The finished meeting is also copied as one Markdown file to the
  Claude Code project it belongs to, for later sessions there, and the transcript is written as a
  PDF in `~/Downloads/litteroi/` with a Slack draft to share it. Each meeting is named from your
  calendar, or Claude asks you. Claude reads the transcript and the names on the screen; the audio
  and the screen videos never leave the Mac.
- `scripts/release.sh` publishes the app, signed and notarized, as a GitHub release that the
  skill installs; see [docs/design.md](docs/design.md).

Requires macOS 14.2 or later on Apple silicon and the GitHub CLI `gh`, signed in to an account
that can read this repository. Building it needs Xcode and XcodeGen. The first transcription
downloads about 3.1 GB of models.

## Getting started

Paste this into Claude Code:

```text
clone git@github.com:TaitoUnited/ai-library.git into ~/Projects/ai-library unless it is there already, then in its litteroi folder read CLAUDE.md, run scripts/update.sh to install the app to ~/Applications so i can open it with cmd space litteroi, then install the litteroi skill
```
