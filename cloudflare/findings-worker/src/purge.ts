import { ApiError } from './errors';
import type { Env } from './env';

/// How many R2 delete batches one invocation will run.
///
/// A Worker gets 50 subrequests on the free plan, and each list-and-delete round is two of them.
/// Stopping short and saying so is the difference between an incomplete purge the caller retries
/// and one that hits the wall and reports success.
const MAXIMUM_BATCHES = 15;
const OBJECTS_PER_BATCH = 500;

/// The most subrequests one purge can spend: the opening stamp, a list and a delete per batch, the
/// confirming list, and the completing D1 batch. The sweep budgets against this before it starts
/// an account, so it never begins a purge it cannot finish.
export const PURGE_WORST_CASE_SUBREQUESTS = 1 + 2 * MAXIMUM_BATCHES + 1 + 1;

export interface PurgeResult {
  /// Whether everything this account had is gone. `false` means call again -- it does NOT mean
  /// the account may be deleted at Clerk, because the credential that reaches this data would go
  /// with it.
  complete: boolean;
  objects: number;
}

/// `PurgeResult` plus what the purge cost. Internal to the sweep's budgeting; the routes return
/// the public shape and never expose the counter.
export interface MeteredPurgeResult extends PurgeResult {
  subrequests: number;
  /// Whether this attempt's completion mark landed on the fence row -- distinct from `complete`.
  ///
  /// Two attempts overlap routinely (app and webhook), and their millisecond timestamps can
  /// coincide, so the mark is conditional on the attempt's own random ID: if a later attempt
  /// re-stamped the row and then died, an earlier one finishing must not close the record over
  /// it. That earlier attempt still answers `complete: true` -- it saw the prefix empty behind the
  /// fence, which is all its caller needs before the Clerk user goes -- and the sweep closes the
  /// record at the cost of an empty purge. Answering "call again" instead would make the routine
  /// overlap a retryable failure for one of the two callers.
  marked: boolean;
}

/// The prefix a user's objects live under.
///
/// The trailing slash is load-bearing: without it `user_1` is a prefix of `user_12`, and a purge
/// would delete a different account's findings.
function prefixFor(userId: string): string {
  return `findings/${userId}/`;
}

/// Erases one account's findings: objects first, then the index.
///
/// **Idempotent by construction.** The fence is set first and never cleared, so a second call finds
/// nothing to delete and answers `complete` again. That matters more than it sounds: `user.delete()`
/// fires Clerk's `user.deleted` webhook, so an in-app deletion normally runs this twice at once.
///
/// A purge that could not finish throws, deliberately retryable and deliberately NOT complete. The
/// caller must not delete the Clerk user while anything is left: that would destroy the only
/// credential able to name this data. Whether or not anyone retries, the account stays pending in
/// `user_state` and the daily sweep finishes it (AIA-0842).
export async function purgeAccount(env: Env, userId: string): Promise<PurgeResult> {
  const { complete, objects } = await purgeAccountMetered(env, userId, Date.now());
  if (!complete) {
    throw new ApiError('internal', 'The purge did not finish; call again.', {
      purged: { objects },
      complete: false,
    });
  }
  return { complete, objects };
}

/// The purge itself, reporting its cost instead of throwing on incomplete.
///
/// **The progress record lives on the fence row, not in the rows being erased.** The first
/// statement sets the fence, marks the purge pending and stamps the attempt; the completing batch
/// is the ONLY thing that marks it done, and it runs only after a listing has shown the prefix
/// empty. Every crash point in between leaves `purged = 0`, which is exactly what the sweep
/// selects -- so unfinished work cannot disappear from recovery, whatever the D1 rows say.
///
/// The index goes AFTER the confirming listing, in the same batch as the completion mark. Deleting
/// the rows first released the account's quota before its storage was confirmed gone, so an
/// incomplete purge left real bytes in R2 that no longer counted toward the account-wide ceiling.
/// Now the per-user counter is dropped, the global total recomputed from the rows that remain, and
/// the purge marked complete in one transaction -- so the retry the webhook race makes routine
/// cannot double-decrement, and quota and storage are released together. An upload whose
/// reservation predates the fence can still land after the listing in either order; that is what
/// `refuseIfAccountVanished` in index.ts is for.
///
/// The completion mark is conditional on this attempt's own ID; the answer is not. See
/// `MeteredPurgeResult.marked`.
export async function purgeAccountMetered(
  env: Env,
  userId: string,
  attemptedAt: number,
): Promise<MeteredPurgeResult> {
  let subrequests = 0;
  const attemptId = crypto.randomUUID();

  await env.DB.prepare(
    `INSERT INTO user_state (user_id, deleting, purged, purge_attempted_at, purge_attempt_id)
       VALUES (?1, 1, 0, ?2, ?3)
       ON CONFLICT (user_id) DO UPDATE SET deleting = 1, purged = 0,
         purge_attempted_at = ?2, purge_attempt_id = ?3`,
  )
    .bind(userId, attemptedAt, attemptId)
    .run();
  subrequests += 1;

  const prefix = prefixFor(userId);
  let deleted = 0;

  for (let batch = 0; batch < MAXIMUM_BATCHES; batch += 1) {
    const listing = await env.FINDINGS.list({ prefix, limit: OBJECTS_PER_BATCH });
    subrequests += 1;
    if (listing.objects.length === 0) break;
    await env.FINDINGS.delete(listing.objects.map((object) => object.key));
    subrequests += 1;
    deleted += listing.objects.length;
    if (listing.truncated === false && batch + 1 < MAXIMUM_BATCHES) break;
  }

  const remaining = await env.FINDINGS.list({ prefix, limit: 1 });
  subrequests += 1;
  if (remaining.objects.length > 0) {
    return { complete: false, objects: deleted, subrequests, marked: false };
  }

  const cleanup = await env.DB.batch([
    env.DB.prepare("DELETE FROM counter WHERE key = 'user:' || ?1").bind(userId),
    env.DB.prepare(
      `UPDATE counter SET value =
         (SELECT COALESCE(SUM(value), 0) FROM counter WHERE key LIKE 'user:%') WHERE key = 'global_bytes'`,
    ),
    env.DB.prepare('DELETE FROM object_bytes WHERE user_id = ?1').bind(userId),
    env.DB.prepare('DELETE FROM finding_revision WHERE user_id = ?1').bind(userId),
    env.DB.prepare('DELETE FROM finding WHERE user_id = ?1').bind(userId),
    env.DB
      .prepare(
        'UPDATE user_state SET purged = 1 WHERE user_id = ?1 AND purge_attempted_at = ?2 AND purge_attempt_id = ?3',
      )
      .bind(userId, attemptedAt, attemptId),
  ]);
  subrequests += 1;

  // The cleanup batch removes the now-known-empty rows either way; see `marked`.
  const marked = cleanup[cleanup.length - 1]?.meta.changes === 1;
  return { complete: true, objects: deleted, subrequests, marked };
}
