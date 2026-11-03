# Design decisions

## Recording app

- A Mac app named Litteroi, so Spotlight finds it with "litteroi".
- Opening it shows a small window (timer, mic and call levels, Lopeta ja tallenna) and starts
  recording.
- Cmd+W, Cmd+Q or the button saves the tracks and quits; a recording under 2 s is deleted. The
  app only records: Whisper runs when the user types litteroi in Claude Code, so the machine is
  busy only when they choose.
- Audio is written while recording, so a crash still leaves a usable file.
- Two tracks: the mic (AVAudioEngine) and everything the Mac plays except Litteroi itself,
  through a Core Audio process tap (macOS 14.2+, `NSAudioCaptureUsageDescription`, "system audio
  recording" permission). A tap on call apps alone would miss a browser call whose audio process
  starts after the recording. A call track with under 10 s of sound is dropped as no call.
- On speakers, the mic also picks up the other participants. Before Whisper, `litteroi-cli`
  removes that echo with the call track as the reference: GCC-PHAT finds the delay between the
  two tracks every 30 s, since the recorders start apart and their clocks drift, then SpeexDSP's
  echo canceller (vendored, BSD) subtracts the call from the mic. A "Minä" line whose words
  mostly repeat a call line at the same time is dropped as leftover echo. With headphones no
  delay stands out and the mic track is used as recorded. `mic.caf` itself is never changed.
- Apple's voice processing on the mic would cancel echo while recording, but it is not known to
  cancel what other apps play, may turn their sound down during the call, and would change the
  recording for good.
- In-person meetings use the mic track alone, split by speaker.

## Finishing with Claude

- Claude takes text, images and PDFs but no audio, so Whisper still transcribes on the Mac and
  Claude works from its text. The `litteroi` skill fixes misheard words from context and from
  `~/Litteroi/sanasto.txt`, guesses who each speaker is from how people address each other, and
  writes the minutes: summary, decisions, tasks and unclear passages.
- The skill starts Whisper (`litteroi-cli transcribe-pending`) for every recorded meeting, in
  the background, and finishes the meetings already transcribed meanwhile. Whisper takes about
  20 minutes per hour of audio. A meeting the app is still recording is left for the next run.
- Claude cannot hear the audio, so it can point out that two speaker labels look like one person
  but cannot check it.

## Meeting detection

- `LitteroiWatcher.app` is a helper with no Dock icon, inside the app bundle under
  `Contents/Library/LoginItems`. The app registers it as a launch agent
  (`SMAppService.agent`, `Contents/Library/LaunchAgents/fi.taitounited.litteroi.watcher.plist`)
  once, when `scripts/update.sh` installs it and runs `Litteroi --register-watcher`, which opens
  no window, or on its first launch, so turning it off in System Settings > General > Login
  Items & Extensions sticks. Registering only on the first launch would have kept the icon away
  until the first recording. `KeepAlive` has launchd start it again whenever it exits, after a
  crash or an update too; a login item would stay down until the next login.
- Every 2 s it reads which processes use the mic (`kAudioHardwarePropertyProcessObjectList`,
  `kAudioProcessPropertyIsRunningInput`; no permission needed). Polling, because change
  listeners are reported unreliable.
- A call starts when a call app has held the mic for 3 polls and ends after 15 polls without one, so
  a short break in mic use does not end it. After 3 polls without one it is quiet: it may be over,
  or muted in an app that lets go of the mic. Browsers count as call apps, for Meet and Teams on the
  web, so dictation in a browser counts too.
- Its menu bar icon shows all the time: a waveform while it waits, with a mic badge during a
  call and a record circle while Litteroi records. Beside it stands the number of recordings not
  transcribed yet, leaving out the one Litteroi is recording, so a backlog for the `litteroi` skill
  shows without opening the folder. Its menu names that state and the count, and opens Litteroi or
  `~/Litteroi`.
- When a call starts, a small window at the top right asks "Palaveri alkoi (Teams).
  Litteroidaanko?", names the shortcut and reminds to tell the participants. Its Nauhoita button
  opens Litteroi. It never starts recording on its own, stays away when Litteroi is already
  recording, and closes when a recording starts, the call ends or Ei nyt is clicked. It was a
  notification at first, but the watcher's notifications were denied on the first Mac it ran on,
  so a Meet call showed nothing, and every Mac would need that permission; the window needs
  none.
- Control-Option-L starts a recording from any app, or stops the one going on, since Litteroi
  saves when it quits. It is a Carbon hot key (`RegisterEventHotKey`) in the watcher, which runs
  all the time and needs no accessibility permission for it.
- A recording the watcher opened during a call, from the prompt, the shortcut or its menu, is for
  that call: once the call is quiet, the same window offers to stop it, Lopeta ja tallenna stops and
  saves, and the window closes again if the call app takes the mic back. The offer waited for the
  call's end at first, and in the first test the user had stopped the recording by hand 10 s after
  leaving the call, before the 30 s were up. A recording started any other way, such as from
  Spotlight for an in-person meeting, gets no such offer and runs until the user stops it.

## Languages

- Whisper large-v3 is multilingual, so Finnish and English are both transcribed, and nobody
  tells Litteroi which one a meeting is in. Each window of speech is transcribed in the language
  Whisper names for it (WhisperKit's `detectLanguage`, which reuses the window's encoding), so a
  meeting that switches language midway keeps both.
- Whisper names a window's language from how it starts, so the windows are cut where the speaker
  changes: SpeakerKit runs first, and each speaker's turn is cut at pauses into windows of up to
  30 s. A turn starts halfway through the pause before it, or where its speech starts when it
  talks over the previous speaker. Speech under 1 s, such as a "joo" while another speaks, stays
  inside the turn around it. The user's own mic track in a call holds one speaker and is cut at
  pauses only.
- A test clip of 30 s of Finnish, then 42 s of English from two other speakers, lost all of its
  English to broken Finnish with one language for the whole meeting, 19 s of it with windows cut
  only at pauses, and none with windows cut at speaker turns. A speaker who switches language in
  the middle of a turn still loses the rest of that window to the first language.
- The turns make more and shorter windows, and Whisper encodes 30 s for each: a 5-minute Finnish
  podcast clip with two speakers took 129 s instead of 120 s on an M5 MacBook Air, with about
  as many errors, in different places.
- The meeting's language is the one most of its speech is in, Finnish on a tie. A window Whisper
  names as another language, or one under 5 s, too short to tell from, is transcribed again in
  the meeting's language when it came out in another.
- Speaker labels follow the meeting's language (Minä and Puhuja 1, or Me and Speaker 1). The
  skill keeps each line of `korjattu.md` in the language it was spoken in and writes
  `muistio.md` in the meeting's language.
- The app and the watcher show Finnish or English by the user's language order in macOS, from
  String Catalogs (`Localizable.xcstrings`, `InfoPlist.xcstrings`) with Finnish as the source;
  a Mac set to neither shows English.

## Storage

- `~/Litteroi/<yyyy-mm-dd-hhmm>/` holds `mic.caf`, `call.caf`, `transcript.md` and
  `transcript.json`, and once Claude has finished the meeting `korjattu.md`, `muistio.md`, the
  key `avain.json` and the `claude/` folder with the text Claude read and wrote. Not
  `~/Documents` (iCloud sync) and not inside the app bundle.
- `~/Litteroi/nimet.txt` lists the people and clients to hide, `~/Litteroi/sanasto.txt` the
  terms Claude may see. The user writes both.
- The tracks are 16 kHz mono 16-bit PCM in CAF, about 115 MB an hour each: the rate Whisper
  works at, and a container that stays readable after a crash, which m4a does not.
- The watcher deletes `mic.caf` and `call.caf` 14 days after `muistio.md` was written, checked
  hourly. By then the minutes have been read, and a `[?]` or a speaker guess checked against the
  audio; storage limitation (GDPR Art. 5(1)(e)) asks for no longer. A meeting not finished keeps
  its audio. Transcripts and minutes stay.

## Privacy

- Recording and transcription run locally and need no data processing agreement. The Claude
  step sends text to Anthropic, which does.
- Participants are told at the start of the meeting, including that Claude may read the text
  with names hidden.
- Voice profiles that recognise people across meetings are biometric data (GDPR Art. 9) and need
  each person's explicit consent. Until then, speakers are named by hand after the meeting, or
  guessed by Claude from the text.
- Before any text goes to Claude, `litteroi-cli pseudonymize` replaces the names of
  `nimet.txt` with Henkilö A, B and Asiakas 1, 2, keeping a Finnish case ending after a colon
  (`Henkilö A:lle`). The key stays on the Mac and `restore` puts the names back.
- The list catches only what it can: capitalised words, the -nen stem and kk, pp, tt and t
  gradation (Meikäläisen, Pekan, Matin, Oudin). A name not on the list, one Whisper writes in
  lower case, such as `moodle-alusta`, or an irregular form reaches Claude, so the skill names
  the name-like words it saw unhidden for the user to add. A capitalised word starting with a
  listed name, such as Mattila for Matti, is hidden too.

## Why not OpenWhispr

- OpenWhispr (MIT) already records mic and system audio on-device and labels speakers. On
  2026-10-30 three 5-minute Finnish podcast clips went through `litteroi-cli` and through the
  engine bundled with OpenWhispr 1.11.0: whisper.cpp with ggml large-v3 in Finnish, then
  sherpa-onnx diarization (pyannote segmentation 3.0, 3D-Speaker CAM++) with OpenWhispr's own
  cluster rules. The app's window was not used.
- Text came out about even. Both run Whisper large-v3; most differences were filler words, which
  litteroi keeps as spoken and OpenWhispr tidies into standard Finnish. Each invented words.
- Speakers: litteroi found 3, 3 and 2, OpenWhispr 7, 6 and 5. On the interview clip, a host and a
  guest, OpenWhispr split the guest into three, sometimes mid-sentence, and put quick exchanges
  under one speaker. Told there were 2, it still switched speaker inside a sentence.
- OpenWhispr took about a third less time (210 s against 320 s for the three clips), with its
  model already loaded. Speaker labels are what litteroi adds, so it stays.
- Results are in `~/Downloads/litteroi-test-audio/results/compare-openwhispr/`. There is no
  reference transcript, so the verdict on text is a reading, not an error rate.

## Distribution

- `scripts/release.sh` publishes the GitHub release `litteroi-<build>` of ai-library: the app,
  signed with Developer ID, notarized and stapled, as `Litteroi.zip`. It is signed with Akira
  Taguchi's own developer account, so macOS names Akira Samuel Taguchi as the developer; a Taito
  United Oy account would need a D-U-N-S number and its account holder.
- The releases are as private as the repository: everyone who can read ai-library can download
  them, which includes its outside collaborators, and nobody else. They hold the app and the
  subjects of the commits since the last release, never audio, transcripts or names. Apple's
  notary service receives each app to scan it.
- `litteroi-cli` sits inside the app, in `Contents/MacOS`, so one signature, one notarization
  and one download cover both, and the skill finds the tool at the same path on every Mac.
- Updates come through the skill: typing litteroi first runs `scripts/update.sh`, which pulls
  main for the skill and installs the newest release with `gh` when its build is above the
  installed app's. Everyone who uses Litteroi already needs this repository and Claude Code for
  the transcription, so the updates need no hosting or IT, only `gh` signed in to an account
  that can read ai-library.
- Releases rather than a build on each Mac: macOS keeps the microphone and system audio
  permissions for the app's code identity. An app built on a Mac without its own development
  certificate is signed ad hoc, whose identity is the hash of that build, so every update asked
  for both permissions again. A release always carries the same team's identity, so the
  permissions stay, and colleagues need no Xcode.
- The script installs only an app that Gatekeeper accepts and that carries the team ID
  `VXSNWDR5MY`, so a release asset replaced on GitHub cannot install someone else's code.
- It leaves a checkout alone that is on another branch or has changes of its own in the
  folder, so a developer's own build stays, and it never replaces the app while it records.
- Sparkle would need a feed colleagues can reach without signing in, which a private repository
  is not; it fits once Litteroi has a public repository of its own. MDM would need managed Macs.
- A Mac without the skill gets `Litteroi.zip` by hand, and opening it unpacks the app. There is
  no DMG: the export signs the app with a cloud-managed certificate, but `codesign` would sign a
  DMG only with a Developer ID certificate kept in one Mac's keychain.

## App icon

- `App/Shared/AppIcon.icon`, an Icon Composer file both the app and the watcher use, so Login
  Items shows it for the watcher too. Its layer is a hand-written SVG waveform.
