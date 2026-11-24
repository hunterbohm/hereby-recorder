// Spoken commands. While the bot is in a call with someone else, the call's audio streams to Deepgram, and a phrase
// that starts with "Hermes" becomes a command: its words go to the call's board room as they are heard (the live
// caption), the finished command goes there the moment the speaker pauses, and the mini also reads it from /status.
// Deepgram bills each second of audio sent, so the stream runs only while it can hear someone, and stops for good at
// the end of the call or after MAX_SECONDS.
import { spawn } from 'node:child_process';

// Nova-3 with "Hermes" as a key term, so the name comes back spelled right ($0.0048 + $0.0013 a minute, 2026-11-20).
// Key term prompting is billed by the minute, whatever the number of terms ("Keyterm Prompting $0.0013/ min", Deepgram's
// pricing page, 2026-11-21), so the greetings people put before the name are key terms too: on 54 clips of commands
// whose first 80 to 220 ms were cut off, as a call cuts the start of someone's speech, the name came back in 31 with
// these four and in 28 with "Hermes" alone (2026-11-21).
// mip_opt_out=true keeps the call's audio out of Deepgram's model training, and Deepgram does not store it after the
// answer (its data page, 2026-11-21); pay-as-you-go prices do not change with it (its changelog, 2026-03-05).
// Interim results give the live caption while someone is still talking. A phrase ends at `speech_final`, after
// `endpointing` ms of silence, or at UtteranceEnd (a gap of utterance_end_ms between words) when noise keeps
// `speech_final` from coming, as Deepgram advises. Both can come seconds late ("Hermes, add a goal: ten paying pilots by
// March" waited 5 s on clean audio, 2026-11-20), so the bot also hears the pause itself (Pause, below) and then asks
// Deepgram to finish the words it has (a Finalize message, answered in about 0.1 s with `from_finalize`).
export const URL = 'wss://api.deepgram.com/v1/listen?model=nova-3&language=en&encoding=linear16&sample_rate=16000'
  + '&channels=1&smart_format=true&interim_results=true&endpointing=300&utterance_end_ms=1000&keyterm=Hermes'
  + '&keyterm=Hey%20Hermes&keyterm=Okay%20Hermes&keyterm=whiteboard&mip_opt_out=true';
const BYTES_PER_SECOND = 16000 * 2;
export const MAX_SECONDS = Number(process.env.VOICE_MAX_SECONDS || 4 * 3600);
// Failed connections in a row before the bot stops trying for the rest of the call; the waits between them. The count
// starts over only once a stream has answered for HEALTHY_MS, so one that opens, answers and drops again and again still
// reaches the end instead of retrying all call.
const RETRIES = [5, 15, 30, 60].map((s) => s * 1000);
const HEALTHY_MS = 60000;
// A stream that has not opened by then is counted as failed.
const CONNECT_MS = 15000;
// An open stream sent sound for this long with no answer has stopped working, and is counted as failed. With interim
// results Deepgram answers about every second ("Interim Results are sent every 1 second", its end-of-speech docs,
// 2026-11-21).
const ANSWER_MS = 15000;
// Meet's tip "Others may see your video differently" covers the call's controls as the bot's first board share starts,
// which reads as being out of the call. A stream that closed there missed two commands said in the next 20 s (a test
// call on the bot's one CPU, 2026-11-21; 2.5 s on a faster machine), so an open stream stays open this long while the
// call cannot be seen. The driver takes a call whose controls stay gone for 2 minutes for lost, and then stops the voice.
export const AWAY_MS = 60000;
const COMMAND_CHARS = 500;
// "Hermes." alone, then the command as the next phrase within this long.
const FOLLOW_MS = 10000;
// Deepgram ends a sentence at a short pause, so "Hermes, add an action item: Lee will hire a designer." and "And it is due
// Friday, December 5." arrive as two phrases, and the second has no name. A phrase that starts within CONTINUE_MS of a
// command, that is short and gives a due date, an owner or a level, carries that command on (the call's audio is one
// mixed stream, so it can be anyone's voice; a wrong guess is one undo away). At most CONTINUE_MAX in a row.
const CONTINUE_MS = 5000;
const CONTINUE_WORDS = 20;
const CONTINUE_MAX = 3;
// What counts as a date after "by", "before" or "until": a day, "tomorrow", "next week", "the end of ...", a clock time, a
// day of the month, or a real month name ("marketing" is not March).
const MONTHS = '(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sept?(?:ember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\\b';
const WHEN = '(?:mon|tues?|wed(?:nes)?|thu(?:rs?)?|fri|sat(?:ur)?|sun)(?:day)?\\b|tomorrow|today|tonight|eod|eow'
  + '|next\\s+(?:week|month|quarter|year|day)\\b|this\\s+(?:week|month|quarter|year)\\b|(?:the\\s+)?end\\b'
  + '|\\d{1,2}(?:st|nd|rd|th|\\s*[ap]\\.?m\\b|/\\d{1,2}\\b)|\\d{1,2}\\s+(?:of\\s+)?' + MONTHS + '|' + MONTHS;
