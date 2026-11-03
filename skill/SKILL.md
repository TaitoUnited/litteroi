---
name: litteroi
description: Finish Litteroi meetings. Transcribes recordings in ~/Litteroi that have no transcript yet, hides the listed names, then fixes Whisper's mistakes, guesses who the speakers are and writes the minutes, and puts the names back on the Mac. Load when the user types litteroi or litteroi finish, or asks to finish, correct or summarise a Litteroi meeting.
---

# Litteroi finish

Run bare, this finishes every meeting under `~/Litteroi` that is not finished yet. The audio never
leaves the Mac, and only text with the listed names hidden reaches Claude.

## What this session may read

A meeting's own `transcript.md` and `transcript.json` hold the real names of colleagues and clients,
and so do `~/Litteroi/nimet.txt`, the key `avain.json` and the restored `korjattu.md` and
`muistio.md`. Whatever this session reads goes to Anthropic, so it never reads, greps, prints or
copies any of them, with the Read tool or through Bash. It reads only:

- `~/Litteroi/<meeting>/claude/transcript.md`, the transcript with the names hidden
- `~/Litteroi/sanasto.txt`, the user's glossary, when it exists

The tool prints counts and paths, never names.

## Steps

The tool is `~/Applications/Litteroi.app/Contents/MacOS/litteroi-cli`.

1. Bring Litteroi up to date. The script pulls ai-library's main for this skill and installs the
   newest Litteroi release from GitHub when it is newer than the installed app, which holds the
   tool. It leaves a checkout alone that is on another branch or has changes of its own in the
   folder, and never replaces the app while it records. Tell the user in a line what it printed.
   When it fails, go on with the tool already installed:

   ```bash
   ~/Projects/ai-library/litteroi/scripts/update.sh
   ```

2. List the meetings. Each line is a stage, `litteroimatta` (recorded), `litteroitu` (transcribed)
   or `valmis` (finished), then the meeting's folder:

   ```bash
   ~/Applications/Litteroi.app/Contents/MacOS/litteroi-cli status
   ```

3. When any meeting is `litteroimatta`, transcribe them all, one after another. The app only
   records, so this is where Whisper runs; a meeting the app is still recording is left alone.
   Whisper takes about 20 minutes per hour of audio on this Mac, so run it with the Bash tool's
   `run_in_background`, tell the user it is running, and go on with the next steps for the
   `litteroitu` meetings meanwhile. When its notification arrives, list the meetings again and
   finish the ones it transcribed:

   ```bash
   ~/Applications/Litteroi.app/Contents/MacOS/litteroi-cli transcribe-pending
   ```

4. Hide the names in each `litteroitu` meeting. When `~/Litteroi/nimet.txt` is missing, the tool
   refuses: stop there and give the user the format below, since the names are theirs to write.

   ```bash
   ~/Applications/Litteroi.app/Contents/MacOS/litteroi-cli pseudonymize <meeting folder>
   ```

5. Read `<meeting folder>/claude/transcript.md` and `~/Litteroi/sanasto.txt`, then write the two
   files below into `<meeting folder>/claude/`.

6. Put the names back. This writes `korjattu.md` and `muistio.md` into the meeting folder:

   ```bash
   ~/Applications/Litteroi.app/Contents/MacOS/litteroi-cli restore <meeting folder>
   ```

7. Reply with each meeting's `korjattu.md` and `muistio.md` as links, the counts the tool printed
   in step 4, and the words in `claude/transcript.md` that look like names of people or companies
   but were not hidden, so the user can add them to `nimet.txt`. Say that the speaker guesses are
   in the minutes for them to check. A meeting still transcribing in the background is named with
   the run it waits on; finish it when the run's notification arrives.

## The hidden names

People are `Henkilö A`, `Henkilö B` and so on, clients `Asiakas 1`, `Asiakas 2`, in the order they
are first mentioned. A case ending follows a colon: `Henkilö A:lle`, `Asiakas 1:n`. Keep every
one as written, never guess who it is, and write a new mention the same way. Prefer a sentence
that needs no ending, such as `Henkilö A: lähettää tarjouksen`, since a new ending comes back as
the listed name followed by a colon, as in `Matti Meikäläinen:lle`.

## korjattu.md

The transcript with Whisper's mistakes fixed, each line kept in the language it was spoken in:

- Keep every line, its timestamp and its speaker label, in the same order. Never merge, split or
  relabel lines.
- Fix a word only when the context or the glossary makes the right one clear, such as a misheard
  technical term or a word that makes no sense in the sentence. Keep filler words and spoken
  forms such as `mä` and `et`, since the transcript records what was said.
- Where the right word is unclear, keep Whisper's word and add `[?]` after it.

## muistio.md

The minutes, in the language most of the transcript is in, in this shape. In English the headings
are `Minutes`, `Speakers`, `Summary`, `Decisions`, `Action items` and `Unclear points`:

```markdown
# Muistio <meeting folder name>

## Puhujat

- Puhuja 1: todennäköisesti Henkilö B, häntä kiitetään nimeltä 00:03:12.
- Puhuja 2 ja Puhuja 3 voivat olla sama henkilö: puhe jatkuu kesken lauseen 00:14:40.

## Tiivistelmä

Muutama kappale siitä, mitä palaverissa käsiteltiin.

## Päätökset

- Mitä päätettiin (00:21:05).

## Tehtävät

- Henkilö A: mitä tehdään ja milloin (00:25:30).

## Epäselvät kohdat

- 00:30:12: mikä jäi epäselväksi ja miksi.
```

`Minä`, or `Me` in English, is the user. Base every speaker guess on the text, such as being
addressed by name, and say what it rests on, since nobody can hear the audio here. Leave out a
section with nothing in it.

## The user's files

`~/Litteroi/nimet.txt` is written by the user and never read here. Give them this format when it
is missing:

```text
# Yksi henkilö riville, muut nimen muodot pilkun jälkeen.
Matti Meikäläinen, Masa
Liisa Virtanen

[asiakkaat]
Esimerkki Oy
```

`~/Litteroi/sanasto.txt` holds terms as they should be written, one per line, such as product,
tool and technical terms. Claude reads it, so names of people and clients go in `nimet.txt`
instead.
