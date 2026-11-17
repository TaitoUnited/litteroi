---
name: litteroi
description: Finish Litteroi meetings. Transcribes recordings in ~/Litteroi that have no transcript yet, asks the user who each speaker is, then rewrites the transcript into understandable Finnish, writes the minutes, copies the meeting to its Claude Code project and drafts its share in Slack. Load when the user types litteroi or litteroi finish, or asks to finish, correct or summarise a Litteroi meeting.
---

# Litteroi finish

Run bare, this finishes every meeting under `~/Litteroi` that is not finished yet. The audio and
the screen videos never leave the Mac and no session opens them; the transcript, the names
`litteroi-cli` reads from the screen videos on the Mac and whose tile the call outlined as speaking
go to Claude.

## Steps

The tool is `~/Applications/Litteroi.app/Contents/MacOS/litteroi-cli`.

1. Bring Litteroi up to date. The script pulls the Litteroi repository's main for this skill and
   installs the newest Litteroi release from GitHub when it is newer than the installed app, which
   holds the tool. It leaves a checkout alone that is on another branch or has changes of its own in
   the folder, and never replaces the app while it records. Tell the user in a line what it printed.
   When it fails, go on with the tool already installed:

   ```bash
   ~/Projects/litteroi/scripts/update.sh
   ```

2. List the meetings. Each line is a stage, `litteroimatta` (recorded), `litteroitu` (transcribed)
   or `valmis` (finished), then the meeting's folder, the recording's length and its name when it
   has one. A recording of a minute or less is most likely a slip: the reply asks whether to move
   its folder to the Trash with `trash`, and it waits for the answer before steps 4 and 5. The
   meeting being recorded shows as
   `nauhoitetaan (ääni)` or `nauhoitetaan (ääni ja video)`: tell the user which, and leave it
   alone:

   ```bash
   ~/Applications/Litteroi.app/Contents/MacOS/litteroi-cli status
   ```

3. When any meeting is `litteroimatta`, transcribe them all, one after another. The app only
   records, so this is where Whisper runs, and where the names on the screen videos are read into
   `nimet-ruudulla.txt` and whose tile was outlined as speaking into `puhujat-ruudulla.txt`; a
   meeting the app is still recording is left alone. A warning that a screen video does not open,
   `näyttövideo ... ei aukea`, means a crash cut it off: its names and outlines are not read and
   the page shows no video for it, which the reply says.
   Whisper takes about 20 minutes per hour of audio on this Mac, so run it with the Bash tool's
   `run_in_background`, tell the user it is running, and go on with the next steps for the
   `litteroitu` meetings meanwhile. When its notification arrives, list the meetings again and
   finish the ones it transcribed:

   ```bash
   ~/Applications/Litteroi.app/Contents/MacOS/litteroi-cli transcribe-pending
   ```

   A `Varoitus` line means that meeting's call track was recorded at the wrong rate, so its call
   side is likely nonsense: name the meeting and both lengths in the reply, and finish it only
   once the user has had the track repaired or says to go on.

4. Read each `litteroitu` meeting's `transcript.md`, its `nimet-ruudulla.txt` and
   `puhujat-ruudulla.txt` when it has them, and `~/Litteroi/sanasto.txt`, name the meeting as
   below and write `korjattu.md`, with the
   speaker labels the user has not named yet left as they are. Then write the questions about who
   the speakers are, and the meeting's name when it is still open, into the meeting's
   `kysymykset.md`, quoting the lines of `korjattu.md`, and write the meeting's page, where the
   user answers them. The reply gives each meeting's page address and its questions, one line
   each with the label and the guess, says to answer on the page and paste the prompt that its
   button, or `Enter` from the last answer, copies, and ends the turn there. The next-step box
   under that reply carries no question and no button that takes every guess at once: the page
   is where the user answers.

5. Once the user has answered, by the page's prompt or in the chat, put the names into
   `korjattu.md`, write `muistio.md`, add to the glossary as below, delete `kysymykset.md` once
   nothing in it is open, write the page again and copy the meeting to its project. The answer
   `kyllä` takes the question's guess or its recommended answer. A question the prompt leaves
   open, `ei vastausta, jää auki`, stays in `kysymykset.md` and is asked again with its context.

