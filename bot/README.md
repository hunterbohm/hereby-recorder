# Meeting bot

The Worker `hermes-meet-bot` (on its workers.dev address) starts one container per call, each a
Chrome that signs in as the notetaker and joins a Google Meet or Zoom call (`src/index.js`, `container/`). The mini's
Hermes calls it with `MEETING_BOT_API_TOKEN`.

The notetaker's Google account and the Deepgram key are Worker secrets. They reach a bot only in the request that
starts it and live only in the driver's memory: no environment variable in the container holds them, so Chrome,
ffmpeg and the start script never inherit them, and the password is dropped once the bot has signed in. The bot never
gets `API_TOKEN`; it joins its call's board room with a key made for that room alone. Chrome runs with its own sandbox,
which Cloudflare's containers allow; if a machine refuses it, Chrome runs without, and `/status` says so (`sandbox`,
`sandbox_error`).

## The notice

The moment a bot is let into a call it posts a notice in the meeting chat, whatever the chat setting, then reads the chat
back (`container/notice.mjs`). It records, listens for spoken commands and keeps the chat only once the chat shows the
notice, and it never keeps a message typed before the notice. The mini dates the audio from when the notice went out. A try that fails is tried again 3 s and 10 s later, then every minute; after the third, `/status` shows
`notice.state` as `failed` and the mini texts the owner once. `POST /bots` takes the words as `notice` (at most 500
characters, from `notetaker_notice` in the mini's `recorder.toml`); without it the bot posts a neutral one that names
nobody: "Hi, I'm an AI notetaker. I'm recording and transcribing this call for the person who invited me. If you'd
rather not be recorded, ask them to remove me." In Meet the bot then pins it, since Meet shows someone who joins later
only the chat that is pinned (`/status` shows `notice.pinned`). A pin that misses is tried twice more, 20 s apart; a
host who lets only hosts pin leaves it unpinned. Zoom has no pin, so there a late joiner sees it only if their call
shows chat from before they joined.

## The recording

Once the notice is up the bot records the call as Ogg Opus (24 kbit/s, about 11 MB an hour). While the call runs, the
mini copies what is new every 10 to 20 seconds (`GET /audio?from=<bytes it has>`; the answer's `x-audio-from` header
says where it starts), and the rest when the call ends. A bot lost in the middle of a call, its container stopped or
restarted, still leaves everything up to the last copy, which the mini files like a call that stopped early. A recorder
that stops while the bot stays in the call is not started again (it would begin a new file): `/status` shows
`recording` as `stopped`, with `recording_error`, and the mini texts the owner once.

## Spoken commands

With `DEEPGRAM_API_KEY` set as a Worker secret (`npx wrangler secret put DEEPGRAM_API_KEY`, from Infisical), a bot the mini
starts with `"voice": true` streams the call audio to Deepgram's live speech-to-text (Nova-3, with "Hermes" as a key
term) and reports every sentence spoken to Hermes in `/status` as `heard`; the mini treats each like a meeting
chat message (`container/voice.mjs`, `mini/meeting_bot.py`). Board commands also go to the call's board room at once
(see Live whiteboard). A command ends at a short silence: Deepgram's own (300 ms), or 0.6 s of quiet the bot hears in the
audio itself, when it asks Deepgram to finish the words it has (Deepgram's own can come 5 s late). A command that
stops mid-thought ("Hey Hermes, add") waits for the rest. It streams only while the bot is in a call with someone
else, stops when the call ends, and stops for good after 4 hours of audio in one call. A stream already open stays
open for up to a minute while the call's controls are hidden: Meet's tip "Others may see your video differently"
covers them as the first board share starts, and a bot that stopped there missed two commands said in the next 20 s
(a test call, 2026-11-21). `/status` shows `voice` with the
seconds streamed, which is what Deepgram bills ($0.0048 a minute plus $0.0013 for the key term, pay as you go, on
2026-11-20). A refused or dropped stream is retried four times, then given up for the call; the recording and typed
commands never depend on it. An open stream sent sound that answers nothing for 15 seconds counts as dropped (Deepgram
answers about every second), and the count of drops starts over only once a stream has worked for a minute. While
spoken commands cannot be heard (the stream is down or being tried again, has given up, reached its limit, or has no
key), the board's status bar says "Not listening, type in chat"; the words of a command half heard as the stream
dropped go with it, never finished into a command nobody said. The mini texts the owner once when spoken commands stop
for the call, given up or at the limit. The test copy has no key, so it never streams.

A call cuts off the first tenth of a second or so of someone's speech after a silence, and with it the start of the
name: Deepgram writes "Hermes, start a whiteboard" with that cut as "Let me start a whiteboard.", "Please start a
whiteboard." or "Start a whiteboard." (measured 2026-11-21, in `voice.mjs`). So while no board is up, a phrase that is
only a request to start a board ("let me start a whiteboard", "start a meeting board for the launch", or a clipped
"Hey Hermes, start a whiteboard" heard as "Hermes, start a whiteboard") starts one without "Hey Hermes", once in 30 seconds; a board meeting, a whiteboard session or a board for tomorrow does not.

Every other command needs "Hey Hermes", "Hi Hermes" or "Okay Hermes" (Deepgram also writes "K. Hermes"), at the start of
a sentence after any filler ("So, hey Hermes, …") or mid-sentence after a comma ("…that's late, hey Hermes, add a
risk: …"). The bare name is talk about Hermes, as in a call about it with others' Hermes in it: "Hermes is good at
memory", "So Hermes, the one Lee built, …", "Can Hermes write to Obsidian?", "Lee, Hermes, and the notes" do nothing.
After "okay" or "hi" the name must stand apart ("Okay Hermes, …") or a board command follow, since "Okay, Hermes makes
a board of every call" is talk too. "Hey Hermes" and "Okay Hermes" are key terms (Deepgram bills key terms by the minute,
not by the term), and the greeting keeps the name whole when the start is cut, so the bot asks people to say "Hey
Hermes". A phrase that sounds like a board command with no name heard ("please put the launch dates on a timeline")
or with the bare name ("Hermes, add a goal: …"), and each unnamed board start taken, is listed in `/status` as `near_misses` (the last 50, never in the logs); the mini
keeps them in the call's record, which goes when the call is forgotten, so the name rules can be tuned from real calls.

In Meet the bot's camera is a tile (`container/tile.mjs`): a canvas in the Meet page, in the board's colors, that says
"Listening" once the notice is up, then "Say" and "Hey Hermes, start a whiteboard" in Hermes's violet, or in their place
the words it hears as they come (drawn only, never kept); after a near miss it says to start with "Hey Hermes". With a
board on screen, where Meet shows the tile small beside it, it says only "Listening" and "Say Hey Hermes", bigger. While
spoken commands cannot be heard it says "Not listening" and to type in the chat. Everything is big, bold and flat, and
sits in the middle of the square, which survives Meet cutting the picture to a wide or a tall tile. Meet sends the
camera of a one-CPU machine like the bot's at a third of its size (320 by 320 for the tile), so once in the call the bot
sets Meet's Send resolution to the highest it offers (`tile_resolution` in `/status`), and the tile reaches the others
at 960 by 960 (measured 2026-11-21). Zoom keeps the camera off.

## Live whiteboard

Each call has a board room, a Durable Object named by the call's board token (`src/room.js`). It holds the call's
boards and sends every change the moment it is made to everyone looking: the bot's own board tab, which is the tab it
shares in the call; anyone who opens the board link; and Hermes on the mini, which reads
the room's event stream (`/rooms/<token>/events`) and sends its edits back (`/rooms/<token>/send`), with the Worker's
`API_TOKEN`. The bot reaches the room over a WebSocket at `/b/<token>/bot/<key>`, with a key made from `API_TOKEN` and
the token, and sends what it hears as it hears it: the words of a spoken command for the status bar, then the
finished command.

Each command is done once. The bot keeps a command until the room says it has it (`got`, sent once it is stored)
and sends it again on every new line until then; the room takes a command it already has only once, by its id, which
is the command's own for the whole call (a spoken one carries the bot process's start time, a typed one its chat
message's id). The mini moves
its place in the room's stream past a command only once it has handled it, so a whiteboard process that stops part
way is sent the command again when it starts over; the room makes no second board for the same command, and it marks
a command finished once Hermes's last caption for it is in (an undo, as it happens), so a finished one is never done
twice. A board command
that comes more than 90 seconds late (the process was away) is not carried out, and the board says "Missed while
Hermes was away. Say it again."

A room exists only once `POST /bots` opens it for a call, before the bot starts; until then it answers nothing and
stores nothing. The token alone opens nothing: a board link is `/b/#<key>`, where the key (after the #, so the browser
never sends it with the page) holds the token, what the link may do (edit, or only watch for the bot's shared tab), a
version and the time it stops working (12 hours after the call's bot started), signed with `API_TOKEN` (`src/links.js`).
The page opens its socket at `/b/<key>/ws`; a key this Worker did not sign, or one that has expired, is refused with one
HMAC in the Worker, before any room is reached, so nobody can make a room by inventing a link. Keys are hex, which
Cloudflare's logs hide in any path they record. Edits are small and applied one at a time (`src/ops.js`), and the page
animates each one in. When the call ends the mini keeps the room's boards as the call left them, with the room's change
count as their revision (`final.json` next to the pictures), then closes the room; a room it cannot read yet stays open
and each tick tries again. A room nobody closed is emptied after 12 hours.

The owner can turn the board link off (`meeting-bot board-link off`), make a new one (`new`), or get a watch-only one
(`view`), through `POST /rooms/<token>/link`. Off and new move the room's link version on, so every older link and its
short link stop at once, and everyone on one is cut off; the shared screen and the bot keep their own sockets. A bot
that stops for any reason, removed or not, turns its call's link off too (`MeetBot.onStop`), so a call whose mini went
quiet does not leave its link working for the rest of the 12 hours.

The page (`public/board/`) draws each board as a few visual blocks side by side and in rows (`BLOCKS.md` says how
they are made and how to add one): lists of one kind, flows, timelines, charts, comparison tables, 2x2s, mind maps and
key numbers. A board starts empty, and what is said first decides its first block; each later change adds to the block
that holds that topic or puts a new block beside it, so the picture grows and is never redrawn. Blocks are DOM and SVG
drawn by `blocks.mjs`, placed by `arrange.mjs` (rows of at most three, each row spanning the board, the last rows kept
when they still fit) at sizes from `sizes.mjs`, and `view.mjs` shrinks every block together (down to 0.72) as the board
fills, so nothing is cut off. Only what changed moves: a new block comes in while the others glide aside, a new bar grows,
a new arrow draws itself. Type is large and lines are thick, so the board stays readable when Meet shrinks and
compresses the share. Colors: goals and pros green, risks and cons red, charts in a palette checked for color
blindness, and violet only for what was just changed. The boards run along the top as tabs, an empty block says what to say to
fill it, and a status bar docked at the bottom says what Hermes hears while someone speaks, then what changed in words
("Added “Hire a designer” to Action items, owner Lee") with "Not right? Say Hey Hermes, undo". The latest change is ringed
"Hermes, just now" (or the person's name) for a few seconds, and Hermes's cursor glides to it. The editable file kept in
the notes is made with Excalidraw only at export (`scene.mjs`, `canvas.mjs`); React and Excalidraw load only then. The
font is Atkinson Hyperlegible Next (SIL Open Font License); fonts, QR code (qrcode-generator, MIT) and Excalidraw come
from jsDelivr, pinned, the scripts with SRI. The picture in the notes is taken on a page of its own (`?print=1`), 1280
wide at twice the pixels, every block as tall as it needs.

Once Hermes has posted the board link in the meeting chat (only with chat replies on), the shared screen shows a QR
code and a short link, `/j/<code>`: 10 letters and digits that cannot be mistaken for each other, the last 4 signed
with `API_TOKEN` (`src/links.js`), so a made-up code is refused by one HMAC before any Durable Object is reached. Each
code is its own Durable Object (`src/short.js`) holding its room's token, forgotten after a day and a half. `/j/<code>`
asks the room and signs an editor's link for its current link version on the way, so it stops working with the call,
or when the link is turned off or made again.

Anyone with the board link can change the board. The link shows the same blocks, stacked one a row on a phone: "+ Add"
in every block and "+ Block" for a new one, a tap on an item, a block's name or the title opens a form with that item's
fields (words, owner, due date, risk level, a number, a date and status, a score per option, a quadrant, the block it is
in), the name is asked once, and Undo and the list of changes sit at the top; a watch-only link shows the same blocks
with none of that. Each change is one edit that the room checks like Hermes's (same limits). People are counted by their address (IPv4, or an
IPv6 /64), not by their socket, so a reconnect or a second tab gets no fresh allowance: per address at most 8 sockets,
12 new ones a minute, 20 edits at once then 5 a second, 25 pointer moves at once then 25 a second, and 80 messages at
once then 40 a second; per room at most 50 people, 60 new sockets at once then 1 a second, and 60 edits at once then 10
a second from everyone together. Only what an address's own limits let through counts against the room's, so one address
cannot use up the room's allowance for everyone. A refused message still counts against its address, and an address that
keeps sending far past its allowance has its sockets closed and is kept out for a minute.
Their pointer, on the item it is over, shows on the other pages and on the shared screen with the name they typed,
and their change is marked with it. Hermes's next command starts from the board as they left it, and the mini keeps the board's
picture again 3 s after their changes stop. As the call ends, the bot draws every board changed since it last drew
it before its browser closes, and the mini's filer keeps those (`GET /bots/<id>/board/final`), so a change made in the
call's last seconds is in the notes too. Filing then checks each kept picture against the room's final boards: a
board whose picture shows an older version goes to the notes with its final text, a board with no picture is not in
the notes but kept in `final.json`, and the owner is told either once, as when the final boards could not be read.
With chat replies on, the mini posts the link in the meeting chat once,
with the first board; with them off, the link goes only to the owner, when asked. Once the owner turns the link off or
makes a new one, the chat gets no link at all.

A board is `{v: 2, title, blocks: [{id, type, title, ...settings, items: [...]}]}` (`public/board/model.mjs`); a board
from before blocks (sections of notes) is read as lists, and the edits from before (section, note, arrow) still work.
A list has a kind: goals, risks (with a level), action items (with an owner and a due date), decisions, pros, cons, or
plain notes, which the model is taught and a list's title implies when none is given. "Hey Hermes, start a whiteboard"
puts up an empty board at once, with no model; boards by name ("a retro", "an agenda", "a decision log", "action
items", "pros and cons", "a timeline", "a mind map", "a process flow") go up shaped at once, also with no model. With a
board up, anything said straight to Hermes that is not a question or small talk goes to the model as a change ("Hey Hermes,
our goal is …", "the beta is done"); when it finds none, the board says to say it again. Each command's edits come from
Claude Haiku with thinking off (a rebuild, such as "group these by owner", from Sonnet), streamed, each applied the
moment it is complete. Every edit says what it did in words ('Added "Hire a designer" to Action items, owner Lee'), which the
board's status line and its change log show. "Hey Hermes, undo" (or "no, not that") and the link's Undo button take back
the last command, all its edits at once: the room keeps what each command changed, ten commands back. "Hey Hermes, recap"
puts up a recap board of every board's action items, decisions and open risks, and the bot asks for one as it leaves
the call, so it is in the notes; with people still there it stays on screen 4 s, and with chat replies on Hermes says
it in the chat.

A call holds up to nine boards, each a tab along the top of the screen, named by its title, or by its first block's
name until it has one. The board on screen is the white tab joined to the page; a new board opens as a new tab and
slides in. Hermes moves between them by rule, with no model, so the screen changes in well under half a second
(`navigate()` in the mini's `meeting_board.py`): a board by its name, said loosely or misheard ("show the hiring
board", "go back to pricing", "the launch one"; when only close, the status bar says which it picked), by number,
"next" and "previous", "show all boards" (every board small at once, in a grid), two side by side ("put the launch
board and the hiring board side by side", "split view with pricing") and back to one ("just the launch board"), and a
new name ("call this board Pricing"). Three side by side were tried and left out: at a third of the screen a board's
main block, a comparison or a chart, no longer fits. The room keeps how the boards are on screen (`view`, with
`current` the board the next change goes to) and each move as an undo step, so "Hermes, undo" puts the screen back
and the status bar says what is back on it ("Undone: back to Q1 launch and Pricing side by side").
With two side by side, a change goes to the board it names ("add a risk to the hiring board") or else to the one
changed last, marked "Adding here", and the status bar says which; a change to a board not on screen puts it on screen
first. Each half shows the blocks that fit it whole and folds the rest into a row of their names at its foot, keeping
the ones changed lately. Someone on the board link follows the screen, or taps a tab to see that board alone until
they tap "Follow the screen" or Hermes changes the view. Side by side and all at once are ways to look, not boards:
each board is still saved to the notes on its own.

## Zoom

The bot signs in to Zoom with the notetaker's Google account (Zoom turns away a scripted browser that is not signed in)
and joins with Zoom's web client. It puts its notice into Zoom's chat box all at once: typed key by key, the notice took
20 s and more on the bot's one CPU, and the bot listens only once the notice is up. Its board tab loads only after the
notice, for the same reason. Every 3 s it closes Zoom's own tips and notices over the call, and nothing else: My Notes,
chatting as a guest, the graphics acceleration banner, and the notice that someone streams the call
(`container/zoom-ui.mjs`; `/status` counts each it closed as `dismissed`).

A host who lets only the host share gets Zoom's "Disabled Share" dialog when the bot presses Share. The bot closes it at
once and reports `the host lets only the host share`, and the mini texts the owner what the host changes. While a board
is up and nobody else shares, the bot then tries again every 30 s for 10 minutes. A share Zoom has not shown as started
when the bot stops waiting (30 s) is counted when it shows, and fails only if it is still not up 90 s later: in a real
call (2026-11-22) one reported failed came up a minute or so later.

## Deploy

From this folder, with a key that may edit this Worker as `CLOUDFLARE_API_TOKEN`:

```sh
npx wrangler deploy --tag "$(git rev-parse HEAD)"
```

The tag stamps the commit on the Worker version, which is how the vulnerability watcher on the mini reads which commit
runs. The watcher's own deploy job (`vulnwatch.py deploy-run`) also labels each image with its commit and build time, so
every deploy rolls out a new image it can name; a plain `wrangler deploy` that changes only the Worker reuses the cached
image, and the watcher then cannot tell which commit the container runs. Prefer the watcher's job for a deploy by hand.
A deploy leaves bots started in the last 4 hours alone (`rollout_active_grace_period`), so it never cuts a call, but its
rollout then waits for them; deploy while no bot runs.

## Test copy

`npx wrangler deploy --env test` deploys `hermes-meet-bot-test` (on its workers.dev address),
made on 2026-11-13 for the watcher's check. It has its own container app, at most one bot, and its own `API_TOKEN`
(Infisical `/agents` `MEETING_BOT_TEST_API_TOKEN`), and no Google secrets, so it cannot sign in as the notetaker.
The watcher's check starts a bot there on a Zoom link with an id no meeting can have (`000000000`), follows its status
until Zoom's own page refuses it (Chrome runs and drives the page, and the bot never starts a sign-in), and ends it.

## Security fixes

The vulnerability watcher on the mini deploys its own merged security fixes: the test copy first, then the live bot,
each checked, and the version from before put back when a check fails. It deploys the live bot only while no bot runs,
and never while someone's change to files that ship waits on `main` undeployed.
