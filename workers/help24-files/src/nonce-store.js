// One-time links, made strictly one-time.
//
// Each link's nonce gets its own Durable Object. A Durable Object processes
// its calls one at a time against strongly consistent storage, so of two
// requests racing with the same link — from the same browser or from opposite
// sides of the world — exactly one is told "first". (Workers KV, used before,
// is eventually consistent and capped at 1,000 writes a day on the free plan:
// one user opening links in a loop could have exhausted it for everyone.)
//
// Only a link whose signature, document and expiry have already been checked
// ever reaches here, so nobody can make it remember nonces of their own
// invention. The object deletes itself a few minutes after the link expired.

import { DurableObject } from 'cloudflare:workers';

/** Storage is wiped this long after a burn — well past the link's 2 minutes. */
const FORGET_AFTER_MS = 10 * 60 * 1000;

export class LinkNonce extends DurableObject {
  /** true the first time this nonce is burnt, false ever after. */
  async burn() {
    if (await this.ctx.storage.get('burnt')) return false;
    await this.ctx.storage.put('burnt', true);
    await this.ctx.storage.setAlarm(Date.now() + FORGET_AFTER_MS);
    return true;
  }

  async alarm() {
    await this.ctx.storage.deleteAll();
  }
}

/** The app's `nonces` dependency, backed by the LINK_NONCES namespace. */
export function durableNonces(namespace) {
  return {
    burn: (nonce) => namespace.get(namespace.idFromName(`link:${nonce}`)).burn(),
  };
}
