// What the bot's camera tile says (tile.mjs). Run with `node --test`.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { CAPTION_MS, HINT_MS, Tile } from './tile.mjs';

const rig = () => {
  let now = 0;
  const shown = [];
  const tile = new Tile((view) => shown.push(view), () => now);
  return { tile, shown, at: (ms) => { now = ms; }, last: () => shown.at(-1) };
};

test('the tile says it is getting ready until the notice is up, then that Hermes is listening and what to say', () => {
  const { tile, last } = rig();
  tile.update();
  assert.equal(last().title, 'Getting ready');
  tile.ready();
  assert.deepEqual(last(), { tone: 'listening', title: 'Listening', lead: 'Say', say: 'Hey Hermes, start a whiteboard',
    caption: '', board: false });
});

test('the words heard show as they come, and go a few seconds after they stop', () => {
  const { tile, last, at } = rig();
  tile.ready();
  tile.words('Let me start a');
  assert.equal(last().caption, 'Let me start a');
  at(CAPTION_MS - 1);
  tile.update();
  assert.equal(last().caption, 'Let me start a');
  at(CAPTION_MS);
  tile.update();
  assert.equal(last().caption, '');
  tile.words('x'.repeat(200));
  assert.equal(last().caption.length, 141);
  assert.ok(last().caption.startsWith('…'));
});

test('a near miss asks for the name for a while; an unnamed board start says it is starting one', () => {
  const { tile, last, at } = rig();
  tile.ready();
  tile.nearMiss({ text: 'Let me start with the budget.', hint: false });
  assert.equal(last().say, 'Hey Hermes, start a whiteboard');
  tile.nearMiss({ text: 'Please put the dates on a timeline.', hint: true });
  assert.deepEqual([last().lead, last().say], ['Start with', 'Hey Hermes']);
  at(HINT_MS);
  tile.update();
  assert.equal(last().say, 'Hey Hermes, start a whiteboard');
  tile.nearMiss({ text: 'Let me start a whiteboard.', started: true });
  assert.equal(last().title, 'Starting a board');
  assert.deepEqual([last().lead, last().say], ['Next time, start with', 'Hey Hermes']);
});

test('beside a board the tile only says Hermes is listening and the name to say, since the board shows the rest', () => {
  const { tile, last } = rig();
  tile.ready();
  tile.board(true);
  tile.words('Hermes, add a goal');
  assert.deepEqual(last(), { tone: 'listening', title: 'Listening', lead: 'Say', say: 'Hey Hermes', caption: '', board: true });
  tile.nearMiss({ text: 'Please add a goal.', hint: true });
  assert.deepEqual([last().lead, last().say], ['Start with', 'Hey Hermes']);
});

test('the tile says when Hermes is not listening, and sends nothing when nothing changed', () => {
  const { tile, shown, last } = rig();
  tile.ready();
  tile.listening(false);
  assert.equal(last().title, 'Not listening');
  assert.deepEqual([last().lead, last().say], ['Type in the chat', 'Hermes, start a whiteboard']);
  tile.board(true);
  assert.equal(last().say, 'Hermes, add a goal …');
  const count = shown.length;
  tile.update();
  tile.listening(false);
  assert.equal(shown.length, count);
});
