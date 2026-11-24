// Spoken commands: which phrases are commands, and when the stream to Deepgram runs. Run with `node --test`.
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { test } from 'node:test';
import { AWAY_MS, nearMiss, Pause, Phrases, startRequest, URL, Voice, wake } from './voice.mjs';

test('a phrase that starts with "Hey Hermes" or "Okay Hermes", or a misheard name after them, is a command', () => {
  assert.deepEqual(wake('Hey Hermes, put the launch dates on a timeline.'), { command: 'put the launch dates on a timeline.', direct: true });
  assert.deepEqual(wake('Okay. Hermès, add a column for risks'), { command: 'add a column for risks', direct: true });
  assert.deepEqual(wake('hey hermies start a whiteboard'), { command: 'start a whiteboard', direct: false });
  assert.deepEqual(wake('So that is settled. Hey Hermes. Make it a timeline.'), { command: 'Make it a timeline.', direct: true });
  assert.deepEqual(wake('Hey Hermes.'), { command: '', direct: true });
  assert.deepEqual(wake('Hey Hermes, start a whiteboard.'), { command: 'start a whiteboard.', direct: true });
  assert.deepEqual(wake('Okay Hermes, add a risk: the Stripe review could slip.'),
    { command: 'add a risk: the Stripe review could slip.', direct: true });
  assert.deepEqual(wake('Hi Hermes, recap.'), { command: 'recap.', direct: true });
  assert.deepEqual(wake('So, hey Hermes, add a goal: ten pilots.'), { command: 'add a goal: ten pilots.', direct: true });
  assert.deepEqual(wake('Um okay Hermes start a board for the launch'), { command: 'start a board for the launch', direct: false });
});

// What people say about Hermes in a call about it (a call about other people's Hermes, 2026-11-22).
const TALK = ['Hermes is really good at memory.', 'So Hermes, the one Lee built, uses Supabase.', 'Can Hermes write to Obsidian?',
  "Acme's Hermes adds a board on its own.", 'And Hermes makes a board of every call.', 'Lee, Hermes, and the notes.',
  'Okay, Hermes makes a board of every call.', 'Okay. Hermes makes a board of every call.'];

test('the name without "Hey" or "Okay", in the middle of a sentence, or talked about, is not a command', () => {
  for (const talk of TALK) assert.equal(wake(talk), null, talk);
  assert.equal(wake('Hermes, put the launch dates on a timeline.'), null);
  assert.equal(wake('So Hermes, add a goal.'), null);
  assert.equal(wake('Hermes.'), null);
  assert.equal(wake('I think Hermes should put that on the board.'), null);
  assert.equal(wake("Hermes's notes were good."), null);
  assert.equal(wake("Hey Hermes's notes were good."), null);
  assert.equal(wake('Hermione, can you share your screen?'), null);
  assert.equal(wake(''), null);
});

test('the talk about Hermes gives no hint, and a command with the bare name gives only the hint', () => {
  for (const talk of TALK) assert.equal(nearMiss(talk), null, talk);
  for (const bare of ['Hermes, add a goal: ten pilots by March.', 'Hermes. Add a goal: ten pilots.', 'Hermes start a whiteboard',
    'So Hermes, put the launch dates on a timeline.']) assert.deepEqual(nearMiss(bare), { text: bare, hint: true }, bare);
});

test('"Hey Hermes" spoken to in the middle of a sentence is a command; the bare name there, or talked about, is not', () => {
  assert.deepEqual(wake("So that's late, hey Hermes, add a high risk: we only have one designer."),
    { command: 'add a high risk: we only have one designer.', direct: true });
  // Where Deepgram began a new piece of the phrase (Phrases puts a line break there).
  assert.deepEqual(wake('So anything new lands on her desk late\nhey Hermes, add a risk: one designer.'),
    { command: 'add a risk: one designer.', direct: true });
  // As Deepgram wrote it in a rehearsal call (2026-11-21): without "hey" it is no longer a command.
  assert.equal(wake('So anything new lands on her desk late, Hermes, at a high risk, we only have one designer.'), null);
  assert.equal(wake('So anything new lands on her desk late\nHermes, add a risk: one designer.'), null);
  assert.deepEqual(wake('We discussed it, okay Hermes makes notes, hey Hermes, add a goal: ship Friday.'),
    { command: 'add a goal: ship Friday.', direct: true });
  assert.equal(wake('Great work, thanks, Hermes.'), null);
  assert.equal(wake('Great work, thanks, hey Hermes.'), null);
  assert.equal(wake('Is that right, Hermes?'), null);
  assert.equal(wake('I asked Hermes, but it did not answer.'), null);
  assert.equal(wake("Okay, Hermes's notes were good."), null);
  assert.equal(wake('I think\nHermes should put that on the board.'), null);
});

