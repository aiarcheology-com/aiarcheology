import { SELF, env } from 'cloudflare:test';
import { describe, expect, it } from 'vitest';
import { auth, bytes, tokenFor } from './helpers';

const BASE = 'https://worker.test';

let sequence = 0;
function nextUser(): string {
  sequence += 1;
  return `user_del_${sequence}`;
}

function findingId(suffix: string): string {
  return `4b7e22${suffix.padStart(2, '0')}-0000-4000-8000-000000000000`;
}

async function store(token: string, id: string, imageBytes = 512): Promise<void> {
  const now = Date.now();
  const image = await SELF.fetch(`${BASE}/v1/findings/${id}/image?modifiedAt=${now}`, {
    method: 'PUT',
    headers: auth(token),
    body: bytes(imageBytes),
  });
  expect(image.status).toBe(200);
  const meta = await SELF.fetch(`${BASE}/v1/findings/${id}/meta?modifiedAt=${now}`, {
    method: 'PUT',
    headers: auth(token),
    body: '{"note":"a ditch","gps_lat":49.2}',
  });
  expect(meta.status).toBe(200);
}

async function globalBytes(): Promise<number> {
  const row = await env.DB.prepare("SELECT value FROM counter WHERE key = 'global_bytes'").first<{
    value: number;
  }>();
  return row?.value ?? 0;
}

describe('erasing an account', () => {
  it('removes every object and every row, and returns the bytes to the counters', async () => {
    const user = nextUser();
    const token = await tokenFor(user);
    const before = await globalBytes();
    await store(token, findingId('01'));
    await store(token, findingId('02'));

    const purged = await SELF.fetch(`${BASE}/v1/me/data`, { method: 'DELETE', headers: auth(token) });
    expect(purged.status).toBe(200);
    expect(((await purged.json()) as { purged: { complete: boolean } }).purged.complete).toBe(true);

    const rows = await env.DB.prepare(
      `SELECT (SELECT COUNT(*) FROM finding WHERE user_id = ?1) AS findings,
              (SELECT COUNT(*) FROM object_bytes WHERE user_id = ?1) AS objects,
              (SELECT COUNT(*) FROM counter WHERE key = 'user:' || ?1) AS counters`,
    )
      .bind(user)
      .first<{ findings: number; objects: number; counters: number }>();
    expect(rows).toEqual({ findings: 0, objects: 0, counters: 0 });
    expect(await globalBytes()).toBe(before);
    expect((await env.FINDINGS.list({ prefix: `findings/${user}/` })).objects).toEqual([]);
  });

  it('refuses every write afterwards, so nothing lands behind the erasure', async () => {
    // A device can still be holding a valid token when the purge runs. Without a fence, its upload
    // arrives after the final listing and the account is left holding data it was told was gone.
    const token = await tokenFor(nextUser());
    await store(token, findingId('03'));
    await SELF.fetch(`${BASE}/v1/me/data`, { method: 'DELETE', headers: auth(token) });

    const late = await SELF.fetch(`${BASE}/v1/findings/${findingId('04')}/image?modifiedAt=${Date.now()}`, {
      method: 'PUT',
      headers: auth(token),
      body: bytes(128),
    });
    expect(late.status).toBe(410);
    const body = (await late.json()) as { error: { code: string; retryable: boolean } };
    expect(body.error.code).toBe('account_deleting');
    expect(body.error.retryable).toBe(false);
  });

  it('can be run twice without deleting anyone else or double-counting', async () => {
    // Not a nicety: deleting a user in the app fires Clerk's `user.deleted` webhook, so the app's
    // own purge and the webhook's purge normally run against the same account at the same time.
    const user = nextUser();
    const token = await tokenFor(user);
    const bystander = await tokenFor(nextUser());
    await store(token, findingId('05'));
    await store(bystander, findingId('06'));

    const bystanderBefore = await SELF.fetch(`${BASE}/v1/me/usage`, { headers: auth(bystander) });
    const bystanderUsage = ((await bystanderBefore.json()) as { usage: { used: number } }).usage.used;
    const doomedBefore = await SELF.fetch(`${BASE}/v1/me/usage`, { headers: auth(token) });
    const doomedUsage = ((await doomedBefore.json()) as { usage: { used: number } }).usage.used;
    expect(doomedUsage).toBeGreaterThan(0);
    const globalBefore = await globalBytes();

    const [first, second] = await Promise.all([
      SELF.fetch(`${BASE}/v1/me/data`, { method: 'DELETE', headers: auth(token) }),
      SELF.fetch(`${BASE}/v1/me/data`, { method: 'DELETE', headers: auth(token) }),
    ]);
    expect(first.status).toBe(200);
    expect(second.status).toBe(200);

    // The bystander is untouched, and the shared counter fell by exactly ONE account's worth --
    // which is the assertion that fails if two concurrent purges each decrement it.
    const after = await SELF.fetch(`${BASE}/v1/me/usage`, { headers: auth(bystander) });
    expect(((await after.json()) as { usage: { used: number } }).usage.used).toBe(bystanderUsage);
    expect(await globalBytes()).toBe(globalBefore - doomedUsage);
  });

  it('never reaches an account whose id merely starts with another', async () => {
    // `findings/user_1/` is a prefix of `findings/user_12/...` without the trailing slash, and the
    // purge would take a different person's fieldwork with it.
    const shortToken = await tokenFor('user_1');
    const longToken = await tokenFor('user_12');
    await store(shortToken, findingId('07'));
    await store(longToken, findingId('08'));

    await SELF.fetch(`${BASE}/v1/me/data`, { method: 'DELETE', headers: auth(shortToken) });

    const survivor = await SELF.fetch(`${BASE}/v1/findings/${findingId('08')}/meta`, {
      headers: auth(longToken),
    });
    expect(survivor.status).toBe(200);
  });
});