// A level counts only as the whole phrase ("high." or "high priority"), so "low-hanging fruit first" is not one.
const LEVEL = '(?:high|medium|low|critical)(?=\\s+(?:priority|risk|severity|level|impact)\\b|\\s*[.,!]*$)';
const CONTINUES = new RegExp("^(?:(?:and|also|oh|so|then|plus|but)[,.]?\\s+)*(?:(?:it|that|this)(?:'s|\\s+is)\\s+|they(?:'re|\\s+are)\\s+)?"
  + '(?:(?:due|owned|owner|owners|assigned|assign|deadline|priority)\\b|' + LEVEL
  + '|(?:by|before|until)\\s+(?:the\\s+)?(?:' + WHEN + '))', 'i');
// A phrase that never pauses is cut here, so one long monologue cannot hold a command back.
const PHRASE_CHARS = 1500;
const PHRASE_MS = 30000;
const KEPT = 50;
// A command's pause: this long below the quiet level, twice the endpointing silence Deepgram is asked for.
const QUIET_MS = 600;
// Quiet is below -40 dBFS (an RMS of 328 in 16-bit audio), or a tenth of the loudest sound so far for a soft speaker.
const QUIET_LEVEL = 328;
const FINALIZE = JSON.stringify({ type: 'Finalize' });

// The name as speech-to-text writes it or mishears it.
const NAME = '(?:herm[eéèê]s|hermies|hermie|hermy|hermeez|hermez|hermis|hermus|herms)';
// Words that call to it right before the name. Deepgram writes a quick "Okay Hermes" as "K. Hermes" (2026-11-21).
const CALL = '(?:hey|hi|ok|okay|k|kay)';
// Fillers that may come before the call ("So, hey Hermes", "Um okay Hermes").
const FILLER = '(?:so|um|uh|oh|alright|and|now|please|well|yeah|yes)';
// The name at the start of a sentence, right after "hey", "hi" or "okay": only then is it spoken to. In a call about
// Hermes (a call about other people's Hermes, 2026-11-22), "Hermes is good at memory", "So Hermes, the one Lee built, …" or "Can Hermes
// write to Obsidian?" talk about it. "Hermes's notes" talks about Hermes too.
const WAKE = new RegExp(`^(?:${FILLER}[,.]?\\s+)*(${CALL})[,.]?\\s+${NAME}\\b(?!['’]s\\b)\\s*([,.:;!?-]*)\\s*`, 'i');
// A call that Deepgram ended as a sentence of its own ("K. Hermes. Add a goal", "Hey. Hermes, start…") goes with the name.
const CALL_ALONE = new RegExp(`(^|[.!?]\\s+)((?:${FILLER}[,.]?\\s+)*${CALL})[.!?]\\s+(?=${NAME}\\b)`, 'gi');
// The name spoken to in the middle of a sentence, after "hey" or "okay": after a comma, or where Deepgram began a new
// piece of the phrase (a line break, see Phrases). Someone who talks and then turns to the bot without a pause runs the
// two together: Deepgram wrote "So anything new lands on her desk late, Hermes, at a high risk, we only have one
// designer." (a rehearsal call, 2026-11-21). A bare ", Hermes," is talk about it ("Lee, Hermes, and the notes").
const ADDRESSED = new RegExp(`(?:[,;]\\s*|\\s*\\n\\s*)(?=(?:${FILLER}[,.]?\\s+)*${CALL}[,.]?\\s+${NAME}\\b(?!['’]s\\b))`, 'gi');
// The name at a sentence start with no call before it: talk about Hermes, or a command said without "Hey". Only the
// near-miss hint looks at what follows it.
const BARE = new RegExp(`^(?:${FILLER}[,.]?\\s+)*${NAME}\\b(?!['’]s\\b)\\s*[,.:;!?-]*\\s*`, 'i');
const oneLine = (text) => text.replace(/\s*\n\s*/g, ' ').trim();

