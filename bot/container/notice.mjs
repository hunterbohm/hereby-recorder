// The notice the bot posts in the meeting chat the moment it is let into a call: everyone is told it records the call
// before it records or listens. The bot then reads the chat back, and only a notice it sees there counts as posted. A
// try that fails is tried again soon, then every minute for as long as the bot is in the call; until one is seen, the
// bot neither records nor listens. Once posted, the notice is pinned where the call lets the bot pin it, because Meet
// shows someone who joins later only the chat that is pinned.
export const DEFAULT_NOTICE = "Hi, I'm an AI notetaker. I'm recording and transcribing this call for the person who "
  + "invited me. If you'd rather not be recorded, ask them to remove me.";
// Meet's chat takes 500 characters.
export const MAX_CHARS = 500;
// The waits before the second and third tries; after the third the notice counts as failed (the mini texts the owner),
// and the bot keeps trying every RETRY_MS.
const SOON_MS = [3000, 10000];
export const RETRY_MS = 60000;
// A message just sent takes a moment to show; the chat is read this many times, this far apart.
const LOOKS = 6;
const LOOK_MS = 1000;
// A pin can miss (a panel Meet opens by itself can cover the chat for a while), so it is tried this many times, this
// far apart.
export const PIN_TRIES = 3;
export const PIN_MS = 20000;

// Words as the chat shows them: spaces and line breaks run together, and either kind of apostrophe.
const squash = (text) => String(text || '').replace(/[’‘]/g, "'").replace(/\s+/g, ' ').trim();

export class Notice {
  // `say(text)` posts in the chat; `shown()` gives the chat messages' words as the page shows them now; `pin(text)`, if
  // the platform has one, pins the posted notice.
  constructor({ text, say, shown, pin = null, now = Date.now, wait = (ms) => new Promise((done) => setTimeout(done, ms)) }) {
    this.text = squash(text) || DEFAULT_NOTICE;
    this.say = say;
    this.shown = shown;
    this.pin = pin;
    this.pinned = null;
    this.pinTries = 0;
    this.pinAt = 0;
    this.now = now;
    this.wait = wait;
    this.state = 'waiting';
    this.tries = 0;
    this.error = null;
    this.at = null;
    this.next = 0;
  }

  get posted() {
    return this.state === 'posted';
  }

  shows(words) {
    return squash(words).includes(squash(this.text));
  }

  async seen(looks = 1) {
    for (let i = 0; i < looks; i++) {
      if (i) await this.wait(LOOK_MS);
      if ((await this.shown()).some((words) => this.shows(words))) return true;
    }
    return false;
  }

  // Of the chat's messages ({ body }, in the chat's order), those up to and including the last notice: people typed
  // them before they were told, so the bot keeps none of them. Null when the notice is not among them.
  upTo(messages) {
    const last = messages.findLastIndex((message) => this.shows(message.body));
    return last < 0 ? null : messages.slice(0, last + 1);
  }

  // One try, when one is due: true once the notice is in the chat. A notice that went out on an earlier try but was
  // not seen then is looked for first, so it is never posted twice.
  async step() {
    if (this.posted || this.now() < this.next) return this.posted;
    this.tries += 1;
    try {
      if (this.tries === 1 || !await this.seen()) {
        await this.say(this.text);
        if (!await this.seen(LOOKS)) throw new Error('the notice did not show in the chat');
      }
      this.state = 'posted';
      this.error = null;
      this.at = new Date(this.now()).toISOString();
      return true;
    } catch (error) {
      this.error = String(error?.message || error).split('\n')[0].slice(0, 200);
      this.state = this.tries > SOON_MS.length ? 'failed' : 'retrying';
      this.next = this.now() + (SOON_MS[this.tries - 1] ?? RETRY_MS);
      return false;
    }
  }

  // Pins the posted notice, when a try is due: true once pinned, false once every try failed, null until then.
  // Everyone in the call has seen the notice by then, so a pin that never works (a host who lets only hosts pin)
  // changes nothing else.
  async pinStep() {
    if (!this.posted || !this.pin || this.pinned !== null || this.now() < this.pinAt) return this.pinned;
    this.pinTries += 1;
    try {
      await this.pin(this.text);
      this.pinned = true;
    } catch {
      if (this.pinTries >= PIN_TRIES) this.pinned = false;
      this.pinAt = this.now() + PIN_MS;
    }
    return this.pinned;
  }

  status() {
    return { state: this.state, tries: this.tries, error: this.error, at: this.at, pinned: this.pinned };
  }
}