test('a quick "Okay Hermes" or "start a board" as Deepgram writes them still reads as the command', () => {
  // As Deepgram wrote them for commands spoken quickly (2026-11-21).
  assert.deepEqual(wake('K. Hermes, start aboard for the launch.'), { command: 'start a board for the launch.', direct: true });
  assert.deepEqual(wake('K. Hermes. Add a goal: ten pilots.'), { command: 'Add a goal: ten pilots.', direct: true });
  assert.deepEqual(wake('Hey Hermes starter board for the launch.'), { command: 'start a board for the launch.', direct: false });
  // Deepgram once wrote "Okay Hermes" as "Can Hermes", but in a call about Hermes that is a question about it.
  assert.equal(wake('Can Hermes start a board for the launch?'), null);
  assert.equal(wake('Can we start with the budget?'), null);
});

test('the greetings people put before the name are key terms too, at no extra price', () => {
  assert.deepEqual(new globalThis.URL(URL).searchParams.getAll('keyterm'), ['Hermes', 'Hey Hermes', 'Okay Hermes', 'whiteboard']);
});

test('a request to start a board with the name cut off is read as one; talk about boards and starting is not', () => {
  // As Deepgram wrote "Hey Hermes, start a whiteboard" with its first tenth of a second cut, as a call cuts it (2026-11-21),
  // and as the recorder heard a real call where nothing happened.
  for (const heard of ['Let me start a whiteboard.', 'Please start a whiteboard.', 'For me, start a whiteboard,', 'Start a whiteboard.',
    'Yes. Can you start a whiteboard?']) assert.equal(startRequest(heard), 'start a whiteboard.', heard);
  assert.equal(startRequest('Me start a board for the launch.'), 'start a board for the launch.');
  assert.equal(startRequest('Start aboard for the launch.'), 'start a board for the launch.');
  assert.equal(startRequest("Let's start a meeting board."), 'start a meeting board.');
  for (const talk of ['Let me start with the budget.', "Let's start with a quick recap of last week.",
    "I'll start a whiteboard session with the design team tomorrow.", 'We should start a board meeting next month.',
    "Let's start a board tomorrow.", 'She wants to start a whiteboard.', 'Start a board game night.',
    'Let me start a whiteboard, and then we can walk through every single one of the open questions from the call last time we met.'])
    assert.equal(startRequest(talk), null, talk);
});

test('an unnamed request to start a board is a command only while no board is up, and once in a while', () => {
  let now = 0;
  let up = false;
  const heard = [], hearing = [], near = [];
  const phrases = new Phrases((c) => heard.push(c), () => now, (h) => hearing.push(h.command), 'v',
    { canStart: () => !up, onNearMiss: (n) => near.push(n) });
  phrases.message(interim('Let me start a whiteboard'));
  phrases.message(final('Let me start a whiteboard.'));
  phrases.message(pause);
  assert.deepEqual(heard, [{ id: 'v1', command: 'start a whiteboard.', direct: true }]);
  assert.deepEqual(hearing, ['start a whiteboard.']);
  assert.deepEqual(near, [{ text: 'Let me start a whiteboard.', started: true }]);
  // Said again soon after, as in that real call (21 s later): the first one is still being made.
  now = 21000;
  phrases.message(final('Let me start a whiteboard.'));
  phrases.message(pause);
  assert.equal(heard.length, 1);
  now = 60000;
  up = true;
  phrases.message(final('Let me start a whiteboard.'));
  phrases.message(pause);
  assert.equal(heard.length, 1);
  up = false;
  phrases.message(final('Start a whiteboard.'));
  phrases.message(pause);
  assert.equal(heard.length, 2);
});

test('an unnamed request taken while it was said still goes when it finishes, though hearing it put the board up', () => {
  let up = false;
  const heard = [];
  // As the driver does: hearing the request starts the share, and from then on a new request would not count.
  const phrases = new Phrases((c) => heard.push(c.command), Date.now, () => { up = true; }, 'v', { canStart: () => !up });
  phrases.message(interim('Let me start a whiteboard'));
  phrases.message(final('Let me start a whiteboard.'));
  phrases.message(pause);
  assert.deepEqual(heard, ['start a whiteboard.']);
  const later = [];
  const fresh = new Phrases((c) => later.push(c.command), Date.now, () => { up = true; }, 'v', { canStart: () => !up });
  up = true;
  fresh.message(final('Let me start a whiteboard.'));
  fresh.message(pause);
  assert.deepEqual(later, []);
});

test('an unnamed request heard only in passing, its words then dropped, leaves no request behind', () => {
  let up = false;
  const heard = [];
  const phrases = new Phrases((c) => heard.push(c.command), Date.now, () => {}, 'v', { canStart: () => !up });
  phrases.message(interim('Let me start a whiteboard'));
  phrases.message(pause);
  up = true;
  phrases.message(final('Let me start a whiteboard.'));
  phrases.message(pause);
  assert.deepEqual(heard, []);
});

