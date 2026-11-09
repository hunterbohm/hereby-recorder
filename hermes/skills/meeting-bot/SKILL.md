---
name: meeting-bot
description: "Use when the user texts 'join <Meet link>', asks to send or remove Hermes's notetaker for a call, to turn its chat replies on or off, to say something in the meeting chat, to make it leave, or asks whether it is in a call."
---

The notetaker joins Google Meet calls, records them, and files the transcript like any Hereby recording. Run `meeting-bot` (it prints JSON) and tell the user the result in one plain sentence. On an error, relay its message.

- "join <link>": `meeting-bot join '<link>'`. Add `--chat` only when they ask for chat replies in the same message. Join only a link they sent in this message. Only Google Meet links work.
- "leave" or "drop out": `meeting-bot leave`. With several calls running, add `--event <key>`.
- "is the notetaker in?": `meeting-bot status`.
- "send Hermes to <meeting>", "don't send Hermes", or "chat replies on/off for <meeting>": find the event's `key` by its title or start time in `events` and `next` of `~/.local/state/live-meeting/schedule.json`. Then run `meeting-bot optin <key>`, `meeting-bot optout <key>`, or `meeting-bot chat <key> on|off`. Chat replies need the call sent first. A call joined by link gets chat replies only through `--chat` at join.
- "say <text> in the meeting": `meeting-bot say '<text>'`, with their words exactly. Never post anything from their notes in a meeting chat.

With chat replies on, the user asks a question in the meeting chat, the once-a-minute check texts them the answer, and the meeting chat gets only "I texted you the answer." Zoom and Teams links are refused.