// Deepgram writes a quick "start a board" as "start aboard" or "starter board" (in 6 of 8 voices tried, 2026-11-21), which
// no board rule reads as a board.
const ABOARD = /\b(start|open|make|create|begin)\s+aboard\b|\b(start)er\s+board\b/gi;
const tidy = (text) => text.replace(ABOARD, (_, verb, starter) => `${verb || starter} a board`);

// A call cuts off the first tenth of a second or so of someone's speech after a silence, and with it the start of the
// name: Deepgram wrote "Hermes, start a whiteboard" with its first 80 to 220 ms cut as "Let me start a whiteboard.",
// "Please start a whiteboard.", "For me, start a whiteboard.", "Me start a board for the launch.", "Yes. Can you start a
// whiteboard?" or "Start a whiteboard." (2026-11-21). The recorder heard a real call's "Hermes, start a whiteboard" as
// "Let me start a whiteboard." twice, and the bot did nothing. These are what can stand where the name was.
const STAND_IN = "(?:let\\s+me|let'?s|let\\s+us|please|for\\s+me|me|yes|yeah|yep|okay|ok|k|so|hey|hi|um|uh|oh|alright|now|and"
  + '|(?:can|could|would|will)\\s+(?:you|we))';
// A request to start a board and nothing else, with at most a topic ("for the launch"). A board meeting, a board member
// or a whiteboard session is talk about something else, and so is a board for later. The bare name may stand before it:
// a clipped "Hey Hermes, start a whiteboard" came back as "Hermes, start a whiteboard." in 4 of 9 clips (2026-11-22).
const START_BOARD = new RegExp(`^(?:(?:${STAND_IN}|${NAME})[,.]?\\s+){0,3}((?:start|open|make|create|begin|set\\s+up|bring\\s+up|pull\\s+up|put\\s+up)`
  + '\\s+(?:up\\s+)?(?:us\\s+)?(?:(?:a|an|the|our|another)\\s+)?(?:(?:new|quick|fresh|blank|meeting)\\s+)*(?:white\\s*)?board\\b'
  + '(?!\\s+(?:meeting|member|members|game|games|room|seat|seats|of|exam|session|sessions)\\b)'
  + '(?:\\s+(?:for|about|on)\\s+[^.?!,]{1,60})?)\\s*[.!?,]*$', 'i');
