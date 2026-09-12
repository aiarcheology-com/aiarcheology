import { SELF, env } from 'cloudflare:test';
import { describe, expect, it } from 'vitest';
import { purgeAccount, purgeAccountMetered } from '../../src/purge';
import { sweepIncompleteFences } from '../../src/sweep';
import { auth, bytes, databaseWithFailingBatch, faultyBucket, tokenFor } from './helpers';

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

interface FenceRow {
  deleting: number;
  purged: number;
  attemptedAt: number | null;
  attemptId: string | null;
}

async function fenceRow(userId: string): Promise<FenceRow | null> {
  return env.DB.prepare(
    `SELECT deleting, purged, purge_attempted_at AS attemptedAt, purge_attempt_id AS attemptId
       FROM user_state WHERE user_id = ?1`,
  )
    .bind(userId)
    .first<FenceRow>();
}

async function findingRows(userId: string): Promise<number> {
  const row = await env.DB.prepare('SELECT COUNT(*) AS n FROM finding WHERE user_id = ?1')
    .bind(userId)
    .first<{ n: number }>();
  return row?.n ?? 0;
}

async function objectsFor(userId: string): Promise<number> {
  return (await env.FINDINGS.list({ prefix: `findings/${userId}/` })).objects.length;
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
    // The public shape, exactly: the purge's subrequest metering is the sweep's business, not the
    // client's, and a field once published is a field kept.
    expect(((await purged.json()) as { purged: unknown }).purged).toEqual({ complete: true, objects: 4 });

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

  it('refuses a same-size re-upload behind the fence, and leaves nothing in the bucket', async () => {
    // The dangerous write is not a new finding, it is the retry the outbox makes routinely: the
    // same object at the same size. That changed no bytes, and a size-delta exemption let it skip
    // the fence entirely -- putting a screenshot into R2 behind a completed purge, unindexed and
    // beyond any later erasure (AIA-751).
    const user = nextUser();
    const token = await tokenFor(user);
    const id = findingId('10');
    const modifiedAt = Date.now();
    await SELF.fetch(`${BASE}/v1/findings/${id}/image?modifiedAt=${modifiedAt}`, {
      method: 'PUT',
      headers: auth(token),
      body: bytes(256),
    });

    // The fence alone, with the sizes still recorded -- the state a purge occupies for its whole
    // list-and-delete loop, which is where a late retry actually arrives. Purging first would drop
    // `object_bytes` and give the retry a non-zero delta, hiding the exemption this pins.
    await env.DB.prepare(
      `INSERT INTO user_state (user_id, deleting) VALUES (?1, 1)
         ON CONFLICT (user_id) DO UPDATE SET deleting = 1`,
    )
      .bind(user)
      .run();

    const late = await SELF.fetch(`${BASE}/v1/findings/${id}/image?modifiedAt=${modifiedAt}`, {
      method: 'PUT',
      headers: auth(token),
      body: bytes(256),
    });
    expect(late.status).toBe(410);
    expect(((await late.json()) as { error: { code: string } }).error.code).toBe('account_deleting');

    await SELF.fetch(`${BASE}/v1/me/data`, { method: 'DELETE', headers: auth(token) });
    expect((await env.FINDINGS.list({ prefix: `findings/${user}/` })).objects).toEqual([]);
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

describe('a purge that cannot finish in one call', () => {
  it('charges four subrequests to confirm an already-empty account', async () => {
    // The sweep reserves the worst case before it starts another account, but charges actual work
    // after it returns. An empty confirmation is its fence write, empty loop listing, confirming
    // listing and one completing D1 batch.
    const result = await purgeAccountMetered(env, nextUser(), 1_000);

    expect(result).toEqual({ complete: true, objects: 0, subrequests: 4, marked: true });
  });

  it('stays pending after exceeding the batch budget, and the sweep finishes it without a credential', async () => {
    // The reproduced state (AIA-0842): more objects than one invocation's batch budget deletes. The
    // listing is capped at one object so fifteen batches remove fifteen; the strays are put
    // directly, which is also exactly what an R2-only leftover looks like.
    const user = nextUser();
    const token = await tokenFor(user);
    const before = await globalBytes();
    await store(token, findingId('20'));
    for (let index = 0; index < 16; index += 1) {
      await env.FINDINGS.put(`findings/${user}/stray/${index}`, 'x');
    }

    const budgeted = { ...env, FINDINGS: faultyBucket(env.FINDINGS, { listLimit: 1 }) };
    await expect(purgeAccount(budgeted, user)).rejects.toMatchObject({
      code: 'internal',
      detail: { complete: false, purged: { objects: 15 } },
    });

    // Refused as incomplete, and recorded as such: the fence is up, the purge is pending, and the
    // index -- with the quota it accounts for -- is still there, because storage is not gone yet.
    expect(await objectsFor(user)).toBe(3);
    expect(await fenceRow(user)).toMatchObject({ deleting: 1, purged: 0 });
    expect(await findingRows(user)).toBe(1);
    expect(await globalBytes()).toBeGreaterThan(before);

    // No client can retry: the token is what a deleted Clerk user no longer has. The daily sweep
    // needs none.
    const swept = await sweepIncompleteFences(env);
    expect(swept.completed).toBeGreaterThan(0);
    expect(await objectsFor(user)).toBe(0);
    expect(await findingRows(user)).toBe(0);
    expect(await fenceRow(user)).toMatchObject({ deleting: 1, purged: 1 });
    expect(await globalBytes()).toBe(before);

    const again = await sweepIncompleteFences(env);
    expect(again.remaining).toBe(0);
  });

  it('stays pending when the confirming listing fails, so the sweep can confirm it later', async () => {
    const user = nextUser();
    const token = await tokenFor(user);
    const before = await globalBytes();
    await store(token, findingId('21'));

    // The first listing finds both objects and is not truncated, so the loop ends; the second is
    // the confirmation, and it is the one that dies.
    const failing = { ...env, FINDINGS: faultyBucket(env.FINDINGS, { failListAt: 2 }) };
    await expect(purgeAccount(failing, user)).rejects.toThrow('injected R2 failure');

    expect(await objectsFor(user)).toBe(0);
    expect(await fenceRow(user)).toMatchObject({ deleting: 1, purged: 0 });
    expect(await findingRows(user)).toBe(1);

    const swept = await sweepIncompleteFences(env);
    expect(swept.completed).toBeGreaterThan(0);
    expect(await findingRows(user)).toBe(0);
    expect(await fenceRow(user)).toMatchObject({ deleting: 1, purged: 1 });
    expect(await globalBytes()).toBe(before);
  });

  it('stays pending when the index wipe fails, so nothing is lost at the boundary', async () => {
    // The storage is confirmed gone and the one transaction that drops the index, releases the
    // quota and marks the purge done fails as a whole. Everything it would have done is still owed.
    const user = nextUser();
    const token = await tokenFor(user);
    const before = await globalBytes();
    await store(token, findingId('22'));

    const failing = { ...env, DB: databaseWithFailingBatch(env.DB) };
    await expect(purgeAccount(failing, user)).rejects.toThrow('injected D1 failure');

    expect(await objectsFor(user)).toBe(0);
    expect(await fenceRow(user)).toMatchObject({ deleting: 1, purged: 0 });
    expect(await findingRows(user)).toBe(1);
    expect(await globalBytes()).toBeGreaterThan(before);

    const swept = await sweepIncompleteFences(env);
    expect(swept.completed).toBeGreaterThan(0);
    expect(await findingRows(user)).toBe(0);
    expect(await fenceRow(user)).toMatchObject({ deleting: 1, purged: 1 });
    expect(await globalBytes()).toBe(before);
  });

  it('does not let an earlier attempt mark done what a later, dead attempt reopened in the same millisecond', async () => {
    // Two attempts overlap routinely. The later one opens after the earlier one did, re-stamping
    // the row, and dies before confirming; the earlier one, confirming afterwards, must not close
    // the record over it. Staged by running the later attempt inside the earlier one's confirming
    // listing, which is exactly where the earlier one is when the later one starts.
    const user = nextUser();
    const token = await tokenFor(user);
    await store(token, findingId('23'));
    const attemptAt = 1_000;
    let earlierAttemptId: string | null | undefined;
    let laterAttemptId: string | null | undefined;

    const earlier = {
      ...env,
      FINDINGS: faultyBucket(env.FINDINGS, {
        beforeListing: {
          at: 2,
          run: async () => {
            earlierAttemptId = (await fenceRow(user))?.attemptId;
            const later = { ...env, DB: databaseWithFailingBatch(env.DB) };
            await expect(purgeAccountMetered(later, user, attemptAt)).rejects.toThrow('injected D1 failure');
            laterAttemptId = (await fenceRow(user))?.attemptId;
          },
        },
      }),
    };
    const result = await purgeAccountMetered(earlier, user, attemptAt);
    // The answer and the mark part ways here; see `MeteredPurgeResult.marked`.
    expect(result.complete).toBe(true);
    expect(result.marked).toBe(false);
    expect(earlierAttemptId).toEqual(expect.any(String));
    expect(laterAttemptId).toEqual(expect.any(String));
    expect(laterAttemptId).not.toBe(earlierAttemptId);

    // Rows are gone -- the storage is confirmed empty -- but the record stays pending until an
    // attempt that owns the row confirms it. The sweep does exactly that.
    expect(await findingRows(user)).toBe(0);
    expect(await fenceRow(user)).toMatchObject({ purged: 0, attemptedAt: attemptAt, attemptId: laterAttemptId });
    await sweepIncompleteFences(env);
    expect(await fenceRow(user)).toMatchObject({ purged: 1 });
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

  it('overlapping app, webhook and sweep purges leave one clean account, one untouched bystander', async () => {
    // The three ways a purge starts, at once: the app's DELETE, the webhook Clerk fires for it,
    // and the cron finding the fence pending mid-flight.
    const user = nextUser();
    const token = await tokenFor(user);
    const bystander = await tokenFor(nextUser());
    await store(token, findingId('30'));
    await store(bystander, findingId('31'));
    const bystanderUsage = ((await (await SELF.fetch(`${BASE}/v1/me/usage`, { headers: auth(bystander) })).json()) as {
      usage: { used: number };
    }).usage.used;
    const doomedUsage = ((await (await SELF.fetch(`${BASE}/v1/me/usage`, { headers: auth(token) })).json()) as {
      usage: { used: number };
    }).usage.used;
    const globalBefore = await globalBytes();
    const body = JSON.stringify({ type: 'user.deleted', data: { id: user } });

    const [app, hook, sweep] = await Promise.all([
      SELF.fetch(`${BASE}/v1/me/data`, { method: 'DELETE', headers: auth(token) }),
      SELF.fetch(`${BASE}/v1/webhooks/clerk`, { method: 'POST', headers: await signed(body), body }),
      sweepIncompleteFences(env),
    ]);
    expect(app.status).toBe(200);
    expect(hook.status).toBe(200);
    expect(sweep.remaining).toBe(sweep.pending - sweep.completed);

    expect(await objectsFor(user)).toBe(0);
    expect(await findingRows(user)).toBe(0);
    expect(await fenceRow(user)).toMatchObject({ deleting: 1, purged: 1 });
    expect(await globalBytes()).toBe(globalBefore - doomedUsage);
    const after = await SELF.fetch(`${BASE}/v1/me/usage`, { headers: auth(bystander) });
    expect(((await after.json()) as { usage: { used: number } }).usage.used).toBe(bystanderUsage);

    const late = await SELF.fetch(`${BASE}/v1/findings/${findingId('32')}/image?modifiedAt=${Date.now()}`, {
      method: 'PUT',
      headers: auth(token),
      body: bytes(64),
    });
    expect(late.status).toBe(410);
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