test('a phrase that sounds like a board command with no name is a near miss; other talk is not', () => {
  assert.deepEqual(nearMiss('Please put the launch dates on a timeline.'), { text: 'Please put the launch dates on a timeline.', hint: true });
  assert.deepEqual(nearMiss('Add a risk: the review could slip.'), { text: 'Add a risk: the review could slip.', hint: true });
  assert.deepEqual(nearMiss('Let me start with the budget.'), { text: 'Let me start with the budget.', hint: false });
  assert.deepEqual(nearMiss('Her mess, add a goal.'), { text: 'Her mess, add a goal.', hint: true });
  assert.equal(nearMiss('The budget is fine.'), null);
  assert.equal(nearMiss(`Add ${'more words '.repeat(20)}`), null);
  const near = [], words = [];
  const phrases = new Phrases(() => {}, Date.now, () => {}, 'v', { onNearMiss: (n) => near.push(n), onWords: (w) => words.push(w) });
  phrases.message(interim('Please put the'));
  phrases.message(final('Please put the launch dates on a timeline.'));
  phrases.message(pause);
  phrases.message(final('Hey Hermes, put the launch dates on a timeline.'));
  phrases.message(pause);
  assert.deepEqual(near, [{ text: 'Please put the launch dates on a timeline.', hint: true }]);
  assert.deepEqual(words, ['Please put the', 'Please put the launch dates on a timeline.', 'Hey Hermes, put the launch dates on a timeline.']);
});

test('a command with the bare name sends nothing and shows nothing on the board, only the hint', () => {
  for (const up of [false, true]) {
    const heard = [], hearing = [], near = [];
    const phrases = new Phrases((c) => heard.push(c), Date.now, (h) => hearing.push(h), 'v',
      { canStart: () => !up, onNearMiss: (n) => near.push(n) });
    for (const line of ['Hermes, add a goal: ten paying pilots by March.', 'Hermes, put the launch dates on a timeline.', ...TALK]) {
      phrases.message(interim(line));
      phrases.message(final(line));
      phrases.message(pause);
    }
    assert.deepEqual(heard, []);
    assert.deepEqual(hearing, []);
    assert.deepEqual(near, [{ text: 'Hermes, add a goal: ten paying pilots by March.', hint: true },
      { text: 'Hermes, put the launch dates on a timeline.', hint: true }]);
  }
});

test('a clipped "Hey Hermes, start a whiteboard" starts a board only while none is up, like any unnamed start', () => {
  // As Deepgram wrote "Hey Hermes, start a whiteboard" with its first 150 to 220 ms cut (2026-11-22).
  for (const heard of ['Hermes, start a whiteboard.', 'Hermes start a whiteboard.'])
    assert.equal(startRequest(heard), 'start a whiteboard.', heard);
  assert.equal(startRequest('Hermes, start a board for the launch.'), 'start a board for the launch.');
  for (const talk of ['Can Hermes start a board for the launch?', 'Hermes starts a board on its own.',
    "Acme's Hermes, start a whiteboard.", 'Hermes, start a board meeting tomorrow.']) assert.equal(startRequest(talk), null, talk);
  for (const up of [false, true]) {
    const heard = [], near = [];
    const phrases = new Phrases((c) => heard.push(c.command), Date.now, () => {}, 'v',
      { canStart: () => !up, onNearMiss: (n) => near.push(n) });
    phrases.message(final('Hermes, start a whiteboard.'));
    phrases.message(pause);
    assert.deepEqual(heard, up ? [] : ['start a whiteboard.']);
    assert.deepEqual(near, [{ text: 'Hermes, start a whiteboard.', ...(up ? { hint: true } : { started: true }) }]);
  }
});

const final = (transcript) => ({ type: 'Results', is_final: true, channel: { alternatives: [{ transcript }] } });
const interim = (transcript) => ({ ...final(transcript), is_final: false });
const pause = { type: 'UtteranceEnd' };

test('the final words up to a pause make one phrase', () => {
  const heard = [];
  const phrases = new Phrases((c) => heard.push(c.command));
  phrases.message(interim('Hey Hermes put the'));
  phrases.message(final('Hey Hermes, put the launch dates'));
  phrases.message(final('on a timeline.'));
  assert.deepEqual(heard, []);
  phrases.message(pause);
  assert.deepEqual(heard, ['put the launch dates on a timeline.']);
  phrases.message(final('And then we ship it.'));
  phrases.message(pause);
  assert.equal(heard.length, 1);
});

test('a bare "Hey Hermes" takes the next phrase as its command, for a short while', () => {
  let now = 0;
  const heard = [];
  const phrases = new Phrases((c) => heard.push(c), () => now);
  phrases.message(final('Hey Hermes?'));
  phrases.message(pause);
  now = 3000;
  phrases.message(final('Add Kim to the owners.'));
  phrases.message(pause);
  assert.deepEqual(heard, [{ id: 'v1', command: 'Add Kim to the owners.', direct: true }]);
  phrases.message(final('Hey Hermes.'));
  phrases.message(pause);
  now = 30000;
  phrases.message(final('Anyway, moving on.'));
  phrases.message(pause);
  assert.equal(heard.length, 1);
});

