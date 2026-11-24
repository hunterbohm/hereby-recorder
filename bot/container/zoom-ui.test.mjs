// Zoom's popups and the board share's follow-up (zoom-ui.mjs), against a small fake page. Run: node --test bot/container/
import test from 'node:test';
import assert from 'node:assert/strict';
import { HOST_ONLY, pressPopups, SHARE_DISABLED, SHARE_RETRY_FOR_MS, SHARE_RETRY_MS, SHARE_SETTLE_MS, ShareFollow,
  ZOOM_POPUPS } from './zoom-ui.mjs';

// A fake element: its own words, a label, children, and whether it is on screen. Only what pressPopups uses, with the
// few selectors it asks for.
function matches(node, selector) {
  if (/chat-message/.test(selector)) return /chat-message|chat-list/.test(node.cls);
  if (selector === '[role=img][aria-label]') return node.role === 'img' && node.label !== null;
  return node.button || node.role === 'button';
}

function el({ text = '', label = null, cls = '', button = false, role = null, shown = true, children = [] } = {}) {
  const node = { text, label, cls, button, role, shown, children, parentElement: null, clicks: 0 };
  for (const child of children) child.parentElement = node;
  const all = () => children.flatMap((child) => [child, ...child.all()]);
  Object.assign(node, {
    all,
    get innerText() { return [text, ...children.map((child) => child.innerText)].filter(Boolean).join('\n'); },
    get textContent() { return node.innerText; },
    getAttribute: (name) => (name === 'aria-label' ? label : name === 'role' ? role : null),
    getClientRects: () => (shown ? [{}] : []),
    click() { node.clicks += 1; },
    querySelector: (selector) => all().find((child) => matches(child, selector)) || null,
    querySelectorAll: (selector) => all().filter((child) => matches(child, selector)),
  });
  return node;
}

function page(...children) {
  const body = el({ children });
  globalThis.document = { querySelectorAll: body.querySelectorAll };
  return body;
}

// Zoom's graphics notice as its code draws it: the words, a link, and a button showing only an icon named "Close".
function graphicsNotice() {
  const close = el({ button: true, children: [el({ role: 'img', label: 'Close' })] });
  const notice = el({ cls: 'notification-message-wrap', children: [
    el({ text: "For a better meeting experience, enable the option 'Use graphics/hardware acceleration' under browser system settings." }),
    el({ text: 'Learn more' }),
    close,
  ] });
  return { notice, close };
}

test('each popup seen in Zoom is closed by its own button', () => {
  const gotIt = el({ text: 'Got it', button: true });
  const { notice, close } = graphicsNotice();
  const ok = el({ text: 'OK', button: true });
  const guest = el({ text: 'Got it', button: true });
  page(
    el({ cls: 'pop-panel', children: [el({ children: [el({ text: 'Introducing My Notes — and a new home for Zoom AI' }), gotIt] })] }),
    notice,
    el({ cls: 'zm-modal', children: [el({ text: 'This meeting is being livestreamed. Anyone with access to the livestream may view or share it with others.' }), el({ children: [ok] })] }),
    el({ children: [el({ text: "You're chatting as a guest" }), guest] }),
  );
  assert.deepEqual(pressPopups(ZOOM_POPUPS).sort(), ['guest_chat', 'hardware', 'livestream', 'my_notes']);
  assert.deepEqual([gotIt.clicks, close.clicks, ok.clicks, guest.clicks], [1, 1, 1, 1]);
});

test('the call itself is left alone: Leave, Share, a hidden button, and a button with no popup words around it', () => {
  const leave = el({ label: 'Leave', button: true });
  const share = el({ label: 'Share', button: true });
  const hidden = el({ text: 'Got it', button: true, shown: false });
  const stray = el({ text: 'OK', button: true });
  page(el({ children: [el({ text: 'Introducing My Notes' }), hidden] }), el({ children: [stray, leave, share] }));
  assert.deepEqual(pressPopups([...ZOOM_POPUPS, ...SHARE_DISABLED]), []);
  assert.deepEqual([leave.clicks, share.clicks, hidden.clicks, stray.clicks], [0, 0, 0, 0]);
});

