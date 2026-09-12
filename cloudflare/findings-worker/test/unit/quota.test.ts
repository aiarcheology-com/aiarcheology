import { SELF, env } from 'cloudflare:test';
import { describe, expect, it } from 'vitest';
import { auth, bytes, tokenFor } from './helpers';

const BASE = 'https://worker.test';

let sequence = 0;
function nextUser(): string {
  sequence += 1;
  return `user_quota_${sequence}`;
}

function findingId(suffix: string): string {
  return `7c1b4d${suffix.padStart(2, '0')}-0000-4000-8000-000000000000`;
}

async function putImage(token: string, id: string, size: number, modifiedAt = Date.now()) {
  return SELF.fetch(`${BASE}/v1/findings/${id}/image?modifiedAt=${modifiedAt}`, {
    method: 'PUT',
    headers: auth(token),
    body: bytes(size),
  });
}

describe('per-user quota', () => {
  it('refuses an upload that would cross the cap, with a terminal error', async () => {
    const token = await tokenFor(nextUser());
    expect((await putImage(token, findingId('01'), 2000)).status).toBe(200);
    expect((await putImage(token, findingId('02'), 2000)).status).toBe(200);

    const refused = await putImage(token, findingId('03'), 2000);
    expect(refused.status).toBe(507);
    const body = (await refused.json()) as { error: { code: string; retryable: boolean } };
    expect(body.error.code).toBe('quota_exceeded');
    // Terminal on purpose: retrying cannot make room. Only the user pruning findings can, so the
    // outbox must park the item and say so rather than spin.
    expect(body.error.retryable).toBe(false);
  });

  it('charges a staged replacement until the reaper can prove it lost or was superseded', async () => {
    // Revisioned keys deliberately keep both objects until the newer one commits and maintenance
    // reclaims the old revision. Charging that short overlap is the safe direction: a crash cannot
    // turn a real R2 object into unmetered storage.
    const token = await tokenFor(nextUser());
    const id = findingId('04');
    const modifiedAt = Date.now() - 100;
    await putImage(token, id, 2000, modifiedAt);
    const replaced = await putImage(token, id, 2048, modifiedAt + 1);
    expect(replaced.status).toBe(200);
    expect(((await replaced.json()) as { usage: { used: number } }).usage.used).toBe(4048);
  });

  it('reports usage against the limit on every write, so the client can warn before it blocks', async () => {
    const token = await tokenFor(nextUser());
    const response = await putImage(token, findingId('05'), 1024);
    expect(((await response.json()) as { usage: unknown }).usage).toEqual({ used: 1024, limit: 4096 });
  });
});

describe('body size caps', () => {
  it('refuses an oversized body and stores nothing', async () => {
    const token = await tokenFor(nextUser());
    const id = findingId('06');
    const response = await putImage(token, id, 4096);
    expect(response.status).toBe(413);

    const usage = await SELF.fetch(`${BASE}/v1/me/usage`, { headers: auth(token) });
    expect(((await usage.json()) as { usage: { used: number } }).usage.used).toBe(0);
    expect((await SELF.fetch(`${BASE}/v1/findings/${id}/image`, { headers: auth(token) })).status).toBe(404);
  });

  it('refuses an oversized body even when Content-Length lies about it', async () => {
    // The cap is enforced against bytes actually read, so a client that understates its size is
    // refused by the same code path rather than trusted.
    const token = await tokenFor(nextUser());
    const response = await SELF.fetch(`${BASE}/v1/findings/${findingId('07')}/image?modifiedAt=${Date.now()}`, {
      method: 'PUT',
      headers: { ...auth(token), 'content-length': '10' },
      body: bytes(4096),
    });
    expect(response.status).toBe(413);
  });
});

describe('the account-wide ceiling', () => {
  it('refuses an upload that would take the whole account past its ceiling', async () => {
    // The 50 MB per-user cap bounds one user; it is not a spend cap. This is the guard that stops
    // user 201 from quietly taking the account past its free allowance.
    const token = await tokenFor(nextUser());
    // The account-wide total is derived from the per-user rows, so the crowd is seeded as users,
    // not as a number poked into the cached total.
    await env.DB.prepare("INSERT INTO counter (key, value) VALUES ('user:crowd', ?1)")
      .bind(env.GLOBAL_BYTE_CEILING - 10)
      .run();

    try {
      const refused = await putImage(token, findingId('08'), 1024);
      expect(refused.status).toBe(507);
      expect(((await refused.json()) as { error: { code: string } }).error.code).toBe('global_capacity');
    } finally {
      await env.DB.prepare("DELETE FROM counter WHERE key = 'user:crowd'").run();
    }
  });
});

describe('the global guard against a drifted counter', () => {
  it('reads the acting user\'s own bytes from truth, not from their cached total', async () => {
    // A cached row left low by an older build made the ceiling fail OPEN: the guard added the
    // incoming bytes to a total that did not include what the user already had.
    const user = nextUser();
    const token = await tokenFor(user);
    expect((await putImage(token, findingId('20'), 2048)).status).toBe(200);
    // Exactly the drift the derived totals were introduced to heal: the cached row says zero while
    // `object_bytes` says 2048.
    await env.DB.prepare("UPDATE counter SET value = 0 WHERE key = 'user:' || ?1").bind(user).run();

    // Other tests in this file leave their own users behind, so the crowd is sized against what is
    // actually there. Headroom is set so the DRIFTED total still fits and the true one does not:
    // that difference is the whole of the bug.
    const others = await env.DB.prepare(
      "SELECT COALESCE(SUM(value), 0) AS total FROM counter WHERE key LIKE 'user:%'",
    ).first<{ total: number }>();
    const crowd = env.GLOBAL_BYTE_CEILING - 2048 - (others?.total ?? 0);
    await env.DB.prepare("INSERT INTO counter (key, value) VALUES ('user:crowd', ?1)").bind(crowd).run();

    try {
      const refused = await putImage(token, findingId('21'), 1024);
      expect(refused.status).toBe(507);
      expect(((await refused.json()) as { error: { code: string } }).error.code).toBe('global_capacity');
    } finally {
      await env.DB.prepare("DELETE FROM counter WHERE key = 'user:crowd'").run();
    }
  });
});
