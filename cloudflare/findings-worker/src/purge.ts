import { ApiError } from './errors';
import type { Env } from './env';

/// How many R2 delete batches one invocation will run.
///
/// A Worker gets 50 subrequests on the free plan, and each list-and-delete round is two of them.
/// Stopping short and saying so is the difference between an incomplete purge the caller retries
/// and one that hits the wall and reports success.
const MAXIMUM_BATCHES = 15;
const OBJECTS_PER_BATCH = 500;

export interface PurgeResult {
  /// Whether everything this account had is gone. `false` means call again -- it does NOT mean
  /// the account may be deleted at Clerk, because the credential that reaches this data would go
  /// with it.
  complete: boolean;
  objects: number;
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
/// It re-lists after deleting the D1 rows rather than trusting the loop, because an upload whose
/// reservation predates the fence can still land after the last listing -- which is the whole
/// reason the webhook backstop exists.
export async function purgeAccount(env: Env, userId: string): Promise<PurgeResult> {
  await env.DB.prepare(
    `INSERT INTO user_state (user_id, deleting) VALUES (?1, 1)
       ON CONFLICT (user_id) DO UPDATE SET deleting = 1`,
  )
    .bind(userId)
    .run();

  const prefix = prefixFor(userId);
  let deleted = 0;

  for (let batch = 0; batch < MAXIMUM_BATCHES; batch += 1) {
    const listing = await env.FINDINGS.list({ prefix, limit: OBJECTS_PER_BATCH });
    if (listing.objects.length === 0) break;
    await env.FINDINGS.delete(listing.objects.map((object) => object.key));
    deleted += listing.objects.length;
    if (listing.truncated === false && batch + 1 < MAXIMUM_BATCHES) break;
  }

  // The index goes before the confirming listing, not after it. Between a clean listing and the
  // D1 wipe an upload whose reservation predates the fence could still land, and this order shrinks
  // that window to nothing that reports success: anything that arrives is caught by the re-list
  // below and turned into "call again". Deleting the rows first is safe because the fence refuses
  // every later write, so the retry has only R2 stragglers left to sweep.
  //
  // One transaction. The per-user row is dropped and the account-wide total recomputed from the
  // rows that remain, so the retry the webhook race makes routine cannot double-decrement.
  await env.DB.batch([
    env.DB.prepare("DELETE FROM counter WHERE key = 'user:' || ?1").bind(userId),
    env.DB.prepare(
      `UPDATE counter SET value =
         (SELECT COALESCE(SUM(value), 0) FROM counter WHERE key LIKE 'user:%') WHERE key = 'global_bytes'`,
    ),
    env.DB.prepare('DELETE FROM object_bytes WHERE user_id = ?1').bind(userId),
    env.DB.prepare('DELETE FROM finding_revision WHERE user_id = ?1').bind(userId),
    env.DB.prepare('DELETE FROM finding WHERE user_id = ?1').bind(userId),
  ]);

  const remaining = await env.FINDINGS.list({ prefix, limit: 1 });
  if (remaining.objects.length > 0) {
    // Deliberately retryable, and deliberately NOT complete. The caller must not delete the Clerk
    // user while anything is left: that would destroy the only credential able to name this data.
    throw new ApiError('internal', 'The purge did not finish; call again.', {
      purged: { objects: deleted },
      complete: false,
    });
  }

  return { complete: true, objects: deleted };
}
