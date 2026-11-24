// A short link to a call's board, typed from the shared screen: one object per code (src/links.js) holds the token of the
// room it stands for, and forgets it after a day and a half, well after the call is over. /j/<code> (src/index.js) asks
// the room and signs an editor's link on the way, so it only ever opens what the board link opens, and ending the call
// or turning the link off ends it too.
import { DurableObject } from 'cloudflare:workers';

const LIFETIME_MS = 36 * 3600 * 1000;

export class ShortLink extends DurableObject {
  async fetch(request) {
    if (request.method === 'PUT') {
      const { token } = await request.json().catch(() => ({}));
      if (!/^[0-9a-f]{32}$/.test(token || '')) return new Response('bad token', { status: 400 });
      const held = await this.ctx.storage.get('token');
      if (held && held !== token) return new Response('taken', { status: 409 });
      await this.ctx.storage.put('token', token);
      await this.ctx.storage.setAlarm(Date.now() + LIFETIME_MS);
      return Response.json({ ok: true });
    }
    return Response.json({ token: (await this.ctx.storage.get('token')) || null });
  }

  async alarm() {
    await this.ctx.storage.deleteAll();
  }
}