// What Deepgram sent for "Hey Hermes, add an action item: Lee will hire a contract designer, <pause> and it is due Friday,
// December 5th." (a rehearsal call, 2026-11-21): two sentences, and the second has no name.
test('a phrase soon after a command that gives its due date carries the command on, with the id of the command', () => {
  let now = 0;
  const heard = [];
  const hearing = [];
  const phrases = new Phrases((c) => heard.push(c), () => now, (h) => hearing.push(h));
  phrases.message(final('Hey Hermes. Add an action item. Lee will hire a contract designer.'));
  phrases.message({ ...pause });
  assert.deepEqual(heard, [{ id: 'v1', command: 'Add an action item. Lee will hire a contract designer.', direct: true }]);
  now = 1800;
  phrases.message(interim('And it is due'));
  assert.deepEqual(hearing.at(-1), { id: 'v2', command: 'And it is due' });
  now = 3200;
  phrases.message({ ...final('And it is due Friday, December 5.'), speech_final: true });
  assert.deepEqual(heard[1], { id: 'v2', command: 'And it is due Friday, December 5.', direct: true, continues: 'v1' });
  assert.equal(heard.length, 2);
});

test('a phrase that is not about a date, an owner or a level, or comes late, or is a question, is not carried on', () => {
  let now = 0;
  const heard = [];
  const phrases = new Phrases((c) => heard.push(c), () => now);
  const say = (text, at) => {
    now = at;
    phrases.message(final(text));
    phrases.message(pause);
  };
  say('Hey Hermes, add a risk: we only have one designer.', 0);
  say('Yeah, I can do that.', 1500);
  say('Is that due Friday?', 2500);
  say('Due Friday, and then we will see how the week goes, and what Lee says about it, and what the budget allows for it.', 3500);
  say('For marketing, remove the launch task.', 4000);
  say('Low-hanging fruit first, and remove the pricing row.', 4500);
  assert.equal(heard.length, 1);
  say('Due Friday, December 5.', 12000);
  assert.equal(heard.length, 1);
  // Soon after the command, the same words carry it on.
  say('Hey Hermes, add a risk: the Stripe review could slip.', 20000);
  say('Due Friday, December 5.', 22000);
  assert.deepEqual(heard.map((c) => c.continues), [undefined, undefined, 'v2']);
});

test('which short phrases carry a command on: a due date, an owner or a level, and not a word that only starts like one', () => {
  const phrases = new Phrases(() => {}, () => 0);
  phrases.last = { id: 'v1', at: 0, n: 0 };
  const carries = ['Due Friday.', 'And it is due Friday, December 5th.', 'Owner is Lee.', 'High priority.', 'Low risk.', 'And it is high.',
    'By Friday.', 'Before the 15th.', 'By 5 pm.', 'By the end of March.', 'Until next week.', 'By December 5th.'];
  const not = ['For marketing, remove the launch task.', 'By marketing we mean the whole funnel.', 'On Friday we ship.',
    'For 3 people, remove the row.', 'Before we go on, delete the risk.', 'Low-hanging fruit first.', 'By friends of the team.'];
  for (const text of carries) assert.ok(phrases.continues(text), text);
  for (const text of not) assert.ok(!phrases.continues(text), text);
});

test('a command carried on three times is as far as it goes, and a new command starts over', () => {
  let now = 0;
  const heard = [];
  const phrases = new Phrases((c) => heard.push(c), () => now);
  const say = (text, at) => {
    now = at;
    phrases.message(final(text));
    phrases.message(pause);
  };
  say('Hey Hermes, add an action item: hire a designer.', 0);
  say('Owner is Lee.', 1500);
  say('Due Friday.', 3000);
  say('High priority.', 4500);
  say('Low priority.', 6000);
  assert.deepEqual(heard.map((c) => [c.id, c.continues]), [['v1', undefined], ['v2', 'v1'], ['v3', 'v1'], ['v4', 'v1']]);
  say('Hey Hermes, add a goal: ten pilots.', 7000);
  say('By the end of March.', 8500);
  assert.deepEqual(heard.at(-1), { id: 'v6', command: 'By the end of March.', direct: true, continues: 'v5' });
});

test('words said after a stream dropped do not carry on a command from before it', () => {
  let now = 0;
  const heard = [];
  const phrases = new Phrases((c) => heard.push(c), () => now);
  phrases.message(final('Hey Hermes, add an action item: hire a designer.'));
  phrases.message(pause);
  phrases.reset();
  now = 1000;
  phrases.message(final('Due Friday.'));
  phrases.message(pause);
  assert.equal(heard.length, 1);
});

test('a phrase that never pauses is cut so a command is not held back', () => {
  let now = 0;
  const heard = [];
  const phrases = new Phrases((c) => heard.push(c.command), () => now);
  phrases.message(final('Hey Hermes, start a whiteboard for hiring.'));
  now = 31000;
  phrases.message(final('And more talk.'));
  assert.deepEqual(heard, ['start a whiteboard for hiring. And more talk.']);
});

const spoken = (transcript) => ({ ...final(transcript), speech_final: true });

