# Design decisions

## Recording app

- A Mac app named Litteroi, so Spotlight finds it with "litteroi".
- Opening it starts recording. Opened with Cmd+Space, it shows the small window (timer,
  mic and call levels, Lopeta ja tallenna) and a Dock icon. Started by the watcher, from
  Control-Option-T, V or A or the prompt, it shows neither, so the meeting stays in front, as the
  user asked: the app is an `LSUIElement` that takes the regular activation policy only while its
  window is open. The window opens anyway when a recorder fails, when the Mic Mode is not
  Standard, when the watcher is not running, and when Litteroi is opened again from Spotlight or
  the watcher's Näytä nauhoitus.
- Control-Option-T, Cmd+Q or the button saves the tracks and quits; closing the window leaves the
  recording going. A recording under 2 s is deleted. The app only records: Whisper runs when the
  user types litteroi in Claude Code, so the machine is busy only when they choose.
- Audio is written while recording, so a crash still leaves a usable file.
- Two tracks: the mic (AVAudioEngine) and everything the Mac plays except Litteroi itself,
  through a Core Audio process tap (macOS 14.2+, `NSAudioCaptureUsageDescription`, "system audio
  recording" permission). A tap on call apps alone would miss a browser call whose audio process
  starts after the recording. A call track with under 10 s of sound is dropped as no call.
- The call track is read at the aggregate device's sample rate, not the rate the tap reports.
  AirPods in their call profile run at 24 kHz while the tap reports 48 kHz, so Signal calls
  recorded before 10.11.2026 play at double speed. `litteroi-cli transcribe` warns when a call
  track's length differs from its mic track's by over 10 s and over 10 %.
- When the screens are recorded, every display is, one video each, so what was shown in a meeting
  can be looked up later: ScreenCaptureKit, H.265, up to 2 frames a second and at most 1920 points
  wide. ScreenCaptureKit sends a frame only when the screen changes, so a slide left up costs next
  to nothing, and the last frame lasts until the recording stops. It needs the screen recording
  permission, which the first recording asks for; without it the audio is still recorded and the
  window says why the screens are not.
- A recording takes the screens too while the Mac's own display is the only one on, and only the
  audio while an external display is connected, as the user asked on 9.11.2026: "litteroi should
  always start transcribing with screen save when not on external display". This holds for every
  start that names no mode: a call recorded on its own, Control-Option-T, the menu and Spotlight.
  Control-Option-V records the screens too and Control-Option-A only the audio, from the start or
  midway, and the prompt's Ääni and Kuva pick one. macOS shows a purple item in the menu bar for
  as long as an app captures the screen, and no app can hide it. The user asked for both keys and
  for the switch midway. The watcher opens the app with `--video`, or switches a recording
  going on with a distributed notification, and each stretch of screen recording is its own
  video, `screen-<display>-<second>.mov`, named by the second of the meeting it starts at, which
  the page uses to show it only while it was recorded. The app writes `ääni` or `ääni ja video` to
  `.nauhoitus` in the meeting folder while it records, so `litteroi-cli status` and the watcher's
  menu say which. The call track needs no switch: its purple dot shares the menu bar's one privacy
  dot with the call app's microphone and camera, which take it during a call.
- On speakers, the mic also picks up the other participants. Before Whisper, `litteroi-cli`
  removes that echo with the call track as the reference: GCC-PHAT finds the delay between the
  two tracks every 30 s, since the recorders start apart and their clocks drift, then SpeexDSP's
  echo canceller (vendored, BSD) subtracts the call from the mic. A line of the user's whose words
  mostly repeat a call line at the same time is dropped as leftover echo. With headphones no
  delay stands out and the mic track is used as recorded. `mic.caf` itself is never changed.
- Apple's voice processing on the mic would cancel echo while recording, but it is not known to
  cancel what other apps play, may turn their sound down during the call, and would change the
  recording for good.
- macOS filters the mic of any app, one with no voice processing too, whose Mic Mode in the menu
  bar is Voice Isolation, which Apple describes as isolating the voice and attenuating other
  signals. That changes `mic.caf` for good, may turn down the people further from the Mac in a
  room and hands the echo canceller a filtered track. The mode is the user's pick per app and no
  app can set its own, so while Litteroi's is not Standard the window opens and says so. Apple
  does not say whether `activeMicrophoneMode` or `preferredMicrophoneMode` follows the menu for
  such an app, so the app reads both and logs them.
- In-person meetings use the mic track alone, split by speaker.

## Finishing with Claude

- Claude takes text, images and PDFs but no audio, so Whisper still transcribes on the Mac and
  Claude works from its text. The `litteroi` skill rewrites each line into what the speaker
  most likely said, from context and from `~/Litteroi/sanasto.txt`, so that `korjattu.md` reads
  as understandable Finnish, with `[?]` after a guess and `[epäselvä]` where nothing makes
  sense; `transcript.md` keeps Whisper's words. Fixing only the words whose right form was clear
  left whole lines unreadable, and the user asked for understandable Finnish. A line with nothing
  meaningful in it is left out, and a line whose speaker cannot be told is labelled Epäselvä, as
  the user asked. It then writes the minutes: summary, decisions, tasks and unclear passages.
- The skill writes `korjattu.md` before it asks who spoke, so the questions and the page quote
  lines the user can read.
- Each meeting has a name in `nimi.txt`, shown on its page, by `litteroi-cli status` and in the
  project's copy. The skill takes it from the user's calendar event at the recording's start, or
  from the transcript and asks the user, since the user could not tell which call a page was
  for.
- When the screens were recorded, `litteroi-cli` reads the names the call app shows on the
  participants' tiles into `nimet-ruudulla.txt`, so the skill can guess the speakers from who was
  in the call. It reads a frame every 10 s with macOS's own text recognition (Vision, Finnish and
  English) on the Mac and keeps only lines shaped like a name, outside the menu bar and away from
  a list of the call apps' and browsers' labels, that stay on screen for 2 minutes or more in at
  least a third of the frames. A one-letter misreading counts with the name. No face recognition:
  a model that recognises faces across meetings would be biometric data like voice profiles.
