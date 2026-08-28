import { SELF, env } from 'cloudflare:test';
import { describe, expect, it } from 'vitest';
import { sweepIncompleteFences } from '../../src/sweep';
import { auth, bytes, tokenFor } from './helpers';

const BASE = 'https://worker.test';

let sequence = 0;
function nextUser(): string {
  sequence += 1;
  return `user_sweep_${sequence}`;
}

function findingId(suffix: string): string {
  return `5c8f33${suffix.padStart(2, '0')}-0000-4000-8000-000000000000`;
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
    body: '{"note":"a ditch"}',
  });
  expect(meta.status).toBe(200);
}

/// Leaves the account in the state a purge that died half-way leaves behind: the fence is set, so
/// nothing can write and nothing will retry, but the data is still there.
async function fenceWithoutPurging(userId: string): Promise<void> {
  await env.DB.prepare(
    `INSERT INTO user_state (user_id, deleting) VALUES (?1, 1)
       ON CONFLICT (user_id) DO UPDATE SET deleting = 1`,
  )
    .bind(userId)
    .run();
}

async function rowsFor(userId: string): Promise<number> {
  const row = await env.DB.prepare('SELECT COUNT(*) AS n FROM finding WHERE user_id = ?1')
    .bind(userId)
    .first<{ n: number }>();
  return row?.n ?? 0;
}

async function objectsFor(userId: string): Promise<number> {
  const listing = await env.FINDINGS.list({ prefix: `findings/${userId}/` });
  return listing.objects.length;
}

describe('sweeping purges that never finished', () => {
  it('finishes a purge that was fenced but never completed', async () => {
    const userId = nextUser();
    await store(await tokenFor(userId), findingId('01'));
    // The state a failed purge leaves: fenced, so no client can ever clean it up, and no webhook
    // will arrive again because svix has given up and the Clerk user is gone.
    await fenceWithoutPurging(userId);
    expect(await rowsFor(userId)).toBe(1);
    expect(await objectsFor(userId)).toBeGreaterThan(0);

    const result = await sweepIncompleteFences(env);

    expect(result.incomplete).toBeGreaterThan(0);
    expect(result.purged).toBe(true);
    expect(await rowsFor(userId)).toBe(0);
    expect(await objectsFor(userId)).toBe(0);
  });

  it('does nothing when every fence is already clean', async () => {
    const userId = nextUser();
    await fenceWithoutPurging(userId); // fenced, but there was never any data behind it

    const result = await sweepIncompleteFences(env);

    expect(result.incomplete).toBe(0);
    expect(result.purged).toBeNull();
  });

  it('leaves an unfenced account alone, however much data it has', async () => {
    const userId = nextUser();
    await store(await tokenFor(userId), findingId('02'));

    const result = await sweepIncompleteFences(env);

    // The fence is the record that a purge was owed. Without one there is nothing to finish, and
    // sweeping a live account would be the worst bug this service could have.
    expect(result.incomplete).toBe(0);
    expect(await rowsFor(userId)).toBe(1);
  });

  it('is safe to run twice — the second run finds nothing left', async () => {
    const userId = nextUser();
    await store(await tokenFor(userId), findingId('03'));
    await fenceWithoutPurging(userId);

    await sweepIncompleteFences(env);
    const second = await sweepIncompleteFences(env);

    expect(second.incomplete).toBe(0);
    expect(second.purged).toBeNull();
  });

  it('keeps the fence, so the account can never write again', async () => {
    const userId = nextUser();
    const token = await tokenFor(userId);
    await store(token, findingId('04'));
    await fenceWithoutPurging(userId);

    await sweepIncompleteFences(env);

    // Sweeping is finishing a deletion, not undoing one.
    const refused = await SELF.fetch(`${BASE}/v1/findings/${findingId('05')}/image?modifiedAt=${Date.now()}`, {
      method: 'PUT',
      headers: auth(token),
      body: bytes(64),
    });
    expect(refused.status).toBe(410);
  });
});
