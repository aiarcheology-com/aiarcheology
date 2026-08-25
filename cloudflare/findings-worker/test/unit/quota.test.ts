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

  it('charges only the difference when an object is replaced', async () => {
    // Otherwise editing the same finding repeatedly would walk a user over their cap while the
    // bucket held one object all along.
    const token = await tokenFor(nextUser());
    const id = findingId('04');
    await putImage(token, id, 2000);
    const replaced = await putImage(token, id, 2048, Date.now() + 1);
    expect(replaced.status).toBe(200);
    expect(((await replaced.json()) as { usage: { used: number } }).usage.used).toBe(2048);
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
    const ceiling = env.GLOBAL_BYTE_CEILING;
    const restore = await env.DB.prepare("SELECT value FROM counter WHERE key = 'global_bytes'").first<{
      value: number;
    }>();
    await env.DB.prepare("UPDATE counter SET value = ?1 WHERE key = 'global_bytes'").bind(ceiling - 10).run();

    try {
      const refused = await putImage(token, findingId('08'), 1024);
      expect(refused.status).toBe(507);
      expect(((await refused.json()) as { error: { code: string } }).error.code).toBe('global_capacity');
    } finally {
      await env.DB.prepare("UPDATE counter SET value = ?1 WHERE key = 'global_bytes'")
        .bind(restore?.value ?? 0)
        .run();
    }
  });
});