- Before writing, the skill asks the user who each speaker is, quoting the lines around a few of
  each speaker's lines with its own guess from how people address each other. A file of names
  written ahead of each meeting was too much work, and the user knows the voices. The user asked
  for the context around each line and for a way to hear it with a click, and to answer on the
  page rather than in the chat.
- `litteroi-cli page` writes each meeting's `palaveri.html`, with the questions, the minutes and the
  whole transcript, and every timestamp on it plays the meeting from there, showing the screens as
  they were. The user opens it in Firefox, since Preview plays neither the CAF tracks nor a jump to
  a time. The tool mixes the tracks into `palaveri.m4a` (AAC) and copies each screen video as H.264
  `screen-<n>-<second>.mp4`, since Firefox may not play the recorder's HEVC; no session opens the
  audio, the tool does the copying. Each question has a field for its answer, with none for
  glossary terms or other notes since the user asked them gone, and a button copies the answers as a prompt for the skill,
  numbered as the questions are. The page keeps them in Firefox's local storage meanwhile.
- The page keeps the cursor in an answer from the first question to the last, since answering five
  meetings' questions with the mouse was slow and the user said on 12.11.2026 that they are always
  in the field. `Enter` ends an answer, pauses the meeting and puts the cursor in the next
  question's field; in an empty answer it first writes `kyllä`, which takes the question's guess,
  since the user had left such answers blank and the prompt called them open; from the last answer
  it copies the answers as the button does. A click on a timestamp inside a question plays it and
  hands the cursor back to that question's answer. `Ctrl+P` plays and pauses from inside a field,
  `Ctrl+N` plays the question's next quoted line and `Ctrl+L` the line the question asks about, the
  quoted line whose speaker the question's own line names in bold, since `Ctrl+N` starts from the
  context line before it. Firefox's own keys use Control only for `Ctrl+M` and the tab keys, and in
  a field the two replace macOS's cursor up and down a line, which the arrows still do. The
  selected question lists these keys and no others: the keys for outside a field, `j`, `k`, space,
  `l`, `n` and `c`, are gone with their hints, `Shift+Enter` no longer makes a new line, and `Esc`
  still takes the cursor out but is not listed, all as the user asked on 12.11.2026.