test('words typed in the chat never make the bot press a button near them', () => {
  const close = el({ label: 'Close', button: true });
  page(el({ cls: 'chat-panel', children: [
    el({ cls: 'new-chat-message__container', children: [el({ text: "is 'Use graphics/hardware acceleration' on? the stream is being livestreamed" })] }),
    close,
  ] }));
  assert.deepEqual(pressPopups(ZOOM_POPUPS), []);
  assert.equal(close.clicks, 0);
});

test("a close button beside a notice, not in it, is left alone: it closes something else", () => {
  // In a test call (2026-11-22) a press counted for the graphics notice left it on screen: the Close pressed was
  // another one near it.
  const other = el({ label: 'Close', button: true });
  const { notice, close } = graphicsNotice();
  page(el({ cls: 'notification-stack', children: [el({ children: [el({ text: "You're screen sharing" }), other] }), notice] }));
  assert.deepEqual(pressPopups(ZOOM_POPUPS), ['hardware']);
  assert.deepEqual([close.clicks, other.clicks], [1, 0]);
});

test("the host's refusal is pressed only when asked for, so the share can report it", () => {
  const ok = el({ text: 'OK', button: true });
  page(el({ cls: 'zm-modal', children: [el({ text: 'Disabled Share' }), el({ text: 'Host disabled attendee screen sharing.' }), ok] }));
  assert.deepEqual(pressPopups(ZOOM_POPUPS), [], 'the tick leaves it for the share');
  assert.deepEqual(pressPopups(SHARE_DISABLED), ['share_disabled']);
  assert.equal(ok.clicks, 1);
  assert.equal(HOST_ONLY, 'the host lets only the host share');
});

function clock() {
  let now = 1000;
  return { now: () => now, add: (ms) => { now += ms; } };
}

test('a share pressed but not seen fails only once it has had SHARE_SETTLE_MS more', () => {
  const time = clock();
  const share = new ShareFollow(time);
  share.unconfirmed();
  time.add(SHARE_SETTLE_MS - 1);
  assert.equal(share.failed(), false);
  time.add(1);
  assert.equal(share.failed(), true);
  assert.equal(share.failed(), false, 'told once');
});

test('a share that comes up while pending is not failed later', () => {
  const time = clock();
  const share = new ShareFollow(time);
  share.unconfirmed();
  time.add(10000);
  share.settled();
  time.add(SHARE_SETTLE_MS);
  assert.equal(share.failed(), false);
});

test('after a refusal the share is tried again every SHARE_RETRY_MS, for SHARE_RETRY_FOR_MS from the first one', () => {
  const time = clock();
  const share = new ShareFollow(time);
  assert.equal(share.retry(), false, 'nothing refused yet');
  share.refused();
  assert.equal(share.retry(), false);
  time.add(SHARE_RETRY_MS);
  assert.equal(share.retry(), true);
  assert.equal(share.retry(), false, 'one try per wait');
  share.refused();
  time.add(SHARE_RETRY_MS);
  assert.equal(share.retry(), true, 'a refused retry waits again');
  time.add(SHARE_RETRY_FOR_MS);
  assert.equal(share.retry(), false, 'the window is over');
  share.refused();
  time.add(SHARE_RETRY_MS);
  assert.equal(share.retry(), true, "a person's next request opens a new window");
  share.settled();
  time.add(SHARE_RETRY_MS);
  assert.equal(share.retry(), false, 'shared: no more tries');
});

test('no retry while a share pressed on a retry may still be starting', () => {
  const time = clock();
  const share = new ShareFollow(time);
  share.refused();
  time.add(SHARE_RETRY_MS);
  assert.equal(share.retry(), true);
  share.unconfirmed();
  time.add(SHARE_RETRY_MS);
  assert.equal(share.retry(), false, 'waits for the pending share');
  time.add(SHARE_SETTLE_MS);
  assert.equal(share.failed(), true);
  time.add(SHARE_RETRY_MS);
  assert.equal(share.retry(), true, 'tries again once it has failed');
});

test('a refusal ends a pending share at once', () => {
  const time = clock();
  const share = new ShareFollow(time);
  share.unconfirmed();
  share.refused();
  time.add(SHARE_SETTLE_MS);
  assert.equal(share.failed(), false);
});