test('a command ends at the first short silence, without waiting for the utterance to end', () => {
  const heard = [];
  const phrases = new Phrases((c) => heard.push(c));
  phrases.message(final('Hey Hermes, stop sharing'));
  assert.deepEqual(heard, []);
  phrases.message(spoken('the board.'));
  assert.deepEqual(heard, [{ id: 'v1', command: 'stop sharing the board.', direct: true }]);
  phrases.message(spoken('Hey Hermes, add Kim to the owners.'));
  assert.deepEqual(heard.map((c) => c.id), ['v1', 'v2']);
});

test('a command that sounds unfinished at a short silence waits for its words, up to the utterance end', () => {
  const heard = [];
  const phrases = new Phrases((c) => heard.push(c.command));
  phrases.message(spoken('Hey Hermes, add a column for'));
  phrases.message(spoken('risks.'));
  phrases.message(spoken('Hey Hermes, add'));
  assert.deepEqual(heard, ['add a column for risks.']);
  phrases.message(pause);
  assert.deepEqual(heard, ['add a column for risks.']);
});

test('a command still unfinished when the utterance ends waits a few seconds for its words, then goes as it was', () => {
  let t = 0;
  const heard = [];
  const phrases = new Phrases((c) => heard.push(c.command), () => t);
  phrases.message(spoken('Hey Hermes, add'));
  phrases.message(pause);
  t = 3900;
  phrases.tick();
  assert.deepEqual(heard, []);
  t = 4000;
  phrases.tick();
  assert.deepEqual(heard, ['add']);
  // A new command in that time sends the held one first, as it was.
  phrases.message(spoken('Hey Hermes, add a risk:'));
  phrases.message(pause);
  t = 5000;
  phrases.message(spoken('Hey Hermes, undo.'));
  assert.deepEqual(heard, ['add', 'add a risk:', 'undo.']);
  // Words heard only for a moment, which Deepgram then drops, do not keep it waiting.
  phrases.message(spoken('Hey Hermes, add a risk:'));
  phrases.message(pause);
  phrases.message(interim('um'));
  phrases.message(final(''));
  phrases.message(pause);
  t = 9000;
  phrases.tick();
  assert.deepEqual(heard, ['add', 'add a risk:', 'undo.', 'add a risk:']);
});

test('a word Deepgram drops before a pause does not cut the command off there', () => {
  // Deepgram's answers in a live rehearsal call and a replay of its audio (2026-11-21): "risk" never came back, so the
  // utterance ended at the pause after it, and the risk reached the board as "New high risk".
  let t = 0;
  const heard = [], hearing = [];
  const phrases = new Phrases((c) => heard.push(c), () => t, (h) => hearing.push(h.command));
  phrases.message(spoken('So anything new lands on her desk late.'));
  phrases.message(pause);
  t = 2000;
  phrases.message(interim('Hey Hermes, add a high'));
  phrases.message({ ...final('Hey Hermes, add a high'), from_finalize: true });
  t = 3000;
  phrases.message(interim('we all'));
  phrases.message(pause);
  assert.deepEqual(heard, []);
  t = 4000;
  phrases.message(interim('we only have one design'));
  phrases.tick();
  t = 7000;
  phrases.tick();
  assert.deepEqual(heard, []);
  phrases.message(spoken('we only have one designer, and she is booked through January.'));
  assert.deepEqual(heard, [{ id: 'v1', command: 'add a high we only have one designer, and she is booked through January.',
    direct: true }]);
  assert.deepEqual(hearing.slice(-1), ['add a high we only have one designer, and she is booked through January.']);
});

test('the words of a command are passed on as they are heard, with the id the command will have', () => {
  const heard = [], hearing = [];
  const phrases = new Phrases((c) => heard.push(c), Date.now, (h) => hearing.push(h));
  phrases.message(interim('So anyway'));
  phrases.message(interim('Hey Hermes, put the'));
  phrases.message(interim('Hey Hermes, put the'));
  phrases.message(final('Hey Hermes, put the launch dates'));
  phrases.message(interim('on a'));
  phrases.message(spoken('on a timeline.'));
  phrases.message(interim('Hey Hermes, stop'));
  assert.deepEqual(hearing, [{ id: 'v1', command: 'put the' }, { id: 'v1', command: 'put the launch dates' },
    { id: 'v1', command: 'put the launch dates on a' }, { id: 'v1', command: 'put the launch dates on a timeline.' },
    { id: 'v2', command: 'stop' }]);
  assert.deepEqual(heard, [{ id: 'v1', command: 'put the launch dates on a timeline.', direct: true }]);
});

test('talk that runs straight into a command without a pause still gives the command', () => {
  // Deepgram's answers in a replay of that rehearsal call's audio through this code (2026-11-21).
  const heard = [], hearing = [];
  const phrases = new Phrases((c) => heard.push(c), Date.now, (h) => hearing.push(h.command));
  phrases.message(final('The thing that worries me most is design.'));
  phrases.message(final('We only have one designer, and she is already booked'));
  phrases.message(final('solid through the end of January. So anything new lands on her desk late,'));
  phrases.message(interim('Hey Hermes, at a high risk.'));
  phrases.message(final('Hey Hermes, at a high risk, we only have one designer.'));
  phrases.message(interim('And she is booked through'));
  phrases.message(spoken('And she is booked through January.'));
  assert.equal(hearing[0], 'at a high risk.');
  assert.deepEqual(heard, [{ id: 'v1', command: 'at a high risk, we only have one designer. And she is booked through January.',
    direct: true }]);
});

