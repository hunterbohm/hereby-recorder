// Zoom's own popups over the bot's call, and how the bot follows a board share Zoom is slow to start or the host
// refuses. Kept apart from driver.mjs so they can be tested without a browser.

// The words Zoom shows when the host lets only the host share and the bot presses Share. The bot reports this as its
// share error, and the mini tells the owner how the host turns sharing on (mini/meeting_bot.py SHARE_HOST_ONLY).
export const HOST_ONLY = 'the host lets only the host share';

// Zoom's popups over the call, each by the words it shows and the one button that closes it. Only these buttons are
// pressed, and only inside a popup showing these words: all of them dismiss, none changes the call. Seen in a real call
// and a test call on 2026-11-22, where they stayed up over the call for as long as the bot was in it.
export const ZOOM_POPUPS = [
  // On every Chrome signed in to Zoom for the first time, as the bot's is in each call.
  { name: 'my_notes', words: 'Introducing My Notes', button: '^got it$' },
  // The first time the bot opens the chat.
  { name: 'guest_chat', words: 'chatting as a guest', button: '^got it$' },
  // The bot's Chrome draws without a graphics card. Its close button shows only an icon named "Close".
  { name: 'hardware', words: 'graphics/hardware acceleration', button: '^close$' },
  // A call someone streams, such as with their own notetaker.
  { name: 'livestream', words: 'being livestreamed', button: '^(ok|got it)$' },
];

// What Zoom shows when the bot presses Share and the host lets only the host share: a "Disabled Share" dialog,
// "Host disabled attendee screen sharing." with OK. Pressed by the share itself (driver.mjs), which reports it.
export const SHARE_DISABLED = [
  { name: 'share_disabled', words: 'host disabled (attendee|participant) screen sharing|only (the )?host can share',
    button: '^ok$' },
];

// Runs in Zoom's page (it is handed to the page as text, so it uses nothing from this file): presses the closing
// button of each popup in `popups` that is on screen, and returns the names of those it pressed. A popup is the
// nearest box around one of those buttons that shows its words and holds no other such button: a box holding two is
// a wider part of the page, such as Zoom's stack of notices, where the button may close a different notice. A box
// holding chat messages is never one, since anyone in the call can type the same words in the chat.
export function pressPopups(popups) {
  const pressed = [];
  // A button showing only an icon is named by the icon, as Zoom's close buttons are.
  const label = (el) => (el.getAttribute('aria-label') || el.innerText || el.textContent || '').trim()
    || (el.querySelector('[role=img][aria-label]')?.getAttribute('aria-label') || '').trim();
  const controls = (root) => [...root.querySelectorAll('button, [role=button]')].filter((el) => el.getClientRects().length);
  const chat = '.new-chat-message__container, [class*="chat-message"], [class*="chat-list"]';
  for (const control of controls(document)) {
    const name = label(control);
    for (const popup of popups) {
      const button = new RegExp(popup.button, 'i');
      if (pressed.includes(popup.name) || !button.test(name)) continue;
      const words = new RegExp(popup.words, 'i');
      let box = control.parentElement;
      for (let up = 0; box && up < 5 && !words.test(box.innerText || box.textContent || ''); up += 1) {
        box = box.parentElement;
      }
      if (!box || box.querySelector(chat) || !words.test(box.innerText || box.textContent || '')) continue;
      if (controls(box).filter((el) => button.test(label(el))).length !== 1) continue;
      control.click();
      pressed.push(popup.name);
      break;
    }
  }
  return pressed;
}

// A share Zoom has not shown as started by the time the bot stops waiting can still start: in a real call (2026-11-22)
// one the bot had reported failed, and the owner had been texted about, was counted a minute or so later. So a share
// pressed but not seen when the bot stops waiting fails only if it is still not up this much later.
export const SHARE_SETTLE_MS = 90000;
// After the host refused a share, the bot tries again by itself this often, for this long after the first refusal,
// while a board is up and nobody else is sharing; a person's next board request tries again too, as before.
export const SHARE_RETRY_MS = 30000;
export const SHARE_RETRY_FOR_MS = 600000;

// How a board share is going, between the bot's tries: one pressed but not yet seen (`pending`), and one the host
// refused (`refusedAt`), which is tried again.
export class ShareFollow {
  constructor({ now = Date.now } = {}) {
    this.now = now;
    this.pending = null;
    this.refusedAt = null;
    this.retryAt = 0;
  }

  // Share was pressed, but the share had not shown as started when the bot stopped waiting.
  unconfirmed() {
    this.pending ??= this.now();
  }

  // The host lets only the host share. The window for trying again starts at the first refusal.
  refused() {
    this.pending = null;
    this.refusedAt ??= this.now();
    this.retryAt = this.now() + SHARE_RETRY_MS;
  }

  // The share is up, or no longer wanted.
  settled() {
    this.pending = null;
    this.refusedAt = null;
  }

  // True once, when a share pressed but never seen has waited SHARE_SETTLE_MS: it failed.
  failed() {
    if (this.pending === null || this.now() - this.pending < SHARE_SETTLE_MS) return false;
    this.pending = null;
    return true;
  }

  // True when the bot should press Share again after a refusal; each true starts the next wait. Never while a share it
  // pressed may still be starting.
  retry() {
    if (this.refusedAt === null || this.pending !== null) return false;
    const now = this.now();
    if (now - this.refusedAt >= SHARE_RETRY_FOR_MS) {
      this.refusedAt = null;
      return false;
    }
    if (now < this.retryAt) return false;
    this.retryAt = now + SHARE_RETRY_MS;
    return true;
  }
}
