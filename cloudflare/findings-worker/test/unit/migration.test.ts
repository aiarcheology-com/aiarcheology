import { env } from 'cloudflare:test';
import { describe, expect, it } from 'vitest';
import { sweepIncompleteFences } from '../../src/sweep';

/// Runs a migration's statements one by one, the way `applyD1Migrations` does.
async function replay(name: string): Promise<void> {
  const migration = env.TEST_MIGRATIONS.find((candidate) => candidate.name === name);
  if (migration === undefined) throw new Error(`No migration named ${name}.`);
  for (const query of migration.queries) await env.DB.prepare(query).run();
}

describe('migration 0004', () => {
  // Alone in its file: it rebuilds `user_state` from the fence migration, and files are the unit of
  // storage isolation in this suite.
  it('backfills every existing fence as pending, and the sweep recovers what is behind it', async () => {
    // A fence written under 0002, with an object the purge that set it never reached: the state
    // every erased account was in before this record existed.
    await env.DB.prepare('DROP TABLE user_state').run();
    await replay('0002_account_deletion.sql');
    const userId = 'user_migrated_fence';
    await env.DB.prepare('INSERT INTO user_state (user_id, deleting) VALUES (?1, 1)').bind(userId).run();
    await env.FINDINGS.put(`findings/${userId}/leftover`, 'x');

    await replay('0004_purge_progress.sql');

    const row = await env.DB.prepare(
      `SELECT deleting, purged, purge_attempted_at AS attemptedAt, purge_attempt_id AS attemptId
         FROM user_state WHERE user_id = ?1`,
    )
      .bind(userId)
      .first<{ deleting: number; purged: number; attemptedAt: number | null; attemptId: string | null }>();
    expect(row).toEqual({ deleting: 1, purged: 0, attemptedAt: null, attemptId: null });

    const swept = await sweepIncompleteFences(env);
    expect(swept).toEqual({ pending: 1, completed: 1, remaining: 0 });
    expect((await env.FINDINGS.list({ prefix: `findings/${userId}/` })).objects).toEqual([]);
    const after = await env.DB.prepare('SELECT purged FROM user_state WHERE user_id = ?1')
      .bind(userId)
      .first<{ purged: number }>();
    expect(after).toEqual({ purged: 1 });
  });
});