test('a command also ends when Deepgram finishes the words it has, as asked at a pause', () => {
  const heard = [];
  const phrases = new Phrases((c) => heard.push(c.command));
  phrases.message(interim('Hey Hermes, add a goal, 10 paying pilots'));
  assert.equal(phrases.pending(), true);
  phrases.message({ ...final('Hey Hermes, add a goal, 10 paying pilots by March.'), from_finalize: true });
  assert.deepEqual(heard, ['add a goal, 10 paying pilots by March.']);
  assert.equal(phrases.pending(), false);
  phrases.message({ ...final('Hey Hermes, at a risk.'), from_finalize: true });
  assert.equal(heard.length, 1, '"add a risk" heard as "at a risk" waits for the rest at a pause');
  phrases.message({ ...final('We only have one designer.'), from_finalize: true });
  assert.deepEqual(heard.at(-1), 'at a risk. We only have one designer.');
  phrases.message({ ...final('Hey Hermes, add a'), from_finalize: true });
  assert.deepEqual(heard, ['add a goal, 10 paying pilots by March.', 'at a risk. We only have one designer.']);
  assert.equal(phrases.pending(), true);
});

// 16 kHz 16-bit audio at an RMS of `level`, `ms` long.
const sound = (ms, level) => {
  const buf = Buffer.alloc(ms * 32);
  for (let i = 0; i < buf.length; i += 2) buf.writeInt16LE(i % 4 ? -level : level, i);
  return buf;
};

test('a pause is measured from the audio, only after someone has spoken', () => {
  const pause = new Pause();
  assert.equal(pause.add(sound(500, 0)), 0);
  assert.equal(pause.add(sound(100, 5000)), 0);
  assert.equal(pause.add(sound(200, 20)), 200);
  assert.equal(pause.add(sound(300, 300)), 500);
  assert.equal(pause.add(sound(100, 2000)), 0);
  const soft = new Pause();
  soft.add(sound(100, 500));
  assert.equal(soft.add(sound(100, 300)), 0, 'a soft speaker is measured against their own voice');
  assert.equal(soft.add(sound(100, 40)), 100);
  const split = new Pause();
  split.add(sound(100, 3000));
  const quiet = sound(100, 0);
  assert.equal(split.add(quiet.subarray(0, 1601)), 50);
  assert.equal(split.add(quiet.subarray(1601)), 100, 'a chunk that ends mid-sample is read with the next one');
});

// A stand-in WebSocket and audio capture, so the stream's rules run without Deepgram or Pulse.
class FakeSocket {
  constructor(url, protocols) {
    Object.assign(this, { url, protocols, readyState: 0, bufferedAmount: 0, sent: [], closed: false });
  }

  send(data) {
    this.sent.push(data);
  }

  close() {
    this.closed = true;
    this.readyState = 3;
  }

  open() {
    this.readyState = 1;
    this.onopen?.();
  }

  drop(code = 1006) {
    this.readyState = 3;
    this.onclose?.({ code, reason: '' });
  }
}

function rig(options = {}) {
  let now = 0;
  const sockets = [], captures = [], heard = [];
  const voice = new Voice({
    key: 'test-key', log: () => {}, now: () => now, onCommand: (c) => heard.push(c.command), ...options,
    connect: (url, protocols) => sockets.at(sockets.push(new FakeSocket(url, protocols)) - 1),
    capture: () => {
      const audio = Object.assign(new EventEmitter(), { stdout: new EventEmitter(), exitCode: null });
      audio.kill = () => { audio.exitCode = 0; };
      return captures.at(captures.push(audio) - 1);
    },
  });
  return { voice, sockets, captures, heard, at: (ms) => { now = ms; } };
}

test("the stream opts out of Deepgram's model improvement program, so the call's audio is not kept", () => {
  assert.equal(new globalThis.URL(URL).searchParams.get('mip_opt_out'), 'true');
  const { voice, sockets } = rig();
  voice.update({ inCall: true, alone: false });
  assert.equal(new globalThis.URL(sockets[0].url).searchParams.get('mip_opt_out'), 'true');
});

test('the stream runs only in a call with someone else, and the key goes only in the protocol header', () => {
  const { voice, sockets, captures } = rig();
  voice.update({ inCall: false });
  voice.update({ inCall: true, alone: true });
  assert.equal(sockets.length, 0);
  voice.update({ inCall: true, alone: false });
  assert.equal(sockets.length, 1);
  assert.deepEqual(sockets[0].protocols, ['token', 'test-key']);
  assert.equal(sockets[0].url, URL);
  assert.ok(!URL.includes('test-key'));
  sockets[0].open();
  assert.equal(voice.status().state, 'listening');
  captures[0].stdout.emit('data', Buffer.alloc(32000));
  assert.equal(voice.status().streamed_seconds, 1);
  voice.update({ inCall: true, alone: true });
  assert.ok(sockets[0].closed && captures[0].exitCode !== null);
  assert.equal(voice.status().state, 'paused');
  voice.update({ inCall: true, alone: false });
  assert.equal(sockets.length, 2);
});