6. Make each meeting finished in step 5 ready to share in Slack, as below.

7. Reply with each meeting's page address and its share. A meeting still transcribing in the
   background is named with the run it waits on; finish it when the run's notification arrives.

Every reply names each meeting by its date and its name, such as 3.11. Viral Vegans x Taito
United, never by its folder alone.

## The page

`litteroi-cli page` writes `palaveri.html` into the meeting folder: the questions, the minutes and
the whole transcript, the corrected one once it exists. Every timestamp on it plays the meeting
from that moment, and the screen videos show what was on screen then. The first run mixes the two
tracks into `palaveri.m4a` and copies each screen video as an `.mp4`, which Firefox plays.

Each numbered question in `kysymykset.md` gets a field on the page for its answer, such as a name,
the same person as another label, a mix of two voices or don't know; a term for the glossary or a
note, such as part of a line being someone else's, goes into the answer it belongs to. Its
button copies the answers as a prompt that starts `litteroi, vastaukset palaveriin <folder>` and
gives each answer by its question number, and the page keeps what the user typed until then.
The page opens with the cursor in the first unanswered question's field.
The cursor stays in an answer. `Enter` moves it on to the next question's field and pauses the
meeting, and from the last answer it copies the answers. In an empty answer `Enter` takes the
guess without writing in the field, which then shows `kyllä` greyed out, and the prompt gives that
answer as `kyllä`. `Shift+Enter` moves the cursor back to the previous question's field. `Ctrl+P`
plays and pauses, `Ctrl+L` plays the asked line, and a click on a timestamp inside a question
plays it and keeps the cursor in that question's answer. The selected question lists these keys.

A quoted line under a question plays from where its quoted part is said to half a second after it
ends, by the word times in `transcript.json`, so cut a long line to the part that matters and leave
the rest to the page. A transcript from before 10.11.2026 has no word times and its quoted lines
play from the line's start; this adds them, at about 20 minutes per hour of audio:

```bash
~/Applications/Litteroi.app/Contents/MacOS/litteroi-cli words ~/Litteroi/<meeting>
```

Every reply that asks about a meeting or finishes it gives its page's `file://` address, with the
full path from the root, in a `text` block of its own on one line, which the user copies into
Firefox's address bar, since the desktop app sends a click on a `file://` link to its side pane:

```text
file:///Users/<user>/Litteroi/<meeting>/palaveri.html
```

```bash
~/Applications/Litteroi.app/Contents/MacOS/litteroi-cli page ~/Litteroi/<meeting>
```

## The meeting's name

Each meeting gets a name. When a calendar connector is there, it is the title of the user's own
event that runs at the recording's start, the folder's name, or starts within 15 minutes after
it, and that event's attendees are the people who may have spoken. Without such an event, name
the meeting from the transcript and ask the user in step 4 to confirm it, with that name as the
recommended answer. Write the name into the meeting's `nimi.txt`, which the page, `status` and
the project's copy show.

Write a short name into the meeting's `lyhenne.txt` too, which names the PDF to share: the kind
of meeting in a word, then a word or two for the meeting, such as `daily sis-meks`, which gives
`daily-mon-9-nov-2026-sis-meks-transcription.pdf`. The kind is what the user calls the meeting,
which can differ from the event's title: the user calls the Monday "Sisäinen: Meks weekly" a
daily. Take both from the project's memory when it names them for the series; otherwise pick them,
and when unsure ask in step 4 with the pick as the recommended answer. Two meetings of one day get
short names that differ, so neither PDF replaces the other.

## Asking who spoke

The user's own lines carry their first name, the first word of `id -F`; a transcript from before
5.11.2026 labels them `Minä`, or `Me` in English, and `korjattu.md` gives them the first name
instead. For every other speaker label, `Puhuja 1` or `Speaker 1` and so on, give Claude's guess
with what it rests on, then the context of one or two of that speaker's lines, picked to show who it
is, such as a greeting by name or the speaker's own topic: the line before, the speaker's line and
the line after, each with its timestamp and label, a long line cut to its part that matters with
`...`. List the speaker's other short lines with their times; no time to listen from, since the
page plays each quoted line from its quoted part. Number each meeting's questions from 1, in the
order the meeting reached them: by the time of each question's earliest line, quoted or listed, so
the page reads from the start of the meeting to its end. A question asked again is numbered anew
with the rest. Each page copies its own prompt, which names its folder, and in the chat the
questions stand under each meeting's folder name, so a number need not be unique across meetings.
Ask too about a name the transcript spells two ways or that Whisper may have misheard. The user may
confirm a guess, give a name, say two labels are one person, say a label mixes two people, call its
lines unclear, which makes them `Epäselvä`, or say they do not know; a question the user cannot
settle from the text is asked again with its context.

