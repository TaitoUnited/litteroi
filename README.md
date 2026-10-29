# Litteroi

Litteroi turns Finnish meetings into text on your own Mac. Nothing is sent to the cloud.

- `LitteroiCore`: Whisper large-v3 in Finnish (WhisperKit) and speaker labels (SpeakerKit,
  pyannote community-1).
- `litteroi-cli`: transcribes a mic recording, optionally with a separate call recording, into
  `transcript.md` and `transcript.json`.
- The recording app (menu bar, meeting detection) is planned in [docs/design.md](docs/design.md).

Requires macOS 14 or later on Apple silicon and Xcode. The first run downloads about 3.1 GB of
models.

## Getting started

Paste this into Claude Code:

```text
clone git@github.com:TaitoUnited/ai-library.git into ~/Projects/ai-library unless it is there already, then in its litteroi folder read CLAUDE.md, build the package, run the tests, and transcribe a short Finnish recording I give you with litteroi-cli
```