test('the stream stays open while the call is out of sight for a moment, as when a tip covers it, and not for long', () => {
  const { voice, sockets, captures, at } = rig();
  voice.update({ inCall: true, alone: false });
  sockets[0].open();
  at(1000);
  voice.update({ inCall: false });
  at(AWAY_MS);
  voice.update({ inCall: false });
  assert.ok(!sockets[0].closed);
  assert.equal(voice.status().state, 'listening');
  captures[0].stdout.emit('data', Buffer.alloc(32000));
  assert.equal(voice.status().streamed_seconds, 1);
  voice.update({ inCall: true, alone: false });
  at(AWAY_MS + 2000);
  voice.update({ inCall: false });
  at(2 * AWAY_MS + 1999);
  voice.update({ inCall: false });
  assert.ok(!sockets[0].closed);
  at(2 * AWAY_MS + 2000);
  voice.update({ inCall: false });
  assert.ok(sockets[0].closed);
  assert.equal(voice.status().state, 'paused');
  assert.equal(sockets.length, 1);
  voice.update({ inCall: true, alone: false });
  assert.equal(sockets.length, 2);
});

test('out of sight, a stream that is not open is not opened, nor one that dropped opened again', () => {
  const { voice, sockets, at } = rig();
  voice.update({ inCall: false });
  assert.equal(sockets.length, 0);
  voice.update({ inCall: true, alone: false });
  sockets[0].open();
  voice.update({ inCall: false });
  sockets[0].drop();
  at(600000);
  voice.update({ inCall: false });
  assert.equal(sockets.length, 1);
  voice.update({ inCall: true, alone: false });
  assert.equal(sockets.length, 2);
});

test('audio sent before the stream opens is dropped, not billed', () => {
  const { voice, sockets, captures } = rig();
  voice.update({ inCall: true, alone: false });
  captures[0].stdout.emit('data', Buffer.alloc(32000));
  assert.equal(sockets[0].sent.length, 0);
  assert.equal(voice.status().streamed_seconds, 0);
});

test('a dropped stream is retried with waits, then given up for the call', () => {
  const { voice, sockets, at } = rig();
  voice.update({ inCall: true, alone: false });
  sockets[0].drop();
  assert.equal(voice.status().state, 'retrying');
  voice.update({ inCall: true, alone: false });
  assert.equal(sockets.length, 1);
  at(5000);
  voice.update({ inCall: true, alone: false });
  assert.equal(sockets.length, 2);
  // A stream that answers and soon drops again still counts toward giving up.
  let t = 5000;
  for (const wait of [15000, 30000, 60000, 0]) {
    sockets.at(-1).open();
    sockets.at(-1).onmessage({ data: JSON.stringify({ type: 'Metadata' }) });
    sockets.at(-1).drop();
    t += wait;
    at(t);
    voice.update({ inCall: true, alone: false });
  }
  assert.equal(voice.status().state, 'failed');
  const count = sockets.length;
  at(t + 600000);
  voice.update({ inCall: true, alone: false });
  assert.equal(sockets.length, count);
});

test('a refused handshake, which Node reports only as an error, counts as a failure', () => {
  const { voice, sockets } = rig();
  voice.update({ inCall: true, alone: false });
  sockets[0].onerror({});
  assert.equal(voice.status().state, 'retrying');
  assert.equal(voice.status().error, 'Deepgram refused or dropped the stream');
  assert.ok(sockets[0].closed);
});

test('a stream that never opens is counted as failed', () => {
  const { voice, sockets, at } = rig();
  voice.update({ inCall: true, alone: false });
  at(10000);
  voice.update({ inCall: true, alone: false });
  assert.equal(voice.status().state, 'connecting');
  at(16000);
  voice.update({ inCall: true, alone: false });
  assert.equal(voice.status().state, 'retrying');
  assert.ok(sockets[0].closed);
});

test('the stream stops for good at the per-call limit and at the end of the call', () => {
  const { voice, sockets, captures } = rig({ maxSeconds: 2 });
  voice.update({ inCall: true, alone: false });
  sockets[0].open();
  captures[0].stdout.emit('data', Buffer.alloc(64000));
  voice.update({ inCall: true, alone: false });
  assert.equal(voice.status().state, 'capped');
  assert.ok(sockets[0].sent.some((m) => m === JSON.stringify({ type: 'CloseStream' })));
  voice.update({ inCall: true, alone: false });
  assert.equal(sockets.length, 1);

  const other = rig();
  other.voice.update({ inCall: true, alone: false });
  other.voice.stop();
  other.voice.update({ inCall: true, alone: false });
  assert.equal(other.voice.status().state, 'stopped');
  assert.equal(other.sockets.length, 1);
});

