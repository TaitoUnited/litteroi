# Litteroi

Finnish and English meeting transcription for macOS, fully on-device. Swift package: `LitteroiCore`
runs Whisper large-v3 through WhisperKit and labels speakers with SpeakerKit (pyannote community-1),
both from `argmaxinc/argmax-oss-swift`. `litteroi-cli` runs the pipeline on audio files.
`LitteroiMeetings` knows the meeting folders and deletes old audio. `LitteroiWatch` tells from Core
Audio when a call app holds the mic, reads a browser's page through Accessibility and keeps the
auto list `~/Litteroi/automaattiset.txt`. `CSpeexDSP` is SpeexDSP 1.2.1's echo canceller, vendored
from github.com/xiph/speexdsp under its BSD licence. `App/` is the Mac app, which only records, and
`LitteroiWatcher`, a launch agent inside it that records a call in an app or site of the auto list
until it ends, offers to record any other call and to add its app or site to the list, with a menu
bar icon while meetings wait for the skill. `skill/` is the `litteroi`
skill for Claude Code, which transcribes the recordings and finishes them with Claude: it asks the
user who each speaker is, then writes the corrected transcript and the minutes.
[docs/design.md](docs/design.md) holds the decisions behind it.

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
- Release: `scripts/release.sh` publishes the GitHub release `litteroi-<build>`, the build being the
  number of commits on main. It holds `Litteroi.zip`, signed with Developer ID, notarized and
  stapled, which `scripts/update.sh` installs. It runs only on a pushed main with no local changes,
  and needs Xcode signed in to the team's account and a notarytool profile named `litteroi`.
- Signing: `App/Signing.xcconfig` signs ad hoc; the untracked `App/Signing.local.xcconfig` names
  a development certificate, so macOS keeps the microphone permission across builds.
- The recorders need the microphone, system audio recording and screen recording permissions,
  so the app is launched by a person, not from a session.
- Transcribe: `.build/debug/litteroi-cli <mic.wav> [--call <call.wav>] --output <folder>` writes
  `transcript.md` and `transcript.json`. Without `--call` the mic track is split by speaker; with it
  the mic track carries the user's first name, from macOS, and only the call track is split. Given a
  meeting folder under `~/Litteroi` instead, it transcribes that meeting's tracks into the folder.
- Meetings: `litteroi-cli status` lists each meeting as `litteroimatta`, `litteroitu` or `valmis`,
  the one being recorded as `nauhoitetaan (ääni)` or `nauhoitetaan (ääni ja video)`, then its folder,
  the recording's length while its audio is kept, such as `9 s` or `40 min`, and the meeting's name
  from `nimi.txt` when it has one, and `litteroi-cli transcribe-pending`
  transcribes the `litteroimatta` ones, skipping the newest while the app is recording it. Both
  transcribe commands also read the names on the screen videos into `nimet-ruudulla.txt`, and
  `litteroi-cli names <meeting folder>` reads them again. `litteroi-cli words <meeting folder>`
  adds word times to a `transcript.json` from before they were kept, by transcribing the meeting
  again without changing its text. `litteroi-cli page <meeting folder>`
  writes the meeting's `palaveri.html`, whose timestamps play the meeting in Firefox and whose form
  copies the answers to `kysymykset.md` as a prompt, and prints its `file://` address. `litteroi-cli
  export <meeting folder> <folder>` writes a finished meeting's minutes and corrected transcript as
  `<meeting>.md` into the folder, which the skill points at the meeting's Claude Code project.
  `litteroi-cli pdf <meeting folder> <folder>` writes its corrected transcript as an A4 PDF to
  share, `--minutes` with the minutes.
- Skill: it runs `~/Applications/Litteroi.app/Contents/MacOS/litteroi-cli` and is installed with
  `ln -s ~/Projects/litteroi/skill ~/.claude/skills/litteroi`.
- Update: `scripts/update.sh`, which the skill runs first, pulls main and installs the newest
  `litteroi-` release with `gh` when its build is above the installed app's `CFBundleVersion`,
  after Gatekeeper and the team ID check out. It skips a checkout on another branch or with local
  changes, so in a working checkout build and install by hand.
- Models download on first run into `~/Library/Application Support/Litteroi/models`
  (Whisper large-v3 about 3.1 GB, SpeakerKit models about 33 MB).
- Test audio lives outside the repo in `~/Downloads/litteroi-test-audio`: `podcasts/` (full
  episodes), `clips/` (16 kHz mono cuts made with ffmpeg) and `results/`.

## Rules

- Keep `openai_whisper-large-v3`. Turbo, Parakeet v3 and Qwen3-ASR made more errors on Finnish in
  the GAIK benchmark (github.com/GAIK-project/finnish-asr). Each window of speech is transcribed in
  Finnish or English, whichever Whisper hears in it, so a meeting may switch between the two.
  Whisper names a window's language from how it starts, so windows are cut at speaker turns.
- Audio and screen videos never leave the Mac, and the app and `litteroi-cli` call no cloud API.
  Text reaches Claude only through the skill: a meeting's transcript, names included, the names
  `litteroi-cli` reads from the screen videos on the Mac, and the glossary. No session opens the
  audio or the screen videos.
- Models, recordings and transcripts never go under `~/Documents`, which iCloud may sync.
  WhisperKit defaults to `~/Documents/huggingface`, so always pass `downloadBase`.
- User-facing text is written in Finnish, and every string gets its English in the target's
  String Catalog (`Localizable.xcstrings`, `InfoPlist.xcstrings`); macOS picks one by the user's
  language order. Speaker labels follow the meeting's language. Code and identifiers are English.