When the mic track holds no speech, or only what Whisper makes of silence, such as `you`, check
the track before any reply or the minutes say why. A stretch in which every sample of `mic.caf`
is zero means Litteroi got no sound from the Mac's mic at all, since a live mic never gives exact
zero; this lists each one over 5 s with its start and end in seconds:

```bash
ffmpeg -hide_banner -nostats -i ~/Litteroi/<meeting>/mic.caf \
  -af silencedetect=noise=-85dB:d=5 -f null - 2>&1 | grep silence_
```

Of the meetings up to 17.11.2026 only two had such a stretch. In the 5.11. daily it ran from
00:23:54 to the end, from the moment the MacBook's lid closed, which cuts its built-in mic. In
the 17.11. daily it ran from start to end with the lid open, while Meet in Firefox ran Apple's
voice processing on the same built-in mic. While a call app does that, macOS hands the mic to
other apps as 3 channels with a discrete layout, and Litteroi's conversion to 16 kHz mono turns
those into zeros with no error, as a test on 17.11.2026 showed; the user's mute in the call plays
no part. Litteroi mixes such input down itself from the build of 17.11.2026 on, so a zero mic
track from a later meeting has another cause. The reply names each stretch as a recording fault
with what the Mac's log shows for it, such as a `Clamshell state changed` line of `loginwindow`,
and the minutes say the mic recorded nothing then and guess at no line of the user's. The user
asked for this check on 17.11.2026.

`nimet-ruudulla.txt` lists the names the call app showed on the screen, one a line with when each
was first and last on screen, and the calendar event lists who was invited. Both say who was in
the call, not who spoke a line, so a guess still rests on the lines; a name on the screen that
the event does not list may be text from another window, such as a document, and is named as
such. Someone on the screen or in the event who matches no speaker is named in the questions, so
the user can say whether they spoke.

`puhujat-ruudulla.txt` says whose tile Google Meet outlined as speaking while each label's words
were said, read from every frame of the screen videos. Its first lines hold one speaker label
each, tab-separated: the label, the seconds of its words, the seconds of those with an outlined
tile on screen, then each name on those tiles with its share of the outlined seconds, as in
`Puhuja 2	178 s	99 s	Emma Hammer 97 %`. After an empty line come the transcript's lines with half
a second or more of outline: timestamp, label, outlined seconds and names. A meeting with screen
videos that was transcribed before 17.11.2026 gets the file in a few seconds with:

```bash
~/Applications/Litteroi.app/Contents/MacOS/litteroi-cli speakers ~/Litteroi/<meeting>
```