- A quoted line under a question plays from its quoted part and stops half a second after it, which
  the user picked over playing on. A line carries the time its utterance starts, and an utterance
  ran for minutes, so the quoted words came long after a click. Whisper already timed each word, so
  `transcript.json` keeps them per utterance, and the page matches each quoted part, in the
  corrected transcript's words, to the stretch of Whisper's words most like it. `litteroi-cli
  words` adds the times to an older transcript by transcribing it again, keeping its text. The page opens with the cursor in the first unanswered question's field, as the user
  asked, so the first answer needs no key; an address that names a transcript line opens on that
  line instead, with no field in focus.
- `litteroi-cli export` copies a finished meeting, its minutes and corrected transcript in one
  Markdown file, into `~/.claude/projects/<project>/meetings/` of the Claude Code project it
  belongs to, so later sessions there can read it; a note in that project's memory says where.
  The copy stays outside `memory/`, since a team repository's memory is shared with colleagues
  and a meeting is not. The skill picks the project from the meeting and asks when none fits.
- `litteroi-cli pdf` writes the corrected transcript as an A4 PDF to share, since Slack cuts a
  message at 40,000 characters, less than an hour of transcript. AppKit's text system lays it out in
  Helvetica Neue, so it needs no LibreOffice, whose headless run sees only its own fonts. Its name
  is the kind and short name of `lyhenne.txt` around the date, such as
  `daily-mon-9-nov-2026-sis-meks-transcription.pdf`, as the user asked, and the date and the
  meeting's whole name without the file. The skill then drafts the share as one line, the meeting,
  that it was recorded and transcribed, and its topics as search words, since people read the PDF
  and Slack's search finds no word inside one. It goes where the project's memory says, or the skill
  asks once and writes the answer there. The line says the meeting was recorded, since Litteroi
  tells no one else in the call.
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
- launchd keeps the signature of the app that registered the watcher. When the first release,
  signed with Developer ID, replaced a local build signed with a development certificate, launchd
  refused to start the watcher (`needs LWCR update`, exit 78) until it was registered again about
  10 s after the first try. So `--register-watcher` registers a watcher that is on again and
  retries until it runs, which takes about 18 s after such a switch and 3 s otherwise.
- Every 2 s it reads which processes use the mic (`kAudioHardwarePropertyProcessObjectList`,
  `kAudioProcessPropertyIsRunningInput`; no permission needed). Polling, because change
  listeners are reported unreliable.
- A call starts when a call app has held the mic for 3 polls and ends after 15 polls without one, so
  a short break in mic use does not end it. After 3 polls without one it is quiet: it may be over,
  or muted in an app that lets go of the mic. Browsers count as call apps, for Meet and Teams on the
  web, so dictation in a browser counts too.
- Its menu bar icon shows only while meetings wait for the `litteroi` skill, transcribed or not,
  leaving out the one Litteroi is recording: the user asked for the icon only when there is
  something to run in Claude Code. Beside it stands that number. The icon is a waveform, with a
  mic badge during a call and a record circle while Litteroi records. Its menu names that state
  and the count, says to type litteroi in Claude Code, and opens Litteroi or `~/Litteroi`. A
  recording alone does not bring the icon up: with no Dock icon either, macOS's orange mic dot is
  its only sign, which the user chose over an icon that shows with nothing to run.
  Control-Option-H hides the icon, or shows it with nothing waiting, from then on until the next
  press, since the user asked for a key to hide and unhide it; the watcher keeps that choice in
  its defaults, so a restart keeps it too.
- A call in an app or site of the auto list, `~/Litteroi/automaattiset.txt`, is recorded on its
  own as soon as it starts, and the recording stops when the call ends, 30 s after the call app let
  go of the mic, as the user asked on 9.11.2026: "it should always transcribe audio while on mic is
  being used by a meeting". The watcher only offered to record at first, since the participants
  have to be told first; telling them stays the user's part. The list holds a call app's name, such
  as Teams or Signal, or a site's host, such as meet.google.com, one a line, so a browser on a
  meeting site is recorded and the same browser taking the mic for dictation on another site is
  not. The menu's Litteroidaan itsestään removes an entry, and the file can be edited by hand.