test('commands come from what the stream hears, and a broken message is skipped', () => {
  const { voice, sockets, heard } = rig();
  voice.update({ inCall: true, alone: false });
  sockets[0].open();
  sockets[0].onmessage({ data: 'not json' });
  sockets[0].onmessage({ data: JSON.stringify(final('Hey Hermes, add a risks column.')) });
  sockets[0].onmessage({ data: JSON.stringify(pause) });
  assert.deepEqual(heard, ['add a risks column.']);
});

test('a pause in a command asks Deepgram once to finish its words, and only in a command', () => {
  const { voice, sockets, captures } = rig();
  voice.update({ inCall: true, alone: false });
  sockets[0].open();
  const play = (ms, level) => captures[0].stdout.emit('data', sound(ms, level));
  const finishes = () => sockets[0].sent.filter((m) => m === '{"type":"Finalize"}').length;
  play(1000, 3000);
  play(1000, 0);
  assert.equal(finishes(), 0, 'talk that is not a command');
  sockets[0].onmessage({ data: JSON.stringify(interim('Hey Hermes, add a goal')) });
  play(500, 3000);
  play(500, 0);
  assert.equal(finishes(), 0, 'too short a pause');
  play(200, 0);
  play(1000, 0);
  assert.equal(finishes(), 1);
  play(100, 3000);
  play(700, 0);
  assert.equal(finishes(), 2, 'more words, then another pause');
});

test('with no key the bot never streams', () => {
  const { voice, sockets } = rig({ key: undefined });
  voice.update({ inCall: true, alone: false });
  assert.equal(sockets.length, 0);
  assert.deepEqual(voice.status(), { state: 'off', error: 'no Deepgram key', streamed_seconds: 0 });
});

test('a bot process that starts over gives its commands new ids, so the board room takes each one', () => {
  const ids = [0, 90000].map((start) => {
    const heard = [];
    const { voice } = rig({ now: () => start, onCommand: (c) => heard.push(c.id) });
    voice.phrases.message(spoken('Hey Hermes, add Kim to the owners.'));
    voice.phrases.message(spoken('Hey Hermes, stop sharing.'));
    return heard;
  });
  assert.equal(new Set(ids.flat()).size, 4);
});

test('a stream that answers for a minute counts as working again, and the count of drops starts over', () => {
  const { voice, sockets, at } = rig();
  voice.update({ inCall: true, alone: false });
  sockets[0].drop();
  at(5000);
  voice.update({ inCall: true, alone: false });
  sockets[1].open();
  at(65000);
  sockets[1].onmessage({ data: JSON.stringify({ type: 'Metadata' }) });
  sockets[1].drop();
  // The first wait again (5 s), not the second (15 s).
  at(70000);
  voice.update({ inCall: true, alone: false });
  assert.equal(sockets.length, 3);
});

test('an open stream sent sound that answers nothing for 15 seconds counts as dropped; quiet with no answer does not', () => {
  const { voice, sockets, captures, at } = rig();
  voice.update({ inCall: true, alone: false });
  sockets[0].open();
  captures[0].stdout.emit('data', sound(1000, 0));
  at(30000);
  voice.update({ inCall: true, alone: false });
  assert.equal(voice.status().state, 'listening');
  captures[0].stdout.emit('data', sound(1000, 3000));
  at(40000);
  voice.update({ inCall: true, alone: false });
  assert.equal(voice.status().state, 'listening');
  sockets[0].onmessage({ data: JSON.stringify(interim('')) });
  captures[0].stdout.emit('data', sound(1000, 3000));
  at(56000);
  voice.update({ inCall: true, alone: false });
  assert.deepEqual([voice.status().state, voice.status().error], ['retrying', 'Deepgram stopped answering']);
  assert.ok(sockets[0].closed);
});

test('the board is told when spoken commands cannot be heard, and when they can again', () => {
  const told = [];
  const { voice, sockets, at } = rig({ onListening: (on) => told.push(on) });
  assert.equal(voice.listening(), true);
  voice.update({ inCall: true, alone: false });
  sockets[0].open();
  sockets[0].drop();
  at(5000);
  voice.update({ inCall: true, alone: false });
  assert.equal(voice.listening(), false, 'trying again is not listening yet');
  sockets[1].open();
  assert.deepEqual(told, [false, true]);
  const capped = rig({ maxSeconds: 0, onListening: (on) => told.push(on) });
  capped.voice.update({ inCall: true, alone: false });
  assert.deepEqual([capped.voice.status().state, told.at(-1)], ['capped', false]);
  assert.equal(rig({ key: undefined }).voice.listening(), false);
});

test('words of a command half heard as the stream drops are forgotten, not joined to what the next stream hears', () => {
  const { voice, sockets, heard, at } = rig();
  voice.update({ inCall: true, alone: false });
  sockets[0].open();
  sockets[0].onmessage({ data: JSON.stringify(final('Hey Hermes, add Kim to the')) });
  sockets[0].drop();
  at(5000);
  voice.update({ inCall: true, alone: false });
  sockets[1].open();
  sockets[1].onmessage({ data: JSON.stringify(final('So anyway, the numbers look fine.')) });
  sockets[1].onmessage({ data: JSON.stringify(pause) });
  assert.deepEqual(heard, []);
});
