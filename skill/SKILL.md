---
name: litteroi
description: Finish Litteroi meetings. Transcribes recordings in ~/Litteroi that have no transcript yet, asks the user who each speaker is, then rewrites the transcript into understandable Finnish, writes the minutes, copies the meeting to its Claude Code project and drafts its share in Slack. Load when the user types litteroi or litteroi finish, or asks to finish, correct or summarise a Litteroi meeting.
---

# Litteroi finish

Run bare, this finishes every meeting under `~/Litteroi` that is not finished yet. The audio and
the screen videos never leave the Mac and no session opens them; the transcript and the names
`litteroi-cli` reads from the screen videos on the Mac go to Claude.

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
   `nimet-ruudulla.txt`; a meeting the app is still recording is left alone.
   Whisper takes about 20 minutes per hour of audio on this Mac, so run it with the Bash tool's
   `run_in_background`, tell the user it is running, and go on with the next steps for the
   `litteroitu` meetings meanwhile. When its notification arrives, list the meetings again and
   finish the ones it transcribed:

   ```bash
   ~/Applications/Litteroi.app/Contents/MacOS/litteroi-cli transcribe-pending
   ```

4. Read each `litteroitu` meeting's `transcript.md`, its `nimet-ruudulla.txt` when it has one,
   and `~/Litteroi/sanasto.txt`, name the meeting as below and write `korjattu.md`, with the
   speaker labels the user has not named yet left as they are. Then write the questions about who
   the speakers are, and the meeting's name when it is still open, into the meeting's
   `kysymykset.md`, quoting the lines of `korjattu.md`, and write the meeting's page, where the
   user answers them. The reply gives each meeting's page address and its questions, one line
   each with the label and the guess, says to answer on the page and paste the prompt its button
   copies, and ends the turn there.

5. Once the user has answered, by the page's prompt or in the chat, put the names into
   `korjattu.md`, write `muistio.md`, add to the glossary as below, delete `kysymykset.md` once
   nothing in it is open, write the page again and copy the meeting to its project. A question
   the prompt leaves open, `ei vastausta, jää auki`, stays in `kysymykset.md` and is asked again
   with its context.

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
the same person as another label, a mix of two voices or don't know, and the page has fields for
terms to add to the glossary and for other notes, such as part of a line being someone else's. Its
button copies the answers as a prompt that starts `litteroi, vastaukset palaveriin <folder>` and
gives each answer by its question number, and the page keeps what the user typed until then.
On the page, `j` and `k` select the next and the previous question, `Enter` puts the cursor in its
field and `Esc` takes it out, space plays and pauses the meeting and `c` copies the answers; the
selected question lists these keys. `Enter` in an answer moves the cursor on to the next question's
field, and `Shift+Enter` makes a new line.

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

## Asking who spoke

The user's own lines carry their first name, the first word of `id -F`; a transcript from before
5.11.2026 labels them `Minä`, or `Me` in English, and `korjattu.md` gives them the first name
instead. For every other speaker label, `Puhuja 1` or `Speaker 1` and so on, give Claude's guess
with what it rests on, then the context of one or two of that speaker's lines, picked to show who it
is, such as a greeting by name or the speaker's own topic: the line before, the speaker's line and
the line after, each with its timestamp and label, a long line cut to its part that matters with
`...`. Add a time a few seconds before to listen from, and list the speaker's other short lines with
their times. Number the speakers, one meeting after another under the meeting's folder name, so the
user can answer each by its number. Ask too about a name the transcript spells two ways or that
Whisper may have misheard. The user may confirm a guess, give a name, say two labels are one person,
say a label mixes two people, call its lines unclear, which makes them `Epäselvä`, or say they do
not know; a question the user cannot settle from the text is asked again with its context.

`nimet-ruudulla.txt` lists the names the call app showed on the screen, one a line with when each
was first and last on screen, and the calendar event lists who was invited. Both say who was in
the call, not who spoke a line, so a guess still rests on the lines; a name on the screen that
the event does not list may be text from another window, such as a document, and is named as
such. Someone on the screen or in the event who matches no speaker is named in the questions, so
the user can say whether they spoke.

`kysymykset.md` holds the same questions as a numbered list in Markdown, each context line a
sub-item in the transcript's own form, `[00:12:06] **Puhuja 2:** text`, so the page plays it.

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

The PDF is A4, named such as `litterointi-sisainen-meks-daily-5-nov.pdf`, and holds the title, a
note that a machine transcribed the recording and Claude corrected it for reading, the whole of
`muistio.md` and every line with its time; without `--minutes` it holds only the speakers of
`muistio.md`. Read it and look at every page before the reply hands it
over.

The share is a post, or a reply in a thread, whose text holds the decisions and the action items
of `muistio.md`, with the PDF attached. Slack's search finds the words of a
message but not those inside a PDF, so what a later search, Claude's included, should find goes in
the text, and the PDF carries the summary and the whole transcript.

The place is the one the project's memory names for the meeting, such as its note on meetings.
Without one, search Slack, private channels and DMs included, for where the attendees talk, such
as a thread where the organiser posted minutes, ask in the reply with a recommended answer, and
write the answer into the project's memory, so the next meeting of the series goes there too.

Draft it with the `slack-draft` skill, in the place's language and register, so a post with lists
goes on the clipboard. Litteroi tells no one else in the call that it records, so the draft says
the meeting was recorded, and the reply says that the user posts it only when the attendees are
fine with that. The reply names the channel and the thread in words, and gives the PDF's `file://`
address in a `text` block of its own, which the user copies into Firefox's address bar to read
it, and a step to attach it in Slack's own upload dialog from Downloads > litteroi, never a Finder
command.

## The glossary

`~/Litteroi/sanasto.txt` holds terms and names as they should be written, one per line: people
first, then organisations, then product, tool and technical terms. It grows as meetings are
finished: in step 5, add every name the user confirmed, every term or name Claude corrected in
`korjattu.md` that is not a guess marked `[?]`, and every term the prompt lists under `Sanastoon`,
each in its group and only when the file does not have it yet. The reply names what was added.
