# Litteroi

Finnish and English meeting transcription for macOS, fully on-device. Swift package: `LitteroiCore`
runs Whisper large-v3 through WhisperKit and labels speakers with SpeakerKit (pyannote community-1),
both from `argmaxinc/argmax-oss-swift`. `litteroi-cli` runs the pipeline on audio files.
`LitteroiMeetings` knows the meeting folders and deletes old audio. `LitteroiWatch` tells from Core
Audio when a call app holds the mic. `CSpeexDSP` is SpeexDSP 1.2.1's echo canceller, vendored from
github.com/xiph/speexdsp under its BSD licence. `App/` is the Mac app, which only records, and
`LitteroiWatcher`, a launch agent inside it that sits in the menu bar and offers to record when a
call starts and to stop when it ends. `skill/` is the `litteroi` skill for Claude Code, which
transcribes the recordings and finishes them with Claude: corrected transcript, speaker guesses and
minutes, with names hidden first. [docs/design.md](docs/design.md) holds the decisions behind it.

## Commands

- Build: `swift build`
- Test: `swift test`
- App project: `xcodegen generate --spec App/project.yml` writes `App/Litteroi.xcodeproj`, which
  git ignores; `App/project.yml` is the source.
- App build: `xcodebuild -project App/Litteroi.xcodeproj -scheme Litteroi -configuration Release
  -derivedDataPath .build/xcode build`
- App install: `ditto .build/xcode/Build/Products/Release/Litteroi.app ~/Applications/Litteroi.app`,
  so Spotlight finds it with "litteroi". The app holds `litteroi-cli` in `Contents/MacOS`. Check
  first that `pgrep -x Litteroi` finds no recording in progress. Then `pkill -x LitteroiWatcher`
  has launchd start the new watcher, and `~/Applications/Litteroi.app/Contents/MacOS/Litteroi
  --register-watcher` registers it on a Mac where it never ran, without recording, and again
  when the new build is signed another way, such as a local build over a release.
- Release: `scripts/release.sh` publishes the GitHub release `litteroi-<build>` of ai-library,
  the build being the number of commits that touched `litteroi/`. It holds `Litteroi.zip`, signed
  with Developer ID, notarized and stapled, which `scripts/update.sh` installs. It runs only on a
  pushed main with no local changes in `litteroi/`, and needs Xcode signed in to the team's account
  and a notarytool profile named `litteroi`.
- Signing: `App/Signing.xcconfig` signs ad hoc; the untracked `App/Signing.local.xcconfig` names
  a development certificate, so macOS keeps the microphone permission across builds.
- The recorders need the microphone and system audio recording permissions, so the app is
  launched by a person, not from a session.
- Transcribe: `.build/debug/litteroi-cli <mic.wav> [--call <call.wav>] --output <folder>`
  writes `transcript.md` and `transcript.json`. Without `--call` the mic track is split by
  speaker; with it the mic track is "Minä" and only the call track is split. Given a meeting
  folder under `~/Litteroi` instead, it transcribes that meeting's tracks into the folder.
- Meetings: `litteroi-cli status` lists each meeting as `litteroimatta`, `litteroitu` or
  `valmis`, and `litteroi-cli transcribe-pending` transcribes the `litteroimatta` ones, skipping
  the newest while the app is recording it. `litteroi-cli pseudonymize <folder>` hides the
  names of `~/Litteroi/nimet.txt` into `claude/transcript.md` and keeps the key in
  `avain.json`; `litteroi-cli restore <folder>` puts them back into the files Claude wrote in
  `claude/` and writes those into the meeting folder.
- Skill: it runs `~/Applications/Litteroi.app/Contents/MacOS/litteroi-cli` and is installed with
  `ln -s ~/Projects/ai-library/litteroi/skill ~/.claude/skills/litteroi`.
- Update: `scripts/update.sh`, which the skill runs first, pulls main and installs the newest
  `litteroi-` release with `gh` when its build is above the installed app's `CFBundleVersion`,
  after Gatekeeper and the team ID check out. It skips a checkout on another branch or with local
  changes in `litteroi/`, so in a working checkout build and install by hand.
- Models download on first run into `~/Library/Application Support/Litteroi/models`
  (Whisper large-v3 about 3.1 GB, SpeakerKit models about 33 MB).
- Test audio lives outside the repo in `~/Downloads/litteroi-test-audio`: `podcasts/` (full
  episodes), `clips/` (16 kHz mono cuts made with ffmpeg) and `results/`.

## Rules

- Keep `openai_whisper-large-v3`. Turbo, Parakeet v3 and Qwen3-ASR made more errors on Finnish in
  the GAIK benchmark (github.com/GAIK-project/finnish-asr). Each window of speech is transcribed in
  Finnish or English, whichever Whisper hears in it, so a meeting may switch between the two.
  Whisper names a window's language from how it starts, so windows are cut at speaker turns.
- Audio never leaves the Mac, and the app and `litteroi-cli` call no cloud API. Text reaches
  Claude only through the skill, from a meeting's `claude/` folder with the listed names hidden:
  a session never reads a meeting's own transcript, its `avain.json`, the restored `korjattu.md`
  and `muistio.md`, or `~/Litteroi/nimet.txt`.
- Models, recordings and transcripts never go under `~/Documents`, which iCloud may sync.
  WhisperKit defaults to `~/Documents/huggingface`, so always pass `downloadBase`.
- User-facing text is written in Finnish, and every string gets its English in the target's
  String Catalog (`Localizable.xcstrings`, `InfoPlist.xcstrings`); macOS picks one by the user's
  language order. Speaker labels follow the meeting's language. Code and identifiers are English.
