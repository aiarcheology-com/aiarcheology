import { purgeAccount } from './purge';
import type { Env } from './env';

/// How many accounts one sweep run will purge.
///
/// One, deliberately. `purgeAccount` can spend 32 subrequests on a large account (15 list-and-delete
/// rounds, the D1 batch, the confirming list) against a budget of 50, so a second purge in the same
/// invocation could hit the wall mid-account. A cron that clears one straggler per run and says how
/// many are left beats one that clears two and truncates the third.
const ACCOUNTS_PER_RUN = 1;

export interface SweepResult {
  /// Fences whose data had not fully gone when the sweep started.
  incomplete: number;
  /// Whether the account this run picked up is now clean. `null` when there was nothing to do.
  purged: boolean | null;
}

/// Finishes purges that never completed.
///
/// A deletion normally completes on the `user.deleted` webhook. When it does not -- svix exhausts
/// its eight attempts, an upload lands after the confirming list, a purge dies mid-flight -- the
/// fence row survives and the leftovers do not. Nothing then retries: the Clerk user is gone, so no
/// client can authenticate, and svix's schedule is finite.
///
/// This is that retry. It needs no credential and no notification: the fence row is the record that
/// a purge was owed, and `purgeAccount` is idempotent, so re-running it on a clean account is a
/// no-op and re-running it on a dirty one finishes the job.
///
/// **The fence is the source of truth, not a report of failure.** A fence with rows behind it means
/// the purge did not finish, whatever the webhook answered at the time.
export async function sweepIncompleteFences(env: Env): Promise<SweepResult> {
  // Fences that still have index rows. R2-only stragglers -- an object written after the confirming
  // list, whose metadata never committed -- are not visible here, which is why the purge this
  // dispatches re-lists R2 rather than trusting D1.
  const candidates = await env.DB.prepare(
    `SELECT s.user_id AS userId FROM user_state s
      WHERE s.deleting = 1
        AND (EXISTS (SELECT 1 FROM finding f WHERE f.user_id = s.user_id)
          OR EXISTS (SELECT 1 FROM object_bytes o WHERE o.user_id = s.user_id)
          OR EXISTS (SELECT 1 FROM counter c WHERE c.key = 'user:' || s.user_id))
      ORDER BY s.user_id`,
  ).all<{ userId: string }>();

  const incomplete = candidates.results?.length ?? 0;
  if (incomplete === 0) return { incomplete: 0, purged: null };

  const next = candidates.results?.slice(0, ACCOUNTS_PER_RUN)[0];
  if (next === undefined) return { incomplete, purged: null };

  try {
    const result = await purgeAccount(env, next.userId);
    return { incomplete, purged: result.complete };
  } catch {
    // A purge that cannot finish in one run throws by design. The fence stays, so the next run
    // picks the same account up again -- which is the whole mechanism, not a failure of it.
    return { incomplete, purged: false };
  }
}
