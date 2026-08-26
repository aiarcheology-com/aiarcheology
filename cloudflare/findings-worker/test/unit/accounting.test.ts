import { SELF, env } from 'cloudflare:test';
import { describe, expect, it } from 'vitest';
import { auth, bytes, tokenFor } from './helpers';

const BASE = 'https://worker.test';

let sequence = 0;
function nextUser(): string {
  sequence += 1;
  return `user_acct_${sequence}`;
}

function findingId(suffix: string): string {
  return `9e2f11${suffix.padStart(2, '0')}-0000-4000-8000-000000000000`;
}

function putImage(token: string, id: string, size: number, modifiedAt = Date.now()): Promise<Response> {
  return SELF.fetch(`${BASE}/v1/findings/${id}/image?modifiedAt=${modifiedAt}`, {
    method: 'PUT',
    headers: auth(token),
    body: bytes(size),
  });
}

async function globalBytes(): Promise<number> {
  const row = await env.DB.prepare("SELECT value FROM counter WHERE key = 'global_bytes'").first<{
    value: number;
  }>();
  return row?.value ?? 0;
}

async function usedBytes(token: string): Promise<number> {
  const response = await SELF.fetch(`${BASE}/v1/me/usage`, { headers: auth(token) });
  return ((await response.json()) as { usage: { used: number } }).usage.used;
}

describe('byte accounting under concurrency and retries', () => {
  it('does not let simultaneous uploads walk a user past the cap', async () => {
    // Two devices on one account is the entire reason this Worker exists, so a read-check-write
    // quota is not a theoretical race: three of these all succeeded against a 4096-byte cap before
    // the check and the reservation became one guarded transaction.
    const token = await tokenFor(nextUser());
    const responses = await Promise.all([
      putImage(token, findingId('01'), 2000),
      putImage(token, findingId('02'), 2000),
      putImage(token, findingId('03'), 2000),
    ]);

    const accepted = responses.filter((response) => response.status === 200).length;
    expect(accepted).toBeLessThanOrEqual(2);
    expect(await usedBytes(token)).toBeLessThanOrEqual(env.USER_BYTE_LIMIT);
  });

  it('charges concurrent writes of the SAME object once, not once per writer', async () => {
    // The retry test below is sequential, and a sequential retry cannot expose this: two writers
    // that both measure the same pre-image and the same size used to pass the post-image guard
    // together and both add their bytes, permanently, with nothing to reconcile them (AIA-751).
    const token = await tokenFor(nextUser());
    const id = findingId('30');
    const modifiedAt = Date.now();
    const before = await globalBytes();

    await Promise.all([
      putImage(token, id, 512, modifiedAt),
      putImage(token, id, 512, modifiedAt),
      putImage(token, id, 512, modifiedAt),
    ]);

    expect(await usedBytes(token)).toBe(512);
    expect(await globalBytes()).toBe(before + 512);
  });

  it('releases a finding\'s bytes once when two devices delete it at the same time', async () => {
    // Both deletes read the same total outside the transaction and both subtracted it; the user's
    // counter floored at zero and hid it, while the account-wide total silently drifted open.
    const token = await tokenFor(nextUser());
    const kept = findingId('31');
    const doomed = findingId('32');
    const modifiedAt = Date.now();
    expect((await putImage(token, kept, 512, modifiedAt)).status).toBe(200);
    expect((await putImage(token, doomed, 512, modifiedAt)).status).toBe(200);
    const before = await globalBytes();

    const remove = (): Promise<Response> =>
      SELF.fetch(`${BASE}/v1/findings/${doomed}?modifiedAt=${modifiedAt + 1}`, {
        method: 'DELETE',
        headers: auth(token),
      });
    await Promise.all([remove(), remove(), remove()]);

    expect(await usedBytes(token)).toBe(512);
    expect(await globalBytes()).toBe(before - 512);
  });

  it('charges a retried upload exactly once, however many times it is retried', async () => {
    // The failure this guards is permanent and account-wide: if the counter moves without the size
    // record, every retry adds the bytes again, nothing reconciles it, and the ceiling eventually
    // refuses everyone.
    const token = await tokenFor(nextUser());
    const id = findingId('04');
    const modifiedAt = Date.now();

    expect((await putImage(token, id, 512, modifiedAt)).status).toBe(200);
    const afterFirst = await globalBytes();

    expect((await putImage(token, id, 512, modifiedAt)).status).toBe(200);
    expect((await putImage(token, id, 512, modifiedAt)).status).toBe(200);

    expect(await globalBytes()).toBe(afterFirst);
    expect(await usedBytes(token)).toBe(512);
  });

  it('returns every byte to both counters when a finding is deleted', async () => {
    const token = await tokenFor(nextUser());
    const id = findingId('05');
    const now = Date.now();
    const before = await globalBytes();

    await putImage(token, id, 1024, now);
    await SELF.fetch(`${BASE}/v1/findings/${id}/meta?modifiedAt=${now}`, {
      method: 'PUT',
      headers: auth(token),
      body: '{"note":"x"}',
    });
    expect(await globalBytes()).toBeGreaterThan(before);

    await SELF.fetch(`${BASE}/v1/findings/${id}?modifiedAt=${now + 1}`, {
      method: 'DELETE',
      headers: auth(token),
    });
    expect(await globalBytes()).toBe(before);
    expect(await usedBytes(token)).toBe(0);
  });
});