describe('the Clerk webhook', () => {
  async function signed(body: string, secret = env.CLERK_WEBHOOK_SECRET ?? ''): Promise<Headers> {
    const id = 'msg_test';
    const timestamp = String(Math.floor(Date.now() / 1000));
    const raw = secret.startsWith('whsec_') ? secret.slice(6) : secret;
    const key = await crypto.subtle.importKey(
      'raw',
      Uint8Array.from(atob(raw), (character) => character.charCodeAt(0)),
      { name: 'HMAC', hash: 'SHA-256' },
      false,
      ['sign'],
    );
    const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(`${id}.${timestamp}.${body}`));
    const signature = btoa(String.fromCharCode(...new Uint8Array(mac)));
    return new Headers({
      'svix-id': id,
      'svix-timestamp': timestamp,
      'svix-signature': `v1,${signature}`,
      'content-type': 'application/json',
    });
  }

  it('erases the account named by a correctly signed user.deleted', async () => {
    // The backstop for a deletion that never touches the app: the Clerk dashboard, or support.
    const user = nextUser();
    const token = await tokenFor(user);
    await store(token, findingId('10'));

    const body = JSON.stringify({ type: 'user.deleted', data: { id: user } });
    const response = await SELF.fetch(`${BASE}/v1/webhooks/clerk`, {
      method: 'POST',
      headers: await signed(body),
      body,
    });
    expect(response.status).toBe(200);
    expect((await env.FINDINGS.list({ prefix: `findings/${user}/` })).objects).toEqual([]);
  });

  it('refuses a body that was not signed with the shared secret', async () => {
    const body = JSON.stringify({ type: 'user.deleted', data: { id: 'user_victim' } });
    const headers = await signed(body, 'whsec_' + btoa('not the secret'));
    const response = await SELF.fetch(`${BASE}/v1/webhooks/clerk`, { method: 'POST', headers, body });
    expect(response.status).toBe(401);
  });

  it('refuses a replay from outside the timestamp window', async () => {
    const body = JSON.stringify({ type: 'user.deleted', data: { id: 'user_victim' } });
    const headers = await signed(body);
    headers.set('svix-timestamp', String(Math.floor(Date.now() / 1000) - 3_600));
    const response = await SELF.fetch(`${BASE}/v1/webhooks/clerk`, { method: 'POST', headers, body });
    expect(response.status).toBe(401);
  });

  it('acknowledges a verified event it does not handle', async () => {
    // Answering non-2xx would make svix retry indefinitely and can get the endpoint disabled in
    // Clerk, which would remove the backstop silently.
    const body = JSON.stringify({ type: 'user.updated', data: { id: 'user_someone' } });
    const response = await SELF.fetch(`${BASE}/v1/webhooks/clerk`, {
      method: 'POST',
      headers: await signed(body),
      body,
    });
    expect(response.status).toBe(200);
  });
});
