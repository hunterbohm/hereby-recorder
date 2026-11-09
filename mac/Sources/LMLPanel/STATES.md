# Menu bar panel: UX contract and STATES

## Scope

- Surface: one menu bar status item and one transient panel (NSPopover, 380 pt wide) attached to it, plus the call overlay (see Overlay) while a call is live. No other windows, no notifications, no alerts. Confirmations and errors render inside the panel.
- Design: direction 2, "Transcript", picked by the owner on Oct 24 (`prototypes/index.html`, `livePanel`). During a call the panel is the conversation itself, with marks, questions, and Hermes's texted warnings inline at their time.
- Why: Granola's floating windows fought AeroSpace tiling and one stuck mid-call (Sep 24). The owner typed notes in 1 of 25 meetings since Sep 1, so marking a moment outranks a notepad. Quiet by default.
- Sources: `PLAN.md` contracts C4, C5, C7 and the v2.1 section (`mac/Sources/LMLCore/UIContract.swift`).
- Evidence: offscreen renders of every state (light and dark), unit tests of the snapshot mapping and every action, and `lml-panel-snapshots --measure` for a full 400-line conversation. No live use yet.
- Open assumptions: `next.note` is a link (Full brief shows only when it parses as a URL). `recent[].note` is a readable location line for filed calls and the reason for skipped ones. `TranscriptLine.speaker` is `me`, `them`, `room`, or a person's name; `them` shows as `RecorderSnapshot.themName` when set (the runtime copies `next.with` from the meeting the capture matched), else "Them". The before list reads "You owe <with>", else "You owe them".

## JOBS

| Role | Trigger | Job | Outcome | Completion evidence | Failure cost |
|---|---|---|---|---|---|
| User | A call is about to start | Get into the call with context | Joined, knows what he owes | Join opened the link | Walks in cold or late |
| User | Something important is said | Mark the moment without leaving the call | Mark lands in `marks.jsonl` and the note | Button turns green, a marker appears in the conversation | Moment lost in a long transcript |
| User | Needs a fact mid-call | Ask about the call so far | Short answer in the conversation | Answer shown under the question | Guessing in front of a client |
| User | Hermes texted a warning | See it in context | Warning sits at the moment it was sent | Inline warning, once | Warning read out of context |
| User | Between calls, or during one | Ask about any past meeting | One to three lines | Answer above the field | Digging through notes |
| User | Recording a non-meeting | Stop it and delete it | Transcript gone on both machines | Panel leaves the call | Private audio text kept |
| User | Call ended | Know it filed, where, and what was decided | Opens the note, approves tasks | Filed, summary, marked moments | Silent filing failure |
| User | In-person meeting | Start a mic-only recording | Session recording | Conversation screen | Meeting unrecorded |
| User | Mic or system audio access is off | Fix it before the next call | Access back on | Ready screen returns | Call recorded one-sided or not at all |

## SCAN

- Purpose: the recorder's status, and the one thing to do now.
- Current status: the icon and the panel's header (Ready, Starts in, the live call with its timer, Paused, Filed, Needs access).
- Needs attention: the Needs access screen when nothing else is on; otherwise the orange banner under the header.
- Primary next action (at most one, filled button): Join (before), Mark (recording), Resume (paused), Open note (filed), Open System Settings (access). Idle has none; its field asks about any meeting.

## Screen precedence

Resolved by `PanelScreen.resolve(snapshot, now:, focus:, forgotten:, memory:, hasMini:)`, first match wins. With no mini (`hasMini` false) the panel never says "Connecting to the mini…", the delete confirmations name only this Mac, and an ended call reads "The transcript is saved on this Mac.":