- Any other call gets a small window at the top right that asks "Litteroidaanko?". A call whose app
  or site is not on the list yet adds the line "Aina: litteroi jatkossa itsestään (<app or site>)"
  and the button Aina, which adds it to the list and records, as the user asked: "if the url or app
  is new it should ask add to auto transcribe". Ääni records the audio, Kuva the screens too, and
  Ei dismisses it, each with its shortcut, Control-Option-L, A, V and N. Return takes Kuva while the
  Mac's own display is the only one on and Ääni otherwise, never Aina, which changes the list for
  good. A browser call whose site cannot be read gets the window without Aina, since adding the
  whole browser would record every site. The prompts leave out the word record, as the user asked;
  the T of Control-Option-T stands for transcribe, which the user picked over the L of Litteroi. The
  window stays away when Litteroi is already recording, and closes when a recording starts, the call
  ends, or Ei or Control-Option-N dismisses it. It was a notification at first, but the watcher's
  notifications were denied on the first Mac it ran on, so a Meet call showed nothing, and every Mac
  would need that permission; the window needs none.
- A browser call's site is the host, without www., of the call's tab, read through the
  Accessibility API when the call starts. Chrome, Edge, Brave, Arc and Safari give the URL of the
  front window's tab as the window's document. Firefox builds its accessibility tree only while a
  client has set `AXEnhancedUserInterface`, as VoiceOver does, so when a read finds nothing the
  watcher sets it, reads again, which took about 0.5 s, and sets it back, after which Firefox drops
  the tree again. No browser says which tab holds the mic, and Firefox gives the URL of the front
  tab only, so on 16.11.2026 a Meet call whose prompt came while a GitHub tab was in front offered
  Aina for github.com. Firefox does mark a tab that plays sound with a mute button before its
  title, and a call plays the others' voices, so while a tab of any Firefox window plays sound, the
  front tab is read only when it is one of them. Otherwise the prompt shows without Aina, and the
  site is read again each time the front window's title changes, which costs no tree, then up to
  five times more 10 s apart, since a call can be quiet for a moment, and only from a front tab
  that plays sound. A site read that way records on its own when it is on the list, or adds Aina
  to the prompt while it still shows. With no tab playing sound, as in Meet's waiting room, the
  front tab is read as before. The rule follows Firefox's tab strip, so a browser whose tabs show
  no such button keeps the front tab. AppleScript would need an Automation permission per browser and gives no URL
  in Firefox, the default browser on the first Mac, and Firefox's profile folder, its session file
  included, is closed to other apps. The watcher asks for the Accessibility permission the first
  time a call starts in a browser, once.
- Control-Option-T starts a recording from any app, or stops the one going on, since Litteroi saves
  when it quits. It is a Carbon hot key (`RegisterEventHotKey`), as are V, A and H, held by the
  watcher, which runs all the time and needs no accessibility permission for them.
  Control-Option-N is held only while a prompt shows, so other apps keep it the rest of the time.
- The keys use Control-Option, which the user chose to keep. Apple's guidelines prefer Command and
  avoid Control, but for shortcuts inside an app; these work while the call app is in front,
  where a Command shortcut may be that app's own, and none is among Apple's standard shortcuts.
  With VoiceOver on, they meet its commands, whose default modifier is Control-Option.
- A recording the watcher opened during a call, from the prompt's Ääni or Kuva, the shortcut or its
  menu, is for that call: once the call is quiet, the same window asks "Lopetetaanko litterointi?". Lopeta ja
  tallenna or Control-Option-T stops and saves, Ei nyt or Control-Option-N keeps the recording
  going, and the window closes again if the call app takes the mic back. The offer waited for the
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
- The user's own track carries their first name, the first word of their macOS account's full name,
  since the user asked for their name rather than Minä; on a Mac with no full name it reads Minä, or
  Me in English. The other labels follow the meeting's language (Puhuja 1, or Speaker 1). The skill
  keeps each line of `korjattu.md` in the language it was spoken in and writes `muistio.md` in the
  meeting's language.
- The app and the watcher show Finnish or English by the user's language order in macOS, from
  String Catalogs (`Localizable.xcstrings`, `InfoPlist.xcstrings`) with Finnish as the source;
  a Mac set to neither shows English.

## Storage

