# Litteroi

Finnish meeting transcription for macOS, fully on-device. Swift package: `LitteroiCore` runs
Whisper large-v3 through WhisperKit and labels speakers with SpeakerKit (pyannote community-1),
both from `argmaxinc/argmax-oss-swift`. `litteroi-cli` runs the pipeline on audio files. The
recording app is still to be built; [docs/design.md](docs/design.md) holds the decisions for it.

## Commands

- Build: `swift build`
- Test: `swift test`
- Transcribe: `.build/debug/litteroi-cli <mic.wav> [--call <call.wav>] --output <folder>`
  writes `transcript.md` and `transcript.json`. Without `--call` the mic track is split by
  speaker; with it the mic track is "Minä" and only the call track is split.
- Models download on first run into `~/Library/Application Support/Litteroi/models`
  (Whisper large-v3 about 3.1 GB, SpeakerKit models about 33 MB).
- Test audio lives outside the repo in `~/Downloads/litteroi-test-audio`: `podcasts/` (full
  episodes), `clips/` (16 kHz mono cuts made with ffmpeg) and `results/`.

## Rules

- Keep `openai_whisper-large-v3` with language `fi`. Turbo, Parakeet v3 and Qwen3-ASR made
  more errors on Finnish in the GAIK benchmark (github.com/GAIK-project/finnish-asr).
- Audio and transcripts never leave the Mac: no cloud APIs.
- Models, recordings and transcripts never go under `~/Documents`, which iCloud may sync.
  WhisperKit defaults to `~/Documents/huggingface`, so always pass `downloadBase`.
- Speaker labels and user-facing text are Finnish; code and identifiers are English.
