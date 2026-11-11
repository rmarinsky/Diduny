import Foundation

/// `diduny guide`: the full instructions for agents. The installed skill only points here,
/// so the instructions always match the installed version of the tool.
enum Guide {
    static func text(command: String) -> String {
        """
        # Diduny for agents

        Diduny is a macOS app that records meetings, voice notes and translations and transcribes them.
        `\(command)` reads its library on this Mac. It only reads; it never changes recordings.
        Diduny does not need to be running.

        ## Find a meeting

        - `\(command) meetings list` lists meetings, newest first, as a Markdown table with short ids.
          - `--since 7d` (or 24h, 2w, 2026-11-01) limits the range.
          - `--type voice|translations|files|all` lists other recordings; the default is meetings.
          - `--limit 20` caps the number of rows. `--json` returns JSON.
        - `\(command) search "text"` finds words in transcripts, titles, descriptions and invitations.
          It prints each match with the meeting, its short id and the time `[mm:ss]` where it was said.
          Takes the same `--type`, `--since` and `--json` options.
        - Ids: use the short id from the list, the full id, or `latest`.

        ## Read a meeting

        `\(command) meetings show <id>` prints, in this order:
        - title, start, length, status and the audio file path;
        - the calendar event, when Diduny linked one: scheduled time, calendar, attendees with email,
          organizer and "(you)" for the user, location, meeting link, and the agenda from the invitation;
        - chapters the user marked while recording;
        - the transcript. Lines are `[mm:ss] Speaker N: text`. Speaker numbers come from the
          recognizer and are not names. Match them to attendees only when the transcript makes it
          clear (someone is addressed by name, introduces themselves, or the context leaves no doubt),
          and say when you are guessing.

        `--json` returns the same data with `segments` (time, startMs, endMs, speaker, text) and
        `transcriptVersions` (earlier transcripts and translations). `--no-transcript` leaves the
        transcript out when only the context is needed.

        `\(command) audio <id>` prints the path of the audio file, for tools that work with audio.

        ## What to do with a meeting

        Work only from the transcript and the calendar event. If something was not said, do not add it.
        Transcripts come from speech recognition: names, numbers and product terms can be misheard.
        Use the attendee list and the invitation to spell names, and flag anything that looks misheard
        instead of silently correcting it.

        - Summary: 2 to 4 sentences on what the meeting was about and how it ended.
        - Decisions: only what the group agreed on. A proposal nobody answered is not a decision.
        - Action items: one line each, "Name: task, deadline". Write a name only when the transcript
          says who does it, otherwise "No owner". Write a deadline only when it was said.
          A status update on ongoing work is not an action item.
        - Open questions: raised and not answered.
        - Give the `[mm:ss]` time for each decision and action item so the user can check it.
        - Write in the language the user asks for; otherwise in the language of the meeting.

        For questions across meetings ("what did we decide about X", "what do I owe Olena"),
        search first, then read the meetings the matches come from. Quote times.

        The user's meetings are private. Do not send transcripts anywhere the user did not ask for.

        ## Diduny settings

        Some settings can be changed by agents: `\(command) settings list` shows them with their
        current values and what each does. `\(command) settings set <key> <value>` changes one after
        checking the value. Lists take `uk,en` or a JSON array. Diduny applies the change within a
        second while it runs, or at the next launch. Only change settings when the user asks.
        Settings that are not in the list (hotkeys, devices, addresses, history retention) cannot
        be changed from here; tell the user to change them in Diduny.
        """ + "\n"
    }
}