1. Phase `recording` shows the conversation, unless the user opened the list or a past call from it (`focus` other than `.auto`, rules 2 and 3); a recording that starts, or a held call that comes back, sets focus back to `.auto`. Phase `paused` shows it dimmed under "Paused · nothing is being captured". The recorder ends the capture on pause, so the paused snapshot carries no session; the panel keeps the last recording snapshot (`SessionMemory.pausedFrom`) and freezes the timer at the moment it saw the pause. Without that memory (the app started while paused, or the call was just deleted) the screen reads "Recording paused" with no conversation.
2. A call the user opened (`focus = .call`) shows After with a Back link. Back returns to the list if it was opened from the list, else to the automatic screen.
3. `focus = .list` (the "All recent" link) shows Idle.
4. `feed.next` from 15 min before start until its end (or start + 15 min with no end) shows Before. A call that ended in the last 30 min rides along as "Last call".
5. The newest call ended under 30 min ago shows After. A session that ended on this Mac but is not in the feed yet shows After with "Waiting to file" until the feed reports it.
6. Mic or system audio off shows Needs access in place of Idle. It names the next meeting with a call link and says a text follows if access is still off 10 minutes before (the mini's health alert); "All recent" opens the list. Every other screen keeps its content and shows the problem as a banner, so Join, Open note, and the list stay reachable.
7. Otherwise Idle: the Home screen below, with the next call on top.

## Home (Idle and Before)

- Design: the owner picked a blend of the "command bar" and "one thing" mockups on Nov 8, in the macOS menu look (the popover's own glass, the system accent for the selected row and Join).
- Top: the next call large. "Next call · platform" and its time, a countdown (minutes under an hour, hours and minutes today, then Tomorrow or the weekday; Now once started), the title, up to two brief lines, and a blue Join with a ↩ keycap. Before a call (15 min ahead) it also lists what the user owes; the brief's own "You owe …" line is then left out. No call link: a line pointing at Record in person.
- Hermes (Google Meet calls only, see Hermes below): "Send Hermes" sits beside Join; once on, a card under Join shows where Hermes stands, Cancel, and the Chat replies switch.
- Under it, the ask field, focused when the panel opens. Typing and Return asks about any meeting; with the field empty, Return opens the selected row, or joins the next call when nothing is selected. ↑ and ↓ move the selection, Escape clears it, and hovering a row selects it.
- The list: "Later today" (`feed.today` minus the call on top; an event under way shows Now; Meet rows carry a small Hermes switch at the right edge), "Recent" (the four newest calls; a filed one names only what is left, like "3 tasks to approve"; Before shows only the last call with this person), then Record in person.
- Footer: Ready, Call detected, or Needs attention, and the overlay's shortcuts as keycaps.
- `feed.today` is the rest of today from every calendar account the mini reads (`calendars` in the recorder settings), at most 8; events that ended since the mini last wrote the feed are dropped on the Mac.

## Call screen header

- Title, timer, and the capture detail; then the overlay button (shows or hides the overlay, same as ⌥\), All recent (the list icon, opens the Home list), Stop, and a More menu with Pause, "Not a meeting, delete it", and the overlay style. Paused calls show Resume beside Stop.
- Under the conversation, the overlay's four questions as small buttons, so they work with the overlay hidden. Hidden while paused.

A call forgotten from this panel disappears at once, without waiting for the next feed. Closing the panel resets focus to automatic.

When the resolved screen changes to a different subject (another call, another phase, the After window closing), an open confirmation or a shown failure is dropped, so a confirm button can never act on a call that is no longer on screen. A failure that arrives after the recorder already moved on is not shown. An action that has not returned after 30 s shows its failure and re-enables the buttons; its late result is ignored.

## Conversation

- Items: the snapshot's lines (the session's last 400, oldest first), `markTimes`, the mini's `feed.live.warnings` for this sid, and the questions asked in the panel. Merged by time; at the same instant a line comes before a mark, a warning, then a question.
- Each warning shows once: the panel keeps every warning it has seen for the session, keyed by `n`, so a later feed that repeats or drops it changes nothing.
- Times are elapsed since the recording started (`12:04`); marked moments on a filed call use the start the feed implies (`ended_at - duration_s`), or the clock time when unknown.
- Scrolling: opens at the newest line, follows new lines while at the bottom, and stays put once the user scrolls up (`lml-panel-snapshots --measure` checks all three on real scroll geometry).

## Overlay

- Why: the panel closes on any click outside it, so it is gone the moment the user clicks back into the call. The owner asked for a Cluely-style overlay on Nov 4 and chose the side strip on Nov 7, with all three styles kept to switch between.
- Window: one borderless, non-activating `NSPanel` at the floating level on every Space and over full-screen apps. Its `sharingType` is `.none`, so ScreenCaptureKit captures (Zoom, Meet) leave it out; a prototype on macOS 26.6.2 confirmed that on Nov 4. Typing in it never activates the recorder, so the meeting app stays frontmost.
- Shown while the screen is the conversation (recording or paused with a session) and the user has not hidden it. Hiding lasts until the next session. ⌥\ (`overlay_toggle_key`) toggles it from any app.
- Styles (`OverlayStyle`, kept in user defaults, side strip by default): Side strip, a 320 pt column down the right edge with the whole transcript; Floating card, 340 pt at the top right with the last two lines; Top pill, under the menu bar with the newest line, opening into the card's contents. The header's style menu switches. Card and pill keep their top edge as they grow; all three can be dragged.
- Contents: header (dot or pause glyph, title, timer, Mark, style menu, Hide), the newest nudge from `feed.live.warnings`, the newest question and its answer, four buttons (What to say, Recap, Their questions, Check a number), and the ask field. ⌥↩ (`overlay_say_key`) is What to say. A shortcut that is off or taken by another app loses its hint.
- Tiling: `overlay_command` runs on each show, hide, or style change with `HEREBY_OVERLAY`, `HEREBY_OVERLAY_WIDTH` (328 for the strip, 0 otherwise) and `HEREBY_OVERLAY_DISPLAY`, one run at a time with a 5 s limit; a strip that lands on another screen frees the old one first. The recorder frees every screen at start and the overlay's screen at quit.
- Fast answers: every question in the overlay and the panel goes to `live-meeting-quick` first (30 s limit), which streams JSON lines from the mini's fast model and sends the Mac's last 40 lines, since the mini's copy can be 30 s behind. The answer shows as it arrives. If it fails before any text the question goes to `live-meeting-ask` (Hermes, 120 s); if it fails after some text, that text stays with " …".
- Screen: with `screen_context` on (the default), each fast question also carries a JPEG of the screen under the pointer, at most 1280 px on its long side, with the recorder's own windows left out (`ScreenGrab`). Without Screen Recording permission the question goes without it. Read screen always takes one, and asks for the permission when it is off; if it still has no picture it answers with the Screen Recording hint instead of asking Hermes, and any other failure shows Retry, since Hermes can't see the screen.

## Hermes

- Why: Hereby already records the calls he is on. Hermes's notetaker bot (a signed-in Chrome on the bot service) joins only the Meet calls he picks here, and, when he turns chat replies on, texts him the answer to a question he asks it in the meeting chat (the answer draws on his private notes, so it never goes into the meeting chat). Design approved Nov 9.
- Feed: `next` and every `today` item carry `key` (the calendar event key) and `hermes` = `{"state": "off|scheduled|joining|waiting_room|in_call|done|failed", "chat": bool, "error": str|null}`. A missing, malformed or unknown `hermes` reads as off and never fails the rest of the feed, so an older mini keeps working; without `key` (or without a mini) the controls stay hidden.
- Commands (over the panel's ssh runner, 20 s limit, one JSON object and exit 0, else a nonzero exit): `meeting-bot optin <key>`, `meeting-bot optout <key>`, `meeting-bot chat <key> on|off`. The key is single-quoted for the mini's shell when it holds anything but letters, digits and `._@:=+,/-`.
- Optimistic: the panel shows the change at once (`PanelStore.hermes`), keeps it until a feed built after the mini answered arrives (or 3 min pass), and on failure puts the old state back and shows the one failure line. Controls for that event wait while its command is out. Joining keeps the chat setting the mini reported; cancelling resets it.

## Delete: confirm, not undo

The prototype offered an 8-second Undo for Not a meeting and Forget. The panel keeps the in-panel confirmation instead, because the recorder cannot hold a delete safely for those seconds. Holding a live call means it keeps capturing and syncing to the mini (Pause is no hold: it closes the session, which files it). A delete held only in the panel is lost if the app quits, crashes, or the Mac sleeps in those seconds, so a call the user deleted would be filed. The forget protocol is one-way (tombstone, mini exit 4), so there is nothing to undo once it runs.

## Icon precedence

Resolved by `StatusIcon.resolve`, first match wins: mark flash (1.5 s) > mic or system audio off > recording > paused > mini unreachable > filed flash (10 s) > armed > idle. An unreachable mini never hides the recording icon, because capture still works and the transcript syncs later. The mini counts as unreachable when `feed.at` is over 10 min old (or there is no feed) and more than 2 min have passed since launch or the last wake from sleep.

## STATES

Buttons use the panel's own styles (filled primary, outlined secondary, underlined links); pressed dims them, disabled fades them. Every action is the user's; there are no other roles. While any action runs, every action button is disabled, which blocks double submits.

| Control or region | Trigger and immediate feedback | Disabled or hidden | Loading | Success | Empty | Error | Confirm, cancel, retry | Accessible name, announcement | Keyboard, focus |
|---|---|---|---|---|---|---|---|---|---|
| Status icon | Click toggles the panel | Never | n/a | Icon follows the precedence above | n/a | Problem icon (multicolor warning) | n/a | "Meeting recorder, idle", "…call detected, about to record", "…recording", "…paused", "…notes filed", "…moment marked", "…moment not marked", "Meeting recorder needs attention, microphone access is off" (and system audio, both, can't reach the mini). Same text as tooltip | Standard status item; Escape closes the panel; focus returns to the app that was frontmost |
| Health banner | Shown for the mini out of reach, and for mic or system audio on every screen but Needs access | Hidden when healthy | n/a | Disappears on the next healthy snapshot | n/a | It is the error surface | n/a | Headline and detail read as one group | "Open Privacy Settings" link is tabbable |
| Open Privacy Settings | Opens the Microphone or Screen and System Audio Recording pane | Hidden for the mini problem | n/a | System Settings opens | n/a | n/a | n/a | "Open Privacy Settings" | Tab, Space |
| Armed line | Phase `armed`: the Ready pill reads "Call detected" and the line shows under the header | Hidden otherwise | It is the progress state | Becomes the conversation | n/a | n/a | n/a | "Call detected. Recording starts in a few seconds." | Not focusable |
| Join | "Join Zoom" (or the platform, or "call") opens `meeting_url` | Without a link, Record in person takes its place | n/a | Link opens in the default app | n/a | n/a | n/a | "Join Zoom" | Return (default) |
| Full brief | Opens `next.note` | Hidden unless `note` parses as a URL | n/a | Note opens | n/a | n/a | n/a | "Full brief" | Tab, Space |
| Brief and You owe | Before: first 3 of `next.brief` as bullets, then `next.owed` as a checklist; idle shows the brief lines in the Up next card | Each block hidden when empty; "No brief for this meeting." when both are | n/a | n/a | See disabled | n/a | n/a | "Brief: …", "You owe: …" | Not focusable |
| Record in person | Calls `startInPerson()`; footer shows "Starting…" | Disabled while busy | Spinner and "Starting…" | Snapshot moves to the conversation | n/a | "Couldn't start recording. Try again." | Retry is pressing again | "Record in person" | Return when it is the Before default; Tab otherwise |
| Send Hermes | Button beside Join: calls `meeting-bot optin <key>`; the card appears at once | Only for a Google Meet link with a `key` from the mini, and Hermes off; disabled while an action or this event's command runs | The card shows the new state while the command runs | Card: "Hermes joins at 3:00 PM" (or "joins now"); follows the mini's state through "is joining", "is waiting to be let in", "is in the call" | Calls with another platform or no link show nothing | The old state returns and "Couldn't send Hermes. Try again." shows in red under the list | Pressing again retries | "Send Hermes", hint "Hermes joins this call as a notetaker" | Tab, Space; not the default button (Join keeps Return) |
| Hermes card | Hero, live screen above the conversation, and under Back to the call: the state line, Cancel (Remove once in the call), Chat replies switch with a one-line hint | Hidden while Hermes is off; Cancel and the switch disabled while a command runs; no switch when failed | n/a | "Hermes joins at 3:00 PM", "Hermes is joining", "Hermes is waiting to be let in", "Hermes is in the call"; done reads "Hermes took notes in this call" | See hidden | Failed reads "Hermes couldn't join: <reason>" in red with Cancel; a refused Cancel or switch change puts the old state back with "Couldn't cancel Hermes." or "Couldn't change chat replies." | Cancel runs `meeting-bot optout <key>` (a bot already in the call leaves); the switch runs `meeting-bot chat <key> on|off`, off by default, hint "Off: Hermes listens and takes notes only." / "On: ask Hermes in the meeting chat and it texts you the answer." | "Cancel Hermes" or "Remove Hermes"; "Chat replies" switch | Tab, Space |
| Hermes row switch | Small switch with a one-word caption (Hermes, Joining, Waiting, In call, Failed) at the right edge of a Later today row; on runs optin, off runs optout | Meet rows with a `key` only; hidden once Hermes took notes; disabled while a command runs | Switch shows the new position at once | Stays on | Hidden for other platforms | Switch returns to its old position and the failure line shows | Flip again | "Hermes joins <title>" | Not in the keyboard order: arrow keys and Return in the ask field work as before; hovering still selects the row |
| Recent row and Last call row | Title, filing tag ("Filed · 3 tasks to approve", plain "Filed" once the review is answered, "Skipped · Not a meeting"), then when and the snippet; opens that call's After with a Back link | Disabled while busy | Filing tag shows a spinner | After (pinned) | Idle shows "No recorded meetings yet." | Red "Filing failed" tag | n/a | "<title>, <tag>, <when · snippet>", hint "Shows details" | Tab, Space |
| Back | Returns to the list or the automatic screen, whichever opened the call | Shown only on a pinned After | n/a | Previous screen | n/a | n/a | n/a | "Back" | Escape, unless a confirmation is open |
| All recent | Shows the recent list from the automatic After | Shown only on an unpinned After | n/a | Idle list | n/a | n/a | Cancels an open confirmation | "All recent meetings" | Tab, Space |
| All recent (call) | List icon in the call header; shows the Home list with the call on top. The overlay stays | Disabled while busy | n/a | Home list | n/a | n/a | n/a | "All recent meetings" | Tab, Space |
| Back to the call | The call's title and timer on top of the Home list opened from a call; returns to the conversation. Record in person is hidden there, and the footer reads Recording or Paused | Shown only while a call is live or paused | n/a | Conversation | n/a | n/a | n/a | "Back to the call, <title>" | Escape (when no row is selected and no action runs), or Return with the field empty and no row selected |
| Up next (idle) | Card: title, time, brief lines, platform | "No upcoming meetings" when `next` is null | "Connecting to the mini…" before the first feed | n/a | See disabled | n/a | n/a | One element | Not focusable |
| Header (call) | Dot or pause glyph, title, timer; then platform and marks ("Zoom · 1 marked") | Timer hidden without a start; frozen and dimmed while paused | n/a | n/a | "In person · mic only", "Call" without a matched link | n/a | n/a | "Recording, <title>", "Recording for 12 min" | Not focusable |
| Conversation | Scrolls; see Conversation above | Always shown during a call | "Listening…" before the first line; "Nothing is being recorded until you resume." while paused with nothing kept | n/a | See loading | n/a | n/a | "Conversation"; rows read in order | Scrollable; text selectable |
| Mark (button) | Calls `markMoment(note: nil)`; the button turns green "Marked" for 1.5 s and a marker joins the conversation from the next snapshot | Disabled while paused or busy | n/a | Header count updates | n/a | "Moment not marked" (or "Paused, so nothing was marked") in red above the bar | Retry is pressing again | "Mark moment", hint "Shortcut Option M, works from any app"; announces "Moment marked" or "Moment not marked" | Tab, Space; ⌥M hint hidden if the hotkey could not be registered |
| Option-M hotkey | Same as the button, from any app, panel open or closed | Ignored by the recorder outside a recording; the icon shows the slashed bookmark for 1.5 s | n/a | Bookmark icon 1.5 s | n/a | Slashed bookmark icon | n/a | Icon name changes to "…moment marked" | Carbon `RegisterEventHotKey`; no Accessibility permission. If another app owns ⌥M, the hint disappears |
| Ask about this call | Always-open field in the bottom bar; Return or Ask sends the trimmed text, which joins the conversation as "You asked: …" at that time | Ask disabled when blank or while a question is out; whole bar disabled with no session | "Thinking…" under the question | The answer under the question, selectable | Blank questions are never sent | "Couldn't get an answer." with Try again; an empty reply counts as no answer | Try again resends once and moves the question to now; a new session drops questions and late answers | "Ask about this call"; announces "Answer ready" or "No answer" | Tab; Return sends |
| Ask about any meeting (idle) | Field in the idle footer; runs `askAnyMeeting` (`ssh <ssh_host> live-meeting-ask --any`, 120 s limit) | Ask disabled when blank or while a question is out | "Thinking…" under the question | The latest question and answer above the field | Blank questions are never sent | "Couldn't get an answer." with Try again (a missing `--any` on the mini lands here) | Closing the panel clears an answered or failed question; one still out stays | "Ask about any meeting" | Tab; Return sends |
| Pause | Calls `pause()`; footer "Pausing…" | Disabled while busy | Spinner and "Pausing…"; after 30 s with no reply it shows the failure | Snapshot moves to Paused | n/a | "Couldn't pause. Try again." | Retry is pressing again | "Pause"; failure is announced | Tab, Space |
| Resume | Calls `resume()` | Disabled while busy | "Resuming…" | Recording resumes when the call is detected again, as a new session (the paused part already filed) | n/a | "Couldn't resume. Try again." | Retry | "Resume" | Return (default) |
| Stop | Calls `stop()`; no confirmation, the call still files; while paused it ends the pause, so the recorder does not resume on this call | Disabled while busy | "Stopping…" | Moves to After | n/a | "Couldn't stop. Try again." | Retry | "Stop" | Tab, Space |
| Not a meeting | Shows the confirmation card above the bar; nothing is called yet | Hidden with no session; disabled while busy | "Deleting the transcript…" | Recorder forgets the session; panel follows the snapshot | n/a | "Couldn't delete the transcript. Try again." | Card: "Not a meeting?" / "Recording stops and this call's transcript is deleted from this Mac and the mini." Cancel or Delete transcript; closing the panel cancels. No undo (see above) | "Not a meeting"; the card reads as "Not a meeting?" | Escape = Cancel; no default button on purpose |
| Open note | Opens `note_url` | Hidden without `note_url` | n/a | Note opens | n/a | n/a | n/a | "Open note" | Return (default) |
| Forget | Shows the confirmation card | Disabled while busy | "Deleting the transcript…" | The call disappears from the panel at once; a pinned view goes Back | n/a | "Couldn't delete the transcript. Try again." | Card: "Forget this call?" / "Its transcript is deleted from this Mac and the mini." Cancel or Forget. No undo | "Forget this call" | Escape = Cancel |
| After body | From `recent[].state` | n/a | Waiting: "The transcript is still syncing to the mini."; while the recorder holds a call that may come back (`heldUntil`): "If this call comes back, recording continues here." / "Otherwise it files at 7:13 PM." Filing: "Writing notes now. Usually under 5 minutes" | Filed: "Notes <note>", review line and count, Summary bullets (up to 3), Marked moments (time and line, "None marked" when empty) | Header facts hidden when duration and end are unknown | Skipped: "Not filed: <reason>." Failed: "Notes weren't written. The mini tries again within the hour." | n/a | Header, then rows | Not focusable |
| Overlay | Appears when a call starts, in the saved style | Hidden outside a call, after Hide, or with ⌥\ | n/a | n/a | "Listening…" before the first line | n/a | Hide lasts the session; ⌥\ brings it back | "Meeting overlay"; header reads "Recording, <title>" | Clicking the field gives it focus without activating the app |
| Overlay buttons | Each sends its kind to `live-meeting-quick`; the question shows as "You asked: …" | Disabled while paused or while a question is out | "Thinking…", then the answer with a cursor as it arrives | The answer, selectable | n/a | As for Ask about this call | As for Ask about this call | Button label | ⌥↩ is What to say; Read screen sends the screen even with `screen_context` off |
| Overlay style menu | Switches between Side strip, Floating card, Top pill | Never | n/a | The overlay moves to the style's home spot | n/a | n/a | n/a | "Overlay style" | Tab, Space |
| Texted warning | From `feed.live.warnings` for this sid, inline at its time: "Texted to your phone · 1 of 3" and the text | Hidden for other sessions | n/a | n/a | n/a | n/a | n/a | One element | Not focusable |
| Needs access | Pill, health line, what is off and why it matters, the next call and the text that would follow; "All recent" opens the list | Only in place of Idle | n/a | Ready returns on the next healthy snapshot | No next-call line without a linked meeting | n/a | n/a | One element | "Open System Settings" is the default button |
| Action footer | Shows the running or failed action | Hidden when idle | Spinner and running text | Disappears | n/a | Red line with the failure text; cleared by the next action, a phase change, or closing the panel | Retry is the same button | Failure text announced | Not focusable |

## PROOF

- Fidelity: production SwiftUI views rendered by `lml-panel-snapshots <dir>` from fake snapshots, light and dark, hosted in a borderless window that is never ordered front so scroll views get real geometry.
- Performance: `lml-panel-snapshots --measure` times a one-second tick, a new line arriving, and the recorder's publish at 4 and 400 lines, then checks the scroll behavior.
- Tests: `scripts/test.sh` covers the snapshot to screen and icon mapping, the conversation merge, warnings shown once, the paused memory, every action on a fake recorder, confirmation, stale confirmations, busy, timeout, failure and retry, both ask paths, the filed flash, wake grace, hotkey registration and dispatch, and `askAnyMeeting` over ssh including a missing command.
- Evidence level: internal concept proof, not used on a real call yet. Real use is the gate.
- Open risks: focus hand-back after the panel closes and the Privacy Settings anchors are untested on a live screen.