- A label with 10 s or more of outline and one name at 70 % or more gets that name as its guess,
  and the question's own line says so with the share and the seconds, as in `Emma Hammer, jonka
  ruutu oli kehystettynä 97 % ajasta (99 s / 178 s)`. In the seven Meet meetings finished by
  17.11.2026 all 15 such labels had that name in the minutes.
- With fewer seconds or a lower share the tile is a hint beside what the lines say, and the
  question names both. Of 9 such labels, 6 had the top name in the minutes.
- A label with many outlined seconds split between two names likely mixes two people: ask that,
  and take each line's speaker from its own row when the row has 5 s or more of outline and one
  name at 80 % or more, which matched the minutes on 65 of 66 lines. A row with less matched on
  60 of 73, so it decides nothing alone.
- The outline shows whose microphone carried the sound, not whose voice. Two people in one room
  speak through one tile, or through none when both are muted. A short line said while someone
  else talks shows the tile of the one talking. The Mac never plays the user's own microphone, so
  the user's tile is left out for every label but their own.
- The file knows only the time Meet's tiles were on the screen, which the outlined seconds show:
  while the user looked at another window there is nothing, and a tile whose name is hidden or cut
  short is left out. Teams, Signal and other call apps are not read, so for those, and for a label
  with no outlined seconds, the guess rests on the lines as before.

`kysymykset.md` holds the same questions as a numbered list in Markdown, each context line a
sub-item in the transcript's own form, `[00:12:06] **Puhuja 2:** text`, so the page plays it.
The label a question asks about stands in bold on the question's own line, as `**Puhuja 2**`:
the quoted lines with that label are the ones `Ctrl+L` plays, and every quoted line when none has it.
Put each question as its guess or its recommended answer, so that yes takes it, since `Enter` in
an empty field answers `kyllä`: `Jätetäänkö X pois?` when leaving X out is recommended, never a
question whose yes means the other choice.

A question, its quoted lines and its field fit on the page's first screen without scrolling. The
question's own line is the label, the guess and what it rests on, in at most 250 characters. Under
it stand at most three quoted lines, each cut to under 100 characters, and at most six other
times. What a yes does to single lines, such as which lines of a mixed label get which name, stays
out of the question: step 5 works that out by the rules of `korjattu.md`, and the minutes say it.
A point that needs more room is split into several questions. `kysymykset.md` has no text above
its first question: what the user should know about the recording, such as a broken screen video
or how many lines were left out, goes in the reply.

## korjattu.md

The transcript as Finnish or English that a reader understands, each line kept in the language it
was spoken in. Whisper mishears words, breaks inflections, runs words together and fills a
silence with stock phrases, so Claude reads every line against the lines around it, the glossary
and the user's answers, and writes what the speaker most likely said. The user asked for this:
a line that does not read as Finnish is a line they cannot use. `transcript.md` keeps Whisper's
words, so nothing is lost.

- Keep the lines in their order, each with its timestamp, and never merge or split one. Leave out
  a line with nothing meaningful in it, as the user asked: what Whisper made up in a silence, such
  as "Kiitos kun katsoit videon!", "Amen" or "Thank you" on the user's own track, the words of
  music before or after the meeting, and a line where no reading makes sense at all. Never write
  a line that holds only `[ei puhetta]`, `[musiikkia]` or `[epäselvä]`. A short reply such as
  `Joo`, `Jep` or `Huomenta` is speech and stays, however short, since it can be an answer, as
  the user said.
- Replace each speaker label with the name the user gave for it, and the user's own label with
  their first name. A label the user did not name stays as it is.
- A line whose speaker cannot be told, because people talk over each other, there is noise or
  Whisper put several voices under one label, gets the label `Epäselvä`, or `Unclear` in English,
  as the user asked. So do the `Tuntematon` and `Päällekkäin` lines, `Unknown` and `Overlapping`
  in English, unless their content shows who speaks. When the user says a label mixes two people,
  each of its lines whose content shows the speaker gets that name and the rest get `Epäselvä`. A
  line that holds two known speakers gets both names, such as `Emma ja Clara`, and the minutes say
  where the second one starts.
- Rewrite every word or phrase that makes no sense in its sentence into what the speaker most
  likely meant, such as a misheard term or name, a broken ending or a word Whisper made of two,
  until the line reads as understandable Finnish. Keep the speaker's own wording where it already
  makes sense, with its filler words and spoken forms such as `mä` and `et`: this fixes the
  hearing, it does not turn speech into written Finnish.
- Put `[?]` after the words of a fix that is a guess. Where no reading makes sense, write
  `[epäselvä]`, or `[unclear]` in English, in place of the passage, never Whisper's nonsense.

## muistio.md

The minutes, in the language most of the transcript is in, in this shape. In English the headings
are `Minutes`, `Speakers`, `Summary`, `Decisions`, `Action items` and `Unclear points`:

```markdown
# Muistio <meeting folder name>: <meeting name>

## Puhujat

- Puhuja 1: Matti Meikäläinen.
- Puhuja 2 ja Puhuja 3: Liisa Virtanen.
- Puhuja 4: ei tiedossa, puhuu asiakkaan puolesta 00:14:40.

## Tiivistelmä

Muutama kappale siitä, mitä palaverissa käsiteltiin.

## Päätökset