- `~/Litteroi/<yyyy-mm-dd-hhmm>/` holds `mic.caf`, `call.caf`, `screen-<n>-<second>.mov` for each
  display and stretch of screen recording, `.nauhoitus` while the app records,
  `transcript.md` and `transcript.json`, `nimet-ruudulla.txt` when the screens were recorded,
  `nimi.txt`, `lyhenne.txt`, `kysymykset.md` while the skill waits for the user's
  answers, once Claude has finished the meeting `korjattu.md` and `muistio.md`, and the page
  `palaveri.html` with `palaveri.m4a` and a `.mp4` copy of each screen video. Not `~/Documents`
  (iCloud sync) and not inside the app bundle.
- `~/Litteroi/automaattiset.txt` lists the call apps and sites recorded on their own, one a line.
- `litteroi-cli status` gives each recording's length from the size of `mic.caf`, so a slip of a
  few seconds stands out from a meeting.
- `~/Litteroi/sanasto.txt` lists terms and names as they should be written, people first, then
  organisations, then terms. The skill adds each name the user confirms and each term it corrects
  when it finishes a meeting, as the user asked, so the next meetings start from them.
- The tracks are 16 kHz mono 16-bit PCM in CAF, about 115 MB an hour each: the rate Whisper
  works at, and a container that stays readable after a crash, which m4a does not.
- The screen videos are QuickTime files written in 5 s fragments, with a still screen's frame
  repeated every 2 s, so a crash or a kill costs their last seconds; before 12.11.2026 it left
  the whole video unreadable. The tool warns about a video that does not open and carries on.
  Their size an hour is not measured yet.
- Each audio buffer is copied before it is converted to 16 kHz: the converter leaves frames it
  has no use for yet in the buffer it was handed and reads them on its next call. Read straight
  from the IO proc's memory, that crashed the app on 12.11.2026 when Core Audio restarted the
  devices as a call ended and unmapped the buffer.
- The watcher deletes `mic.caf`, `call.caf`, the screen videos and the page's copies of them 14
  days after `muistio.md` was written, checked hourly. By then the minutes have been read, and a
  `[?]` or an unnamed speaker checked against the audio; storage limitation (GDPR Art. 5(1)(e))
  asks for no longer. A meeting not finished keeps its audio and videos. Transcripts and minutes
  stay.

## Privacy

- Recording and transcription run locally and need no data processing agreement. The Claude
  step sends text to Anthropic, which does.
- Participants are told at the start of the meeting, including that the screens are recorded.
  The app shows no reminder: telling them is the user's part. A call on the auto list is recorded
  from its first seconds, before anyone has been told, so the list holds only the apps and sites
  the user added.
- The screen videos show what was shared and the participants' video, so they stay on the Mac
  like the audio: the skill reads only text, and no session opens them. The names read from them
  go to Claude like the names in the transcript, and the other text on the screen does not.
- Voice profiles that recognise people across meetings are biometric data (GDPR Art. 9) and need
  each person's explicit consent. Until then, the user names the speakers when the skill asks.
- The transcript goes to Claude with its names. Hiding the names of a hand-written list first
  meant writing the list before the first meeting, and names Whisper wrote in lower case or in an
  irregular form got through anyway.

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

- `scripts/release.sh` publishes the GitHub release `litteroi-<build>`: the app,
  signed with Developer ID, notarized and stapled, as `Litteroi.zip`. It is signed with Akira
  Taguchi's own developer account, so macOS names Akira Samuel Taguchi as the developer; a Taito
  United Oy account would need a D-U-N-S number and its account holder.
- The releases are as private as the repository: everyone who can read the repository can download
  them, which includes its outside collaborators, and nobody else. They hold the app and the
  subjects of the commits since the last release, never audio, transcripts or names. Apple's
  notary service receives each app to scan it.
- `litteroi-cli` sits inside the app, in `Contents/MacOS`, so one signature, one notarization
  and one download cover both, and the skill finds the tool at the same path on every Mac.
- Updates come through the skill: typing litteroi first runs `scripts/update.sh`, which pulls
  main for the skill and installs the newest release with `gh` when its build is above the
  installed app's. Everyone who uses Litteroi already needs this repository and Claude Code for
  the transcription, so the updates need no hosting or IT, only `gh` signed in to an account
  that can read the repository. Litteroi lived in `TaitoUnited/ai-library` until 5.11.2026, whose
  releases litteroi-2 and litteroi-3 hold the builds before the move.
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
