// Ways into a call's board room. The room is named by a random token, but the token alone opens nothing: every way in
// is a key this Worker signed when its authenticated API made the room for a call. So a link nobody was given is turned
// away by one HMAC in the Worker, before any Durable Object is reached, and a room exists only for a call the Worker
// started.
//
// A link's key is one run of hex, so Cloudflare's log redaction hides it in any URL it logs:
//   token (32) | scope (1) | version (4) | expires (8, unix seconds) | signature (32: HMAC-SHA-256 cut to 128 bits)
// The scope is what the link may do. The version is the room's link version when it was made: turning the link off,
// or making a new one, moves the room on, and older keys stop working (src/room.js).
export const SCOPES = { e: 'editor', a: 'watcher', c: 'screen' };
const LINK = /^([0-9a-f]{32})([eac])([0-9a-f]{4})([0-9a-f]{8})([0-9a-f]{32})$/;
export const TOKEN = /^[0-9a-f]{32}$/;

const encoder = new TextEncoder();
const keys = new Map();

export const hex = (bytes) => [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, '0')).join('');

// Equal strings, compared in time that does not depend on where they differ.
export function same(given, want) {
  if (!want || typeof given !== 'string' || given.length !== want.length) return false;
  let diff = 0;
  for (let i = 0; i < want.length; i++) diff |= given.charCodeAt(i) ^ want.charCodeAt(i);
  return diff === 0;
}

async function mac(secret, text) {
  let key = keys.get(secret);
  if (!key) {
    key = await crypto.subtle.importKey('raw', encoder.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
    keys.set(secret, key);
  }
  return hex(await crypto.subtle.sign('HMAC', key, encoder.encode(text)));
}

// The key the bot's own browser driver shows to join its room as the bot.
export const botKey = (secret, token) => mac(secret, `room:${token}`);

export async function sign(secret, { token, scope, version, expires }) {
  const body = `${token}${scope}${version.toString(16).padStart(4, '0')}${expires.toString(16).padStart(8, '0')}`;
  return body + (await mac(secret, `link:${body}`)).slice(0, 32);
}

// What a link's key lets in: { token, role, version, expires }, or null for a key this Worker did not sign or that has
// expired.
export async function verify(secret, given, now = Date.now()) {
  const found = LINK.exec(typeof given === 'string' ? given : '');
  if (!found || !secret) return null;
  const [, token, scope, version, expires, signature] = found;
  if (parseInt(expires, 16) * 1000 <= now) return null;
  const want = (await mac(secret, `link:${token}${scope}${version}${expires}`)).slice(0, 32);
  if (!same(signature, want)) return null;
  return { token, role: SCOPES[scope], version: parseInt(version, 16), expires: parseInt(expires, 16) };
}

// A short link's code (/j/<code>), for typing from the shared screen: 6 random letters and digits that are hard to mix
// up, then 4 this Worker signed, so a made-up code is turned away by one HMAC, like a made-up link, before any Durable
// Object is reached. Shown as two groups of five; the dash is optional.
const ALPHABET = 'abcdefghjkmnpqrstuvwxyz23456789';
export const SHORT = /^[a-hj-km-np-z2-9]{5}-?[a-hj-km-np-z2-9]{5}$/i;

async function shortTail(secret, head) {
  const signed = await mac(secret, `short:${head}`);
  return [0, 1, 2, 3].map((i) => ALPHABET[parseInt(signed.slice(2 * i, 2 * i + 2), 16) % ALPHABET.length]).join('');
}

export async function newShort(secret) {
  const head = [...crypto.getRandomValues(new Uint8Array(6))].map((b) => ALPHABET[b % ALPHABET.length]).join('');
  return head + await shortTail(secret, head);
}

// The code as stored (lower case, no dash), or null for one this Worker did not make.
export async function checkShort(secret, given) {
  if (!secret || !SHORT.test(typeof given === 'string' ? given : '')) return null;
  const code = given.toLowerCase().replace('-', '');
  return same(code.slice(6), await shortTail(secret, code.slice(0, 6))) ? code : null;
}

// Who is asking, as a room counts them for its limits: an IPv4 address, or an IPv6 /64 (one home or phone), written the
// same way however the address was shortened.
export function address(ip) {
  const text = String(ip || '').toLowerCase();
  if (!text.includes(':')) return text;
  const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/.exec(text);
  if (mapped) return mapped[1];
  const [head, tail] = text.split('::');
  const part = (words) => (words ? words.split(':') : []);
  const front = part(head);
  const back = part(tail);
  const groups = [...front, ...Array(Math.max(0, 8 - front.length - back.length)).fill('0'), ...back];
  return groups.slice(0, 4).map((group) => (parseInt(group, 16) || 0).toString(16)).join(':');
}