describe('the receipt clock', () => {
  it('gives every write its own receipt value, even back to back', async () => {
    // Two writes handed the same receipt value are safe only while both are visible when a client's
    // cursor crosses that instant. If one commits after the client has paged past, it is invisible
    // for ever -- the same silent cross-device loss that paging on modifiedAt would have caused.
    const token = await tokenFor(nextUser());
    const ids = ['10', '11', '12', '13'].map(findingId);
    // Fired together, so they land in the same millisecond. Issued one at a time the wall clock
    // separates them on its own and the test proves nothing.
    const stamp = Date.now();
    await Promise.all(
      ids.map((id) =>
        SELF.fetch(`${BASE}/v1/findings/${id}/meta?modifiedAt=${stamp}`, {
          method: 'PUT',
          headers: auth(token),
          body: '{"note":"y"}',
        }),
      ),
    );

    const page = await SELF.fetch(`${BASE}/v1/findings`, { headers: auth(token) });
    const rows = ((await page.json()) as { findings: { receivedAt: number }[] }).findings;
    const distinct = new Set(rows.map((row) => row.receivedAt));
    expect(distinct.size).toBe(rows.length);
  });
});

describe('response hygiene', () => {
  it('marks every authenticated response uncacheable and varying on the credential', async () => {
    const token = await tokenFor(nextUser());
    const response = await SELF.fetch(`${BASE}/v1/me/usage`, { headers: auth(token) });
    expect(response.headers.get('cache-control')).toBe('private, no-store');
    expect(response.headers.get('vary')).toBe('Authorization');
  });

  it('keeps the finding\'s own content out of every shared cache', async () => {
    // These two responses carry the coordinates, the finder's name and the photograph, and their
    // URL is identical for every account -- so they are the ones a URL-keyed cache would confuse.
    const token = await tokenFor(nextUser());
    const id = findingId('33');
    const modifiedAt = Date.now();
    expect((await putImage(token, id, 64, modifiedAt)).status).toBe(200);
    const meta = await SELF.fetch(`${BASE}/v1/findings/${id}/meta?modifiedAt=${modifiedAt}`, {
      method: 'PUT',
      headers: auth(token),
      body: JSON.stringify({ id }),
    });
    expect(meta.status).toBe(200);

    for (const kind of ['meta', 'image']) {
      const response = await SELF.fetch(`${BASE}/v1/findings/${id}/${kind}`, { headers: auth(token) });
      expect(response.status).toBe(200);
      expect(response.headers.get('cache-control')).toBe('private, no-store');
      expect(response.headers.get('vary')).toBe('Authorization');
    }
  });

  it('answers a malformed finding id with a client error, not a retryable 500', async () => {
    const token = await tokenFor(nextUser());
    const response = await SELF.fetch(`${BASE}/v1/findings/%zz/meta`, { headers: auth(token) });
    expect(response.status).toBe(400);
    expect(((await response.json()) as { error: { code: string } }).error.code).toBe('bad_request');
  });

  it('tells a client that running out of shared capacity is worth retrying', async () => {
    // Unlike the user's own quota, this is not their condition and it clears without them doing
    // anything. Parking on it would strand every outbox on the service.
    const token = await tokenFor(nextUser());
    // The account-wide total is derived from the per-user rows, so a full account is simulated the
    // way it actually happens: other users already holding the bytes.
    await env.DB.prepare("INSERT INTO counter (key, value) VALUES ('user:crowd', ?1)")
      .bind(env.GLOBAL_BYTE_CEILING - 10)
      .run();
    try {
      const refused = await putImage(token, findingId('20'), 1024);
      expect(refused.status).toBe(507);
      const body = (await refused.json()) as { error: { code: string; retryable: boolean } };
      expect(body.error.code).toBe('global_capacity');
      expect(body.error.retryable).toBe(true);
    } finally {
      await env.DB.prepare("DELETE FROM counter WHERE key = 'user:crowd'").run();
    }
  });
});
