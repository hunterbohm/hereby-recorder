// The join notice (notice.mjs) against a fake chat. Run: node --test bot/container/
import test from 'node:test';
import assert from 'node:assert/strict';
import { DEFAULT_NOTICE, Notice, PIN_MS, PIN_TRIES, RETRY_MS } from './notice.mjs';

// A chat that shows what was said, unless it drops it or refuses it.
function chat({ drop = 0, refuse = 0, show = (text) => text } = {}) {
  let now = 0;
  const made = { said: [], messages: [], waits: 0 };
  made.notice = (text) => new Notice({
    text,
    now: () => now,
    wait: async () => { made.waits += 1; },
    shown: async () => made.messages,
    say: async (words) => {
      if (refuse-- > 0) throw new Error('chat is turned off\nby the host');
      made.said.push(words);
      if (drop-- > 0) return;
      made.messages.push(show(words));
    },
  });
  made.at = (ms) => { now = ms; };
  return made;
}

test('the notice is posted once and counts only when the chat shows it', async () => {
  const made = chat();
  const notice = made.notice('Hi, I record this call.');
  assert.equal(await notice.step(), true);
  assert.deepEqual(made.said, ['Hi, I record this call.']);
  assert.deepEqual(notice.status(), { state: 'posted', tries: 1, error: null, at: new Date(0).toISOString(), pinned: null });
  assert.equal(await notice.step(), true);
  assert.equal(made.said.length, 1, 'never posted again');
});

test('a notice the chat does not show is tried again soon, and one that went out late is not posted twice', async () => {
  const made = chat({ drop: 1 });
  const notice = made.notice('Hi, I record this call.');
  assert.equal(await notice.step(), false);
  assert.deepEqual(notice.status(), { state: 'retrying', tries: 1, error: 'the notice did not show in the chat', at: null,
    pinned: null });
  assert.equal(made.waits, 5, 'the chat was read six times, a second apart');
  made.at(2999);
  assert.equal(await notice.step(), false, 'not due yet');
  assert.equal(notice.tries, 1);
  // The first one shows up after all.
  made.messages.push('Hi, I record this call.');
  made.at(3000);
  assert.equal(await notice.step(), true);
  assert.equal(made.said.length, 1);
});

test('after three failed tries the notice has failed, and the bot keeps trying every minute until it posts', async () => {
  const made = chat({ refuse: 4 });
  const notice = made.notice('Hi, I record this call.');
  for (const at of [0, 3000, 13000]) {
    made.at(at);
    assert.equal(await notice.step(), false);
  }
  assert.deepEqual(notice.status(), { state: 'failed', tries: 3, error: 'chat is turned off', at: null, pinned: null });
  made.at(13000 + RETRY_MS - 1);
  assert.equal(await notice.step(), false);
  assert.equal(notice.tries, 3, 'a minute between tries once it has failed');
  made.at(13000 + RETRY_MS);
  assert.equal(await notice.step(), false);
  assert.equal(notice.state, 'failed');
  made.at(13000 + 2 * RETRY_MS);
  assert.equal(await notice.step(), true);
  assert.deepEqual(made.said, ['Hi, I record this call.']);
});

test('without a notice the neutral one is posted, and the chat may show it with other spaces or apostrophes', async () => {
  const made = chat({ show: (text) => `10:02 AM\n${text.replace(/'/g, '’').replace(/\. /g, '.\n')}\nPin message` });
  const notice = made.notice('  ');
  assert.equal(await notice.step(), true);
  assert.deepEqual(made.said, [DEFAULT_NOTICE]);
  assert.match(DEFAULT_NOTICE, /for the person who invited me/, 'the default names nobody');
});

test('a posted notice is pinned, for people who join later; a missed pin is tried again, and one never allowed changes nothing', async () => {
  // How many pins the call refuses first, and what each due try then reports.
  for (const { misses, reports } of [{ misses: 0, reports: [true, true, true, true] },
    { misses: 1, reports: [null, true, true, true] }, { misses: PIN_TRIES, reports: [null, null, false, false] }]) {
    let now = 0;
    const messages = [];
    const pins = [];
    const notice = new Notice({ text: 'Hi, I record this call.', say: async (t) => messages.push(t),
      shown: async () => messages, wait: async () => {}, now: () => now,
      pin: async (t) => { pins.push(t); if (pins.length <= misses) throw new Error('only hosts can pin'); } });
    assert.equal(await notice.pinStep(), null, 'nothing to pin before the notice is posted');
    assert.equal(await notice.step(), true);
    for (const [i, report] of reports.entries()) {
      assert.equal(await notice.pinStep(), report, `try ${i + 1}`);
      now += PIN_MS - 1;
      const tries = pins.length;
      await notice.pinStep();
      assert.equal(pins.length, tries, 'no try before it is due');
      now += 1;
    }
    assert.equal(pins.length, Math.min(misses + 1, PIN_TRIES), 'a pin that worked, or ran out of tries, is not tried again');
    assert.deepEqual([notice.state, notice.status().pinned], ['posted', misses < PIN_TRIES]);
  }
});

test('chat from before the notice is everything up to the last notice, and nothing is when the notice is not there', () => {
  const notice = new Notice({ text: "Hi, I'm recording this call.", say: async () => {}, shown: async () => [] });
  const chat = [{ id: 1, body: 'hermes, put the price on the board' }, { id: 2, body: "Hi, I'm recording\nthis call." },
    { id: 3, body: 'before the second try showed' }, { id: 4, body: "Hi, I’m recording this call." },
    { id: 5, body: 'hermes, add risks' }];
  assert.deepEqual(notice.upTo(chat).map((m) => m.id), [1, 2, 3, 4]);
  assert.equal(notice.upTo(chat.filter((m) => m.id === 1 || m.id === 5)), null);
});