- Mitä päätettiin (00:21:05).

## Tehtävät

- Matti Meikäläinen: mitä tehdään ja milloin (00:25:30).

## Epäselvät kohdat

- 00:30:12: mikä jäi epäselväksi ja miksi.
```

Leave out a section with nothing in it.

The minutes state only what a line of `korjattu.md` says. An answer the recording does not hold,
such as one read from how the asker reacted to it, goes under `Epäselvät kohdat` with the time of
the question, never into the summary as a fact: a later session plans on what the minutes say.

## The project's copy

Once `muistio.md` is written, the meeting is copied as one Markdown file, the minutes and then the
corrected transcript, into the Claude Code project it belongs to, so later sessions there can
read it. The copy goes to `meetings/` beside that project's memory folder, outside `memory/`,
since the memory of a team's repository is shared with colleagues and a meeting is not:

```bash
~/Applications/Litteroi.app/Contents/MacOS/litteroi-cli export \
  ~/Litteroi/<meeting> ~/.claude/projects/<project key>/meetings
```

The project key is the project's folder with every `/` and `.` as `-`, as the folders under
`~/.claude/projects` show, such as `-Users-<user>-Projects-meks-manager` for the MEKS meetings.
Pick the project from what the meeting is about and the user's earlier answers. When no project
fits or two do, ask in the questions of step 4, with a recommended answer; a meeting the user says
belongs to no project gets no copy. The first time a project gets a copy, add a note `meetings.md`
with `share: no` to its memory that says where its meetings are, and an index line for it in its
`MEMORY.md`. The copy is written again whenever the meeting is.

## The share in Slack

Every finished meeting ends with a share the user posts in Slack. Slack cuts a message at 40,000
characters, less than an hour of transcript, so the transcript goes as a PDF, which the tool writes
into `~/Downloads/litteroi/` and whose path it prints:

```bash
~/Applications/Litteroi.app/Contents/MacOS/litteroi-cli pdf --minutes \
  ~/Litteroi/<meeting> ~/Downloads/litteroi
```

The PDF is A4, named from `lyhenne.txt` such as `daily-mon-9-nov-2026-sis-meks-transcription.pdf`,
and holds the title, a
note that a machine transcribed the recording and Claude corrected it for reading, the whole of
`muistio.md` and every line with its time; without `--minutes` it holds only the speakers of
`muistio.md`. Read it and look at every page before the reply hands it
over.

The share is a post, or a reply in a thread, of one line with the PDF attached: the meeting's
name and date, that it was recorded and transcribed, and the topics of `muistio.md` as the words a
later search would use, such as `Meks weekly 9.11. (nauhoitettu ja litteroitu, muistio ja
litterointi liitteenä): bussikorjaus, Sentry, AWS-tunnukset`. People read the PDF, which carries
the minutes and the whole transcript, so the decisions and the action items stay out of the post.
Slack's search finds the words of a message but not those inside a PDF, so the topics are in the
line for that search alone; Claude reads a meeting from `~/Litteroi` and the project's copy.

The place is the one the project's memory names for the meeting, such as its note on meetings.
Without one, search Slack, private channels and DMs included, for where the attendees talk, such
as a thread where the organiser posted minutes, ask in the reply with a recommended answer, and
write the answer into the project's memory, so the next meeting of the series goes there too.

Draft it with the `slack-draft` skill, in the place's language and register. A line of words
alone needs no clipboard, so the reply gives it in a `text` block. Litteroi tells no one else in the call that it records, so the draft says
the meeting was recorded, and the reply says that the user posts it only when the attendees are
fine with that. The reply names the channel and the thread in words, and gives the PDF's `file://`
address in a `text` block of its own, which the user copies into Firefox's address bar to read
it, and a step to attach it in Slack's own upload dialog from Downloads > litteroi, never a Finder
command.

## The glossary

`~/Litteroi/sanasto.txt` holds terms and names as they should be written, one per line: people
first, then organisations, then product, tool and technical terms. It grows as meetings are
finished: in step 5, add every name the user confirmed, every term or name Claude corrected in
`korjattu.md` that is not a guess marked `[?]`, and every term an answer spells out for it,
each in its group and only when the file does not have it yet. The reply names what was added.
