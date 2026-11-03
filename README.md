# Litteroi

Litteroi turns Finnish and English meetings into text on your own Mac. Nothing is sent to the cloud.

- `Litteroi.app`: open it with Cmd+Space "litteroi" and it starts recording your mic and the call
  audio into `~/Litteroi/<date-time>/`. Cmd+W saves and quits. From the install on, a watcher runs
  all the time with an icon in the menu bar, and when a call starts, a small window offers to
  record; it never records on its own. Control-Option-L starts or stops a recording from any app,
  and when a call ends, a recording started for it is offered to stop.
- `LitteroiCore`: Whisper large-v3 in Finnish or English (WhisperKit) and speaker labels
  (SpeakerKit, pyannote community-1).
- `litteroi-cli`, inside the app: transcribes a mic recording, optionally with a separate call
  recording, into `transcript.md` and `transcript.json`. On speakers, it first removes the call's
  echo from the mic. The watcher deletes a meeting's audio 14 days after its minutes are written.
- The `litteroi` skill for Claude Code: type litteroi in any session and Litteroi updates itself
  from this repository's releases, Whisper transcribes the new recordings, then Claude fixes the
  transcript, guesses who spoke and writes `muistio.md`. Names listed in `~/Litteroi/nimet.txt`
  are hidden before Claude sees the text and put back on the Mac; the audio never leaves it.
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