const LATER = /\b(?:tomorrow|tonight|yesterday|later|next|last|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b/i;

// The request in a phrase that asks to start a board without the name (START_BOARD), as the command to send
// ("start a whiteboard."), or null. Only a short phrase counts, one sentence of which is the whole request.
export function startRequest(text) {
  const all = tidy(oneLine(String(text || '')));
  if (!all || all.split(/\s+/).length > 20) return null;
  for (const sentence of all.split(/(?<=[.!?])\s+/)) {
    const found = sentence.match(START_BOARD);
    if (found && !LATER.test(found[1])) return `${found[1][0].toLowerCase()}${found[1].slice(1)}.`;
  }
  return null;
}

// Words that sound like a board command said with no name Hermes recognized, or with the name but no "Hey": the bot keeps them in /status (never in
// its logs) so the name rules can be tuned from real calls, and its tile tells the speaker to start with "Hey Hermes".
const LOOKS = new RegExp(`^(?:${STAND_IN}[,.]?\\s+){0,3}(?:add|at|put|write|note|start|open|make|create|move|remove|delete|drop|undo`
  + '|recap|wrap\\s+up|mark|assign|rename|change|show|switch|clear|stop\\s+sharing)\\b', 'i');
// A word that may be the name misheard, and the board words that make a near miss worth a hint on the tile.
const NEAR_NAME = /\b(?:hermit\w*|herman|hermon|her\s+(?:mes|miss|mess|meez)|ermes|airmes|homies|thermos)\b/i;
const BOARD_TALK = /\b(?:white\s*board|board|goal|risk|action\s+item|decision|timeline)\b/i;
const NEAR_WORDS = 30;
export function nearMiss(text) {
  const line = oneLine(String(text || ''));
  if (!line || line.split(/\s+/).length > NEAR_WORDS) return null;
  const near = NEAR_NAME.test(line);
  const bare = bareCommand(line);
  if (!near && !bare && !LOOKS.test(line)) return null;
  return { text: line, hint: near || bare || BOARD_TALK.test(line) };
}

// Whether a sentence starts with the bare name and goes on like a board command ("Hermes, add a goal: …"), which is
// said to Hermes without "Hey" and only earns the hint.
function bareCommand(line) {
  const starts = [0, ...[...line.matchAll(/[.!?]\s+/g)].map((m) => m.index + m[0].length)];
  return starts.some((at) => {
    const found = line.slice(at).match(BARE);
    return Boolean(found) && LOOKS.test(line.slice(at + found[0].length));
  });
}

// The command in a phrase that starts a sentence with the wake word, or that speaks to it mid-sentence (ADDRESSED):
// { command, direct }, or null. `direct` is set when the name stands apart ("Hey Hermes, what…" or "Hey Hermes." then
// the command), as when someone speaks to it. The call alone mid-sentence ("Thanks, hey Hermes.") is no command.
// People also say "okay" while they go on talking about it ("Okay, Hermes makes a board of every call."): after anything
// but "hey", the name must stand apart ("Okay Hermes, …") or a board command follow it.
const spokenTo = (found, command) => !command || Boolean(found[2]) || /^hey$/i.test(found[1]) || LOOKS.test(command);

export function wake(text) {
  const all = tidy(String(text || '').trim()).replace(CALL_ALONE, '$1$2, ');
  const sentences = all.split(/(?<=[.!?])\s+/);
  for (let i = 0; i < sentences.length; i++) {
    const found = sentences[i].match(WAKE);
    if (!found) continue;
    const command = oneLine([sentences[i].slice(found[0].length), ...sentences.slice(i + 1)].join(' '));
    if (!spokenTo(found, command)) continue;
    return { command: command.slice(0, COMMAND_CHARS), direct: Boolean(found[2]) || !command };
  }
  for (const at of all.matchAll(ADDRESSED)) {
    const rest = all.slice(at.index + at[0].length);
    const found = rest.match(WAKE);
    const command = oneLine(rest.slice(found[0].length));
    if (command && spokenTo(found, command)) return { command: command.slice(0, COMMAND_CHARS), direct: true };
  }
  return null;
}

// A command that sounds unfinished when the speaker pauses ("Hermes, add a risk:", "put Kim in the"), which waits for
// the rest until UtteranceEnd instead of ending at the first short silence.
const UNFINISHED = /(?:[:,;-]|\b(?:a|an|the|to|for|and|or|of|with|about|on|in|into|under|from|by|called|named|saying|that|is|are|add|put|write|draw|make|move))[.?!]?$/i;
// "add a risk" often comes back as "at a risk", which the mini reads as "add" (meeting_board.spoken).
const SHORT_ADD = /^(?:please\s+)?(?:add|at|put|write|note)\b\S*(?:\s+\S+){0,2}[.?!]?$/i;
const unfinished = (command) => UNFINISHED.test(command.trim()) || SHORT_ADD.test(command.trim());
// A command that still sounds unfinished when the utterance ends waits this long more for its words. Deepgram can drop a
// word and then end the utterance at the pause after it: "Hermes, add a high" and, a second later, "we only have one
// designer, and she is booked through January." (a rehearsal call, 2026-11-21, where the risk reached the board as
// "New high risk"). The next phrase in that time finishes it, unless it starts a command of its own.
const HOLD_MS = 4000;

// While no board is up, an unnamed request to start one (startRequest) counts as a command, once in this long.
const START_AGAIN_MS = 30000;

// Puts Deepgram's words together into phrases, and hands on each command found. While a command is being spoken,
// `onHearing` gets its words so far ({ id, command }), and `onCommand` gets the finished command with the same id.
// Ids are `prefix` and a count. `onWords` gets every phrase's words as they come, command or not, for the bot's tile;
// `onNearMiss` gets a finished phrase that looks like a board command with no name (nearMiss), and an unnamed request to
// start a board that was taken (`started`); `canStart` says whether no board is up, when such a request is taken.
export class Phrases {
  constructor(onCommand, now = Date.now, onHearing = () => {}, prefix = 'v',
    { onWords = () => {}, onNearMiss = () => {}, canStart = () => false } = {}) {
    Object.assign(this, { onWords, onNearMiss, canStart });
    this.startedAt = null;
    this.onCommand = onCommand;
    this.onHearing = onHearing;
    this.now = now;
    this.prefix = prefix;
    this.parts = [];
    this.since = 0;
    this.waiting = null;
    this.count = 0;
    this.lastHeard = null;
    // The last command sent: { id, at, n } (n continuations so far); and when the phrase being heard began.
    this.last = null;
    this.phraseAt = null;
    // An unfinished command waiting for its words after the utterance ended: { command, direct, at }.
    this.held = null;
  }

  message(msg) {
    this.tick();
    if (msg?.type === 'UtteranceEnd') return this.flush({ force: true });
    if (msg?.type !== 'Results') return;
    const text = String(msg.channel?.alternatives?.[0]?.transcript || '').trim();
    if (text) {
      this.phraseAt ??= this.now();
      this.onWords(oneLine([...this.parts, text].join(' ')));
    }
    if (!msg.is_final) {
      if (text) this.hear(text);
      return;
    }
    if (text) {
      if (!this.parts.length) this.since = this.now();
      this.parts.push(text);
      this.hear('');
    }
    if (this.parts.join(' ').length > PHRASE_CHARS || this.now() - this.since > PHRASE_MS) return this.flush({ force: true });
    if (msg.speech_final || msg.from_finalize) this.flush({ force: false });
  }

  // A command is being said and has not ended yet.
  pending() {
    return this.lastHeard !== null || this.held !== null;
  }

  // A held command whose words never came goes as it was. Words that started coming in time finish it when they end.
  tick() {
    if (!this.held || this.phraseAt !== null || this.now() - this.held.at < HOLD_MS) return;
    const { held } = this;
    this.held = null;
    this.lastHeard = null;
    this.send(held);
  }

  // The stream dropped: a new one starts on new words, so the half of a phrase heard before is forgotten rather than
  // joined to them into a command nobody said.
  reset() {
    this.unnamedHeard = false;
    this.parts = [];
    this.lastHeard = null;
    this.waiting = null;
    this.last = null;
    this.phraseAt = null;
    this.held = null;
  }

  // Whether `text`, the phrase being heard, carries on the last command.
  continues(text) {
    const { last } = this;
    if (!last || last.n >= CONTINUE_MAX || (this.phraseAt ?? this.now()) - last.at > CONTINUE_MS) return false;
    return text.split(/\s+/).length <= CONTINUE_WORDS && !/\?\s*$/.test(text) && CONTINUES.test(text);
  }

  // The command's words so far, from the final words and the interim ones after them.
  hear(interim) {
    const pieces = [...this.parts, interim].join('\n').trim();
    const text = oneLine(pieces);
    const following = this.waiting !== null && this.now() - this.waiting < FOLLOW_MS;
    const rest = this.held && text && !wake(pieces) && { command: `${this.held.command} ${text}`, direct: this.held.direct };
    const found = rest || (following ? { command: wake(pieces)?.command || text, direct: true } : wake(pieces)
      || (this.continues(text) && { command: text, direct: true }) || this.unnamedStart(text));
    if (!found?.command || found.command === this.lastHeard) return;
    this.lastHeard = found.command;
    this.onHearing({ id: `${this.prefix}${this.count + 1}`, command: found.command.slice(0, COMMAND_CHARS) });
  }

  // Ends the phrase. Without `force` (a short silence), a command that sounds unfinished keeps waiting for its words.
  flush({ force }) {
    const pieces = this.parts.join('\n').trim();
    const text = oneLine(pieces);
    // Words heard only as interim results and then dropped by Deepgram started no phrase, and no request to start a
    // board.
    if (!text) {
      this.phraseAt = null;
      this.unnamedHeard = false;
      return;
    }
    if (this.held) {
      const { held } = this;
      if (!wake(pieces)) {
        const command = `${held.command} ${text}`;
        if (!force && unfinished(command)) return;
        this.held = null;
        this.clear();
        return this.send({ command, direct: held.direct });
      }
      // A new command begins: the held one goes as it was, first.
      this.held = null;
      this.send(held);
    }
    const following = this.waiting !== null && this.now() - this.waiting < FOLLOW_MS;
    // The command after a bare "Hey Hermes" can itself start with the name; it is still one command.
    const wakeFound = following ? { command: wake(pieces)?.command || text, direct: true } : wake(pieces);
    const carried = !wakeFound && this.continues(text);
    const unnamed = !wakeFound && !carried && this.unnamedStart(text);
    const found = carried ? { command: text, direct: true } : wakeFound || unnamed;
    if (found?.command && unfinished(found.command)) {
      if (!force) return;
      if (!carried) {
        this.clear();
        this.lastHeard = found.command;
        this.held = { command: found.command, direct: found.direct, at: this.now() };
        return;
      }
    }
    this.clear();
    if (unnamed) {
      this.startedAt = this.now();
      this.onNearMiss({ text, started: true });
    }
    if (!found) {
      const near = nearMiss(text);
      if (near) this.onNearMiss(near);
      return;
    }
    if (!found.command) {
      this.waiting = this.now();
      return;
    }
    this.send(found, carried);
  }

  // An unnamed request to start a board, taken only while no board is up and not again soon after one was taken.
  // Once its words have been taken as one while it was said, the request stays one when it finishes, whatever hearing it
  // started (the board going on screen) has done since.
  unnamedStart(text) {
    if (this.startedAt !== null && this.now() - this.startedAt < START_AGAIN_MS) return null;
    const command = startRequest(text);
    if (!command || !(this.unnamedHeard || this.canStart())) return null;
    this.unnamedHeard = true;
    return { command, direct: true };
  }

  clear() {
    this.unnamedHeard = false;
    this.parts = [];
    this.lastHeard = null;
    this.waiting = null;
    this.phraseAt = null;
  }

  // Hands on a finished command, with the next id.
  send(found, carried = false) {
    this.count += 1;
    const id = `${this.prefix}${this.count}`;
    const command = { id, command: found.command.slice(0, COMMAND_CHARS), direct: found.direct };
    if (carried) {
      // The command it carries on is the first of the chain, so the board's tail of edits keeps one thread.
      command.continues = this.last.id;
      this.last = { ...this.last, at: this.now(), n: this.last.n + 1 };
    } else {
      this.last = { id, at: this.now(), n: 0 };
    }
    this.onCommand(command);
  }
}

// How long the call's audio has been quiet, from the audio itself. Silence before anyone has spoken never counts, and
// a chunk can end mid-sample, so the odd byte waits for the next one.
export class Pause {
  constructor() {
    this.loudest = 0;
    this.quietMs = 0;
    this.carry = null;
    this.level = 0;
  }

  // Whether the last chunk was louder than quiet (-40 dBFS): sound Deepgram should answer.
  loud() {
    return this.level >= QUIET_LEVEL;
  }

  // Takes a chunk of 16 kHz 16-bit audio; gives the ms of quiet up to its end.
  add(chunk) {
    const bytes = this.carry ? Buffer.concat([this.carry, chunk]) : chunk;
    const even = bytes.length - (bytes.length % 2);
    this.carry = even < bytes.length ? bytes.subarray(even) : null;
    if (!even) return this.quietMs;
    let sum = 0;
    for (let i = 0; i < even; i += 2) sum += bytes.readInt16LE(i) ** 2;
    const level = this.level = Math.sqrt(sum / (even / 2));
    this.loudest = Math.max(this.loudest, level);
    this.quietMs = level < Math.min(QUIET_LEVEL, this.loudest / 10) ? this.quietMs + even / 32 : 0;
    return this.quietMs;
  }
}

// The call's audio as 16 kHz mono 16-bit PCM, from the same Pulse monitor the recording reads.
const captureCall = () => spawn('ffmpeg', ['-nostdin', '-hide_banner', '-loglevel', 'error', '-f', 'pulse', '-i', 'meet.monitor',
  '-ac', '1', '-ar', '16000', '-f', 's16le', 'pipe:1'], { stdio: ['ignore', 'pipe', 'inherit'] });

// The stream to Deepgram for one call. `update` runs every tick and opens or closes the stream; a failure never reaches
// the call or its recording, which run on their own. `onListening` hears whenever `listening()` changes.
export class Voice {
  constructor({ key, onCommand, onHearing, onListening = () => {}, log = console.log, now = Date.now,
    maxSeconds = MAX_SECONDS, connect = (url, protocols) => new WebSocket(url, protocols), capture = captureCall,
    onWords, onNearMiss, canStart }) {
    Object.assign(this, { key, log, now, maxSeconds, connect, capture, onListening });
    // A command's id is its own for the whole call: the board room takes a command it has seen once, by id, so the ids
    // of a bot process that starts over carry its start time rather than counting from v1 again.
    this.phrases = new Phrases(onCommand, now, onHearing, `v${now().toString(36)}.`, { onWords, onNearMiss, canStart });
    this.state = key ? 'idle' : 'off';
    this.error = key ? null : 'no Deepgram key';
    this.bytes = 0;
    this.failures = 0;
    this.retryAt = 0;
    this.done = !key;
    this.ws = null;
    this.audio = null;
    // When sound was first sent after Deepgram's last answer, or null.
    this.unanswered = null;
    // Since when the call could not be seen, or null.
    this.awaySince = null;
    this.told = this.listening();
  }

  // Whether a command said now can be heard. Not while the stream is down or being tried again, once it has given up or
  // reached its limit, or with no key: the board's status bar then says "Not listening, type in chat". Once the call is
  // over ('stopped') the bar is left as it was; the room says when the call has ended.
  listening() {
    if (this.state === 'connecting') return !this.failures;
    return ['idle', 'paused', 'listening', 'stopped'].includes(this.state);
  }

  report() {
    const on = this.listening();
    if (on === this.told) return;
    this.told = on;
    this.onListening(on);
  }

  seconds() {
    return this.bytes / BYTES_PER_SECOND;
  }

  status() {
    return { state: this.state, error: this.error, streamed_seconds: Math.round(this.seconds()) };
  }

  // Streams while the bot is in the call with someone else; stops while it is alone, since nobody can ask anything, and
  // once the call has been out of sight for AWAY_MS.
  update(where) {
    this.phrases.tick();
    this.step(where);
    this.report();
  }

  step({ inCall, alone }) {
    if (this.done) return;
    if (this.seconds() >= this.maxSeconds) {
      this.close();
      return this.end('capped', `reached the ${Math.round(this.maxSeconds / 60)}-minute limit for one call`);
    }
    if (inCall) this.awaySince = null;
    else this.awaySince ??= this.now();
    const away = !inCall && !(this.ws && this.now() - this.awaySince < AWAY_MS);
    if (away || alone) {
      if (this.ws) this.close();
      if (this.state !== 'retrying') this.state = 'paused';
      return;
    }
    if (this.ws && this.state === 'connecting' && this.now() - this.openedAt > CONNECT_MS) {
      return this.fail('Deepgram did not answer');
    }
    if (this.ws && this.unanswered !== null && this.now() - this.unanswered > ANSWER_MS) {
      return this.fail('Deepgram stopped answering');
    }
    if (!this.ws && inCall && this.now() >= this.retryAt) this.open();
  }

  open() {
    this.state = 'connecting';
    this.openedAt = this.now();
    this.unanswered = null;
    let ws, audio;
    try {
      ws = this.ws = this.connect(URL, ['token', this.key]);
      audio = this.audio = this.capture();
    } catch (error) {
      return this.fail(`could not start: ${error.message}`);
    }
    ws.binaryType = 'arraybuffer';
    ws.onopen = () => {
      if (this.ws !== ws) return;
      this.state = 'listening';
      this.report();
    };
    ws.onmessage = (event) => {
      if (this.ws !== ws) return;
      this.unanswered = null;
      if (this.failures && this.now() - this.openedAt >= HEALTHY_MS) {
        this.failures = 0;
        this.error = null;
      }
      let msg;
      try {
        msg = JSON.parse(typeof event.data === 'string' ? event.data : Buffer.from(event.data).toString());
      } catch {
        return;
      }
      this.phrases.message(msg);
    };
    // Node 22 reports a refused handshake (a wrong key, no credit) only as an error, with no close after it.
    ws.onerror = () => {
      if (this.ws === ws) this.fail('Deepgram refused or dropped the stream');
    };
    ws.onclose = (event) => {
      if (this.ws === ws) this.fail(`Deepgram closed the stream (${event.code}${event.reason ? `: ${event.reason}` : ''})`);
    };
    audio.on('error', (error) => {
      if (this.audio === audio) this.fail(`audio capture: ${error.message}`);
    });
    audio.on('exit', (code) => {
      if (this.audio === audio) this.fail(`audio capture stopped (${code})`);
    });
    // Audio from before the stream opens, or while the network lags, is dropped rather than held: only live speech counts.
    // A pause in a command asks Deepgram, once, to finish the words it has.
    const pause = new Pause();
    let finished = false;
    audio.stdout.on('data', (chunk) => {
      if (this.ws !== ws || ws.readyState !== 1 || ws.bufferedAmount > 1 << 20) return;
      ws.send(chunk);
      this.bytes += chunk.length;
      const quietMs = pause.add(chunk);
      if (pause.loud()) this.unanswered ??= this.now();
      if (!quietMs) finished = false;
      else if (quietMs >= QUIET_MS && !finished && this.phrases.pending()) {
        finished = true;
        ws.send(FINALIZE);
      }
    });
  }

  fail(reason) {
    this.close();
    this.failures += 1;
    this.log('voice', reason);
    if (this.failures > RETRIES.length) return this.end('failed', reason);
    this.state = 'retrying';
    this.error = reason;
    this.retryAt = this.now() + RETRIES[this.failures - 1];
    this.report();
  }

  close() {
    const { ws, audio } = this;
    this.ws = this.audio = null;
    this.unanswered = null;
    this.phrases.reset();
    if (ws) {
      try {
        if (ws.readyState === 1) ws.send(JSON.stringify({ type: 'CloseStream' }));
        ws.close();
      } catch {
        // Already closed.
      }
    }
    if (audio && audio.exitCode === null) audio.kill('SIGKILL');
  }

  end(state, error = null) {
    this.done = true;
    this.state = state;
    this.error = error;
    this.log('voice', state, `${(this.seconds() / 60).toFixed(1)} minutes streamed`, error || '');
    this.report();
  }

  // The call is over: the stream closes and never opens again.
  stop() {
    if (this.done) return;
    this.close();
    this.end('stopped');
  }
}
