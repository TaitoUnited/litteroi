# Design decisions

## Recording app

- A Mac app named Litteroi, so Spotlight finds it with "litteroi".
- Opening it shows a small window (timer, mic and call levels, Lopeta) and starts recording.
- Cmd+W closes the window and stops recording. The app switches to a menu bar icon only
  (`NSApp.setActivationPolicy(.accessory)`), shows saving and transcription progress, and quits
  when the transcript is written. Cmd+Q does the same. A transcription cut short resumes at the
  next launch.
- Audio is written while recording, so a crash still leaves a usable file.
- Two tracks: the mic (AVAudioEngine) and call audio from Teams, Slack and browsers only, through
  Core Audio process taps (macOS 14.2+, `NSAudioCaptureUsageDescription`, "system audio
  recording" permission). With no call, the call track is silent and dropped.
- In-person meetings use the mic track alone, split by speaker.

## Meeting detection (optional setting)

- An idle menu bar icon started at login checks every couple of seconds which processes use the
  mic (`kAudioHardwarePropertyProcessObjectList`, `kAudioProcessPropertyIsRunningInput`; no
  permission needed). Polling, because change listeners are reported unreliable.
- When a call app holds the mic for a few seconds, a notification asks "Palaveri alkoi (Teams).
  Litteroidaanko?" and reminds to tell the participants. It never starts recording on its own.

## Storage

- `~/Litteroi/<yyyy-mm-dd-hhmm>/` holds `mic.m4a`, `call.m4a`, `transcript.md` and
  `transcript.json`. Not `~/Documents` (iCloud sync) and not inside the app bundle.
- Audio is deleted after a set number of days; transcripts stay.

## Privacy

- Everything runs locally, so transcription needs no data processing agreement.
- Participants are told at the start of the meeting.
- Voice profiles that recognise people across meetings are biometric data (GDPR Art. 9) and need
  each person's explicit consent. Until then, speakers are named by hand after the meeting.
- Transcripts sent to a cloud AI are pseudonymised first (names to Henkilö A, clients to
  Asiakas 1) and the key stays on the Mac.

## Distribution

- Developer ID signed and notarized DMG under Taito United Oy's Apple Developer account, shared
  internally, with Sparkle for updates. A Homebrew cask pointing at the same DMG is optional.
