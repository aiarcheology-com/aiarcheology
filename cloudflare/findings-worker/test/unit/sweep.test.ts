import { SELF, createScheduledController, env } from 'cloudflare:test';
import { afterEach, describe, expect, it, vi } from 'vitest';
import worker from '../../src/index';
import { purgeAccountMetered } from '../../src/purge';
import { sweepIncompleteFences } from '../../src/sweep';
import { auth, bytes, databaseWithFailingBatch, faultyBucket, tokenFor } from './helpers';

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
/// nothing can write and nothing will retry, and the purge is recorded as owed but not confirmed.
async function fenceWithoutPurging(userId: string): Promise<void> {
  await env.DB.prepare(
    `INSERT INTO user_state (user_id, deleting, purged) VALUES (?1, 1, 0)
       ON CONFLICT (user_id) DO UPDATE SET deleting = 1, purged = 0`,
  )
    .bind(userId)
    .run();
}

/// A fence whose purge was confirmed: the terminal state of every erased account.
async function fenceConfirmed(userId: string): Promise<void> {
  await env.DB.prepare(
    `INSERT INTO user_state (user_id, deleting, purged) VALUES (?1, 1, 1)
       ON CONFLICT (user_id) DO UPDATE SET deleting = 1, purged = 1`,
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

interface Progress {
  purged: number;
  attemptedAt: number | null;
}

async function progressFor(userId: string): Promise<Progress | null> {
  return env.DB.prepare('SELECT purged, purge_attempted_at AS attemptedAt FROM user_state WHERE user_id = ?1')
    .bind(userId)
    .first<Progress>();
}

async function pendingCount(): Promise<number> {
  const row = await env.DB.prepare('SELECT COUNT(*) AS n FROM user_state WHERE deleting = 1 AND purged = 0').first<{
    n: number;
  }>();
  return row?.n ?? 0;
}

/// A fence with more objects behind it than one purge can delete when listings are capped at one
/// object: the shape of the account that throws every day.
async function fenceWithStrays(userId: string, count: number): Promise<void> {
  await fenceWithoutPurging(userId);
  for (let index = 0; index < count; index += 1) {
    await env.FINDINGS.put(`findings/${userId}/stray/${index}`, 'x');
  }
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

    expect(result.pending).toBeGreaterThan(0);
    expect(result.completed).toBeGreaterThan(0);
    expect(result.remaining).toBe(0);
    expect(await rowsFor(userId)).toBe(0);
    expect(await objectsFor(userId)).toBe(0);
  });

  it('does nothing when every fence is confirmed', async () => {
    const userId = nextUser();
    await fenceConfirmed(userId);

    const result = await sweepIncompleteFences(env);

    expect(result).toEqual({ pending: 0, completed: 0, remaining: 0 });
  });

  it('leaves an unfenced account alone, however much data it has', async () => {
    const userId = nextUser();
    await store(await tokenFor(userId), findingId('02'));

    const result = await sweepIncompleteFences(env);

    // The fence is the record that a purge was owed. Without one there is nothing to finish, and
    // sweeping a live account would be the worst bug this service could have.
    expect(result.pending).toBe(0);
    expect(await rowsFor(userId)).toBe(1);
  });

  it('is safe to run twice — the second run finds nothing left', async () => {
    const userId = nextUser();
    await store(await tokenFor(userId), findingId('03'));
    await fenceWithoutPurging(userId);

    await sweepIncompleteFences(env);
    const second = await sweepIncompleteFences(env);

    expect(second).toEqual({ pending: 0, completed: 0, remaining: 0 });
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

describe('the sweep budget and order', () => {
  it('confirms several empty fences in one run, and stops before it could not finish one', async () => {
    // After the two candidate queries, four empty re-confirmations fit under the budget and a
    // fifth would not leave room for a worst-case purge. This is the backfill case: every fence
    // that predates the progress record is pending, and nearly all of them are already clean.
    expect(await pendingCount()).toBe(0);
    const users = Array.from({ length: 5 }, () => nextUser());
    for (const userId of users) await fenceWithoutPurging(userId);

    const first = await sweepIncompleteFences(env);
    expect(first).toEqual({ pending: 5, completed: 4, remaining: 1 });

    const second = await sweepIncompleteFences(env);
    expect(second).toEqual({ pending: 1, completed: 1, remaining: 0 });
    for (const userId of users) expect(await progressFor(userId)).toMatchObject({ purged: 1 });
  });

  it('takes the least recently attempted account first, so a failing one cannot block the rest', async () => {
    // `blocker` sorts before `victim` by id and cannot be finished in one run. Without an attempt
    // order the sweep would retry it first every day and never reach the victim.
    expect(await pendingCount()).toBe(0);
    const blocker = `user_sweep_order_a_${Date.now()}`;
    const victim = `user_sweep_order_b_${Date.now()}`;
    // Fifteen capped batches per run: 32 strays take three runs.
    await fenceWithStrays(blocker, 32);
    await fenceWithoutPurging(victim);
    const capped = { ...env, FINDINGS: faultyBucket(env.FINDINGS, { listLimit: 1 }) };

    const day1 = await sweepIncompleteFences(capped, 1_000);
    // Both were never attempted; ids break the tie, the blocker spends the run, the victim waits.
    expect(day1).toEqual({ pending: 2, completed: 0, remaining: 2 });
    expect(await progressFor(blocker)).toEqual({ purged: 0, attemptedAt: 1_000 });
    expect(await progressFor(victim)).toEqual({ purged: 0, attemptedAt: null });

    const day2 = await sweepIncompleteFences(capped, 2_000);
    // The victim has never been attempted, so it goes first and is confirmed; the blocker follows
    // with what is left of the budget.
    expect(day2).toEqual({ pending: 2, completed: 1, remaining: 1 });
    expect(await progressFor(victim)).toEqual({ purged: 1, attemptedAt: 2_000 });
    expect(await progressFor(blocker)).toEqual({ purged: 0, attemptedAt: 2_000 });
    expect(await objectsFor(blocker)).toBe(2);

    // Uncapped, the blocker's remaining strays go in one listing.
    const day3 = await sweepIncompleteFences(env, 3_000);
    expect(day3).toEqual({ pending: 1, completed: 1, remaining: 0 });
    expect(await objectsFor(blocker)).toBe(0);
  });

  it('records an attempt that hit a storage error, and keeps the account pending', async () => {
    expect(await pendingCount()).toBe(0);
    const userId = nextUser();
    await store(await tokenFor(userId), findingId('10'));
    await fenceWithoutPurging(userId);
    const broken = { ...env, FINDINGS: faultyBucket(env.FINDINGS, { failEveryList: true }) };

    const result = await sweepIncompleteFences(broken, 4_000);

    expect(result).toEqual({ pending: 1, completed: 0, remaining: 1 });
    expect(await progressFor(userId)).toEqual({ purged: 0, attemptedAt: 4_000 });
    expect(await rowsFor(userId)).toBe(1);

    const recovered = await sweepIncompleteFences(env, 5_000);
    expect(recovered).toEqual({ pending: 1, completed: 1, remaining: 0 });
  });

  it('reports a re-stamped fence as remaining rather than completed', async () => {
    // The sweep confirms the prefix, then a concurrent attempt opens at the same millisecond and
    // dies at its cleanup batch. The first attempt must not claim it finished, and the cron result
    // must report the durable fence state rather than infer it from local control flow.
    expect(await pendingCount()).toBe(0);
    const userId = nextUser();
    await store(await tokenFor(userId), findingId('12'));
    await fenceWithoutPurging(userId);
    const attemptAt = 6_000;
    const interleaved = {
      ...env,
      FINDINGS: faultyBucket(env.FINDINGS, {
        beforeListing: {
          at: 2,
          run: async () => {
            const later = { ...env, DB: databaseWithFailingBatch(env.DB) };
            await expect(purgeAccountMetered(later, userId, attemptAt)).rejects.toThrow('injected D1 failure');
          },
        },
      }),
    };

    const result = await sweepIncompleteFences(interleaved, attemptAt);

    expect(result).toEqual({ pending: 1, completed: 0, remaining: 1 });
    expect(await progressFor(userId)).toEqual({ purged: 0, attemptedAt: attemptAt });
    expect(await sweepIncompleteFences(env, attemptAt + 1)).toEqual({ pending: 1, completed: 1, remaining: 0 });
  });
});

describe('the purge cron', () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  async function runPurgeCron(): Promise<string[]> {
    const lines: string[] = [];
    vi.spyOn(console, 'log').mockImplementation((line: unknown) => {
      lines.push(String(line));
    });
    await worker.scheduled(createScheduledController({ cron: '0 3 * * *' }), env);
    return lines;
  }

  it('logs what it finished and what is left, and nothing when there is nothing to do', async () => {
    expect(await pendingCount()).toBe(0);
    expect(await runPurgeCron()).toEqual([]);

    const userId = nextUser();
    await store(await tokenFor(userId), findingId('11'));
    await fenceWithoutPurging(userId);

    const lines = await runPurgeCron();
    expect(lines).toHaveLength(1);
    expect(JSON.parse(lines[0] ?? '')).toMatchObject({ sweep: 'purged', remaining: 0, completed: 1 });
    expect(await progressFor(userId)).toMatchObject({ purged: 1 });
  });
});
