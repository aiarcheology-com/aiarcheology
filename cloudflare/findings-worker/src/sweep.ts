import { PURGE_WORST_CASE_SUBREQUESTS, purgeAccountMetered } from './purge';
import type { Env } from './env';

/// The subrequests one invocation may spend, in the unit the Worker is metered in.
///
/// 50 is the free plan's ceiling per invocation, and D1 states its own per-invocation query limit
/// in the same unit (50 on the free plan). The sweep starts a purge only while the budget still
/// covers a worst-case one (`PURGE_WORST_CASE_SUBREQUESTS`), so it never begins an account it
/// cannot finish: after the two initial fence queries that admits one large purge, or four empty
/// re-confirmations of four subrequests each. A fifth does not start because it must still reserve
/// the 33-subrequest worst case. Whether D1 counts a batch once or per statement is
/// not documented; counted per statement, four re-confirmations plus the final fence count are
/// 31 queries, still under 50.
const SUBREQUEST_BUDGET = 50;
const FINAL_FENCE_COUNT_SUBREQUESTS = 1;

/// More candidates than the budget can ever admit, so one query suffices and the pending set is
/// never materialised in full.
const CANDIDATE_LIMIT = 5;

export interface SweepResult {
  /// Accounts that were owed a purge and not yet confirmed when the run started.
  pending: number;
  /// How many of them this run confirmed clean.
  completed: number;
  /// What is still pending at the end of this run. This is the number an operator watches: one
  /// that does not fall across successive runs is the alertable condition.
  remaining: number;
}

/// Finishes purges that never completed.
///
/// A deletion normally completes on the `user.deleted` webhook. When it does not -- svix exhausts
/// its eight attempts, an account outgrows one invocation's batch budget, a purge dies mid-flight --
/// nothing else retries: the Clerk user is gone, so no client can authenticate, and svix's schedule
/// is finite.
///
/// This is that retry. It needs no credential and no notification: `user_state.purged = 0` behind
/// a fence is the record that a purge was owed and never confirmed (AIA-0842), written by the purge
/// itself before it touches anything and cleared only after a listing has shown the prefix empty.
/// It does not depend on index rows -- they are gone by the time a purge is confirmed -- so an
/// account with R2-only leftovers stays visible here until they are gone too.
///
/// Least-recently-attempted first. An account that fails every day moves to the back of the queue
/// after each attempt, so it cannot hold every later deletion behind it; fences that predate the
/// progress record have no attempt stamp and go first.
export async function sweepIncompleteFences(env: Env, now: number = Date.now()): Promise<SweepResult> {
  let used = 0;

  const count = await env.DB.prepare(
    'SELECT COUNT(*) AS n FROM user_state WHERE deleting = 1 AND purged = 0',
  ).first<{ n: number }>();
  used += 1;
  const pending = count?.n ?? 0;
  if (pending === 0) return { pending: 0, completed: 0, remaining: 0 };

  const candidates = await env.DB.prepare(
    `SELECT user_id AS userId FROM user_state
      WHERE deleting = 1 AND purged = 0
      ORDER BY purge_attempted_at ASC NULLS FIRST, user_id
      LIMIT ?1`,
  )
    .bind(CANDIDATE_LIMIT)
    .all<{ userId: string }>();
  used += 1;

  let completed = 0;
  for (const candidate of candidates.results ?? []) {
    // Keep room for the final authoritative count as well as the account itself. Without that
    // reservation a later change to the purge's cost could make the log query exceed the limit.
    if (used + PURGE_WORST_CASE_SUBREQUESTS + FINAL_FENCE_COUNT_SUBREQUESTS > SUBREQUEST_BUDGET) break;
    try {
      const result = await purgeAccountMetered(env, candidate.userId, now);
      used += result.subrequests;
      if (result.complete) completed += 1;
    } catch {
      // A storage error mid-purge. The account is still pending -- the purge marked it so before
      // touching anything -- and its attempt stamp sends it to the back of the queue. Charge the
      // worst case, since the failure left no count to trust; the budget check ends the run.
      used += PURGE_WORST_CASE_SUBREQUESTS;
    }
  }

  // An attempt can lose ownership of the fence between its opening write and completion. Count
  // the actual post-sweep state rather than deriving it from local results, so logs never call a
  // re-stamped or concurrently reopened fence clean.
  const remainingCount = await env.DB.prepare(
    'SELECT COUNT(*) AS n FROM user_state WHERE deleting = 1 AND purged = 0',
  ).first<{ n: number }>();

  return { pending, completed, remaining: remainingCount?.n ?? 0 };
}
