import { ApiError } from './errors';
import type { Env } from './env';

export type ObjectKind = 'meta' | 'image';

export interface FindingRow {
  id: string;
  modifiedAt: number;
  receivedAt: number;
  deleted: boolean;
  bytes: number;
  /// Whether an image is actually stored. A finding can legitimately have none, and a resurrected
  /// one has lost the image its delete removed -- without this the client would have no way to
  /// tell either case from a broken download.
  hasImage: boolean;
}

export interface Usage {
  used: number;
  limit: number;
}

/// Clerk user ids and finding ids both land in an R2 key, so both are validated before a key is
/// built rather than sanitised afterwards. Findings are UUIDs on the client; anything else is a
/// client bug, not a shape to accommodate.
const FINDING_ID = /^[A-Za-z0-9-]{1,64}$/;

export function requireFindingId(raw: string | undefined): string {
  if (!raw || !FINDING_ID.test(raw)) {
    throw new ApiError('bad_request', 'The finding id is missing or malformed.');
  }
  return raw;
}

export function objectKey(userId: string, findingId: string, kind: ObjectKind): string {
  return `findings/${userId}/${findingId}/${kind === 'image' ? 'image.jpg' : 'meta.json'}`;
}

/// Reads the whole body, refusing the moment it exceeds `cap`.
///
/// `Content-Length` is never trusted, so the cap has to be enforced against bytes actually read.
///
/// The body is buffered rather than streamed into R2 because refusing an over-cap upload before
/// anything reaches the bucket is the simplest thing that is obviously correct -- not because a
/// streamed `put` would leave a partial object; R2 does not publish an aborted one. The cost is
/// memory: the Worker's 128 MB is shared across concurrent requests in an isolate, so enough
/// simultaneous 16 MB uploads could exhaust it. Streaming through a counting transform is the
/// answer if that ever shows up; at this scale it has not.
export async function readBodyWithCap(request: Request, cap: number): Promise<Uint8Array> {
  const body = request.body;
  if (body === null) {
    throw new ApiError('bad_request', 'The request has no body.');
  }

  const reader = body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > cap) {
        await reader.cancel();
        throw new ApiError('payload_too_large', `The body exceeds the ${cap} byte limit.`, { limit: cap });
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }

  const buffer = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    buffer.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return buffer;
}

/// Per-user byte totals live in `counter` under `user:<id>`, not as a SUM over `object_bytes`.
///
/// A SUM cannot be made part of an atomic reservation: reading it, checking it, then writing is a
/// race two devices on one account will lose -- and two devices on one account is the entire
/// reason this Worker exists.
function userCounterKey(userId: string): string {
  return `user:${userId}`;
}

export async function usageFor(env: Env, userId: string): Promise<Usage> {
  const row = await env.DB.prepare('SELECT value FROM counter WHERE key = ?1')
    .bind(userCounterKey(userId))
    .first<{ value: number }>();
  return { used: row?.value ?? 0, limit: env.USER_BYTE_LIMIT };
}

async function globalBytes(env: Env): Promise<number> {
  const row = await env.DB.prepare("SELECT value FROM counter WHERE key = 'global_bytes'").first<{
    value: number;
  }>();
  return row?.value ?? 0;
}

async function bytesForObject(env: Env, userId: string, findingId: string, kind: ObjectKind): Promise<number> {
  const row = await env.DB.prepare(
    'SELECT bytes FROM object_bytes WHERE user_id = ?1 AND finding_id = ?2 AND kind = ?3',
  )
    .bind(userId, findingId, kind)
    .first<{ bytes: number }>();
  return row?.bytes ?? 0;
}

/// Reserves storage for an object that is about to be written, and records its size.
///
/// The size record and both counters move in ONE D1 batch, which is one transaction. Splitting them
/// is what makes a counter drift: if the counter rises and the size record does not, the next retry
/// of the same upload computes its delta against a stale size and adds the bytes again -- for ever,
/// account-wide, with no reconciliation path. Inside one transaction a retry recomputes a delta of
/// zero and changes nothing.
///
/// All four statements share one guard, so they apply together or not at all:
/// - the object's recorded size must still be what this call measured (optimistic concurrency, so
///   two writers racing the same object cannot both apply their delta), and
/// - neither the user's total nor the account's may cross its limit.
///
/// The guard is written so ordering inside the transaction keeps it consistent: the size row is
/// written first while the counters still hold their pre-update values, and the counter statements
/// then key off the size row already carrying the new value.
///
/// Accounting still runs BEFORE the R2 write. A failed write over-counts, which is the safe
/// direction for a cost guard and is corrected by the next successful write or delete; accounting
/// afterwards would under-count exactly when a crash left the bytes in the bucket.
export async function reserveBytes(
  env: Env,
  userId: string,
  findingId: string,
  kind: ObjectKind,
  incoming: number,
): Promise<Usage> {
  const key = userCounterKey(userId);
  const existing = await bytesForObject(env, userId, findingId, kind);
  const delta = incoming - existing;

  const currentBytes = `COALESCE((SELECT bytes FROM object_bytes WHERE user_id = ?1 AND finding_id = ?2 AND kind = ?3), 0)`;

  const results = await env.DB.batch([
    // A user's counter row is created on first sight. It has to exist before the guard reads it:
    // a missing row makes the comparison NULL, and the write would be refused rather than allowed.
    env.DB.prepare('INSERT INTO counter (key, value) VALUES (?1, 0) ON CONFLICT (key) DO NOTHING').bind(key),

    env.DB
      .prepare(
        `INSERT INTO object_bytes (user_id, finding_id, kind, bytes)
           SELECT ?1, ?2, ?3, ?4
            WHERE ${currentBytes} = ?5
              AND COALESCE((SELECT value FROM counter WHERE key = ?6), 0) + ?7 <= ?8
              AND COALESCE((SELECT value FROM counter WHERE key = 'global_bytes'), -1) + ?7 <= ?9
           ON CONFLICT (user_id, finding_id, kind) DO UPDATE SET bytes = excluded.bytes`,
      )
      .bind(userId, findingId, kind, incoming, existing, key, delta, env.USER_BYTE_LIMIT, env.GLOBAL_BYTE_CEILING),

    env.DB
      .prepare(`UPDATE counter SET value = value + ?4 WHERE key = ?5 AND ${currentBytes} = ?6`)
      .bind(userId, findingId, kind, delta, key, incoming),

    env.DB
      .prepare(
        `UPDATE counter SET value = value + ?4 WHERE key = 'global_bytes' AND ${currentBytes} = ?5`,
      )
      .bind(userId, findingId, kind, delta, incoming),
  ]);

  const stored = results[1]?.meta.changes ?? 0;
  if (stored !== 1 && delta !== 0) {
    // Nothing was written. Report which limit refused it, reading the counters rather than
    // guessing, so the client gets an error it can act on.
    const usage = await usageFor(env, userId);
    if (usage.used + delta > env.USER_BYTE_LIMIT) {
      throw new ApiError('quota_exceeded', 'This account has no room left for that finding.', {
        usage,
      });
    }
    if ((await globalBytes(env)) + delta > env.GLOBAL_BYTE_CEILING) {
      throw new ApiError('global_capacity', 'The service is at its storage ceiling. Try again later.');
    }
    // The object's recorded size changed underneath this call: another write for the same finding
    // is in flight. Retrying is the right answer.
    throw new ApiError('internal', 'A concurrent write to the same finding interrupted this one.');
  }

  return usageFor(env, userId);
}

/// Releases every byte recorded for a finding. Without this a delete would free space in the bucket
/// but not in the quota, and "storage full -- prune findings" would be advice that does not work.
export async function releaseBytes(env: Env, userId: string, findingId: string): Promise<void> {
  const row = await env.DB.prepare(
    'SELECT COALESCE(SUM(bytes), 0) AS total FROM object_bytes WHERE user_id = ?1 AND finding_id = ?2',
  )
    .bind(userId, findingId)
    .first<{ total: number }>();
  const total = row?.total ?? 0;
  if (total === 0) return;

  await env.DB.batch([
    env.DB
      .prepare('UPDATE counter SET value = MAX(0, value - ?2) WHERE key = ?1')
      .bind(userCounterKey(userId), total),
    env.DB.prepare("UPDATE counter SET value = MAX(0, value - ?1) WHERE key = 'global_bytes'").bind(total),
    env.DB.prepare('DELETE FROM object_bytes WHERE user_id = ?1 AND finding_id = ?2').bind(userId, findingId),
  ]);
}

export async function findingRow(env: Env, userId: string, findingId: string): Promise<FindingRow | null> {
  const row = await env.DB.prepare(
    `SELECT f.id AS id, f.modified_at AS modifiedAt, f.received_at AS receivedAt, f.deleted AS deleted,
            COALESCE((SELECT SUM(bytes) FROM object_bytes o WHERE o.user_id = f.user_id AND o.finding_id = f.id), 0) AS bytes,
            EXISTS(SELECT 1 FROM object_bytes o WHERE o.user_id = f.user_id AND o.finding_id = f.id AND o.kind = 'image') AS hasImage
       FROM finding f WHERE f.user_id = ?1 AND f.id = ?2`,
  )
    .bind(userId, findingId)
    .first<{
      id: string;
      modifiedAt: number;
      receivedAt: number;
      deleted: number;
      bytes: number;
      hasImage: number;
    }>();
  return row ? { ...row, deleted: row.deleted === 1, hasImage: row.hasImage === 1 } : null;
}


/// Commits a finding: the index row is written last, after both objects are in R2, so a crash can
/// only ever leave orphan bytes (which the next retry overwrites) and never an index row pointing
/// at an object that is not there.
export async function commitFinding(
  env: Env,
  userId: string,
  findingId: string,
  modifiedAt: number,
  deleted: boolean,
  now: number,
): Promise<FindingRow> {
  // `received_at` is computed inside the INSERT rather than read and then written.
  //
  // A SELECT MAX followed by a separate INSERT lets two concurrent writes for one user be handed
  // the SAME receipt value. The (received_at, id) cursor only keeps tied rows safe while both are
  // visible when a client crosses them -- if one commits after a client has already paged past that
  // instant, it is invisible for ever. One statement is what makes the clock strictly increasing.
  await env.DB.prepare(
    `INSERT INTO finding (user_id, id, modified_at, received_at, deleted)
       VALUES (?1, ?2, ?3,
               MAX(?4, COALESCE((SELECT MAX(received_at) FROM finding WHERE user_id = ?1), 0) + 1),
               ?5)
       ON CONFLICT (user_id, id) DO UPDATE SET
         modified_at = excluded.modified_at,
         received_at = excluded.received_at,
         deleted     = excluded.deleted`,
  )
    .bind(userId, findingId, modifiedAt, now, deleted ? 1 : 0)
    .run();

  const committed = await findingRow(env, userId, findingId);
  if (committed === null) {
    throw new ApiError('internal', 'The finding was written but could not be read back.');
  }
  return committed;
}

export interface Page {
  findings: FindingRow[];
  nextCursor: string | null;
  hasMore: boolean;
}

/// Keyset pagination over (received_at, id).
///
/// The pair, not `received_at` alone, is the cursor: two findings can share a receipt instant, and
/// a page boundary falling between them would drop one for ever if the cursor could not tell them
/// apart.
export async function listSince(env: Env, userId: string, cursor: string | null, limit: number): Promise<Page> {
  let afterReceived = 0;
  let afterId = '';
  if (cursor !== null) {
    const split = cursor.indexOf('.');
    const received = Number(split === -1 ? cursor : cursor.slice(0, split));
    if (!Number.isFinite(received) || received < 0) {
      throw new ApiError('bad_request', 'The cursor is malformed.');
    }
    afterReceived = received;
    afterId = split === -1 ? '' : cursor.slice(split + 1);
  }

  const rows = await env.DB.prepare(
    `SELECT f.id AS id, f.modified_at AS modifiedAt, f.received_at AS receivedAt, f.deleted AS deleted,
            COALESCE((SELECT SUM(bytes) FROM object_bytes o WHERE o.user_id = f.user_id AND o.finding_id = f.id), 0) AS bytes,
            EXISTS(SELECT 1 FROM object_bytes o WHERE o.user_id = f.user_id AND o.finding_id = f.id AND o.kind = 'image') AS hasImage
       FROM finding f
      WHERE f.user_id = ?1 AND (f.received_at > ?2 OR (f.received_at = ?2 AND f.id > ?3))
      ORDER BY f.received_at ASC, f.id ASC
      LIMIT ?4`,
  )
    .bind(userId, afterReceived, afterId, limit + 1)
    .all<{
      id: string;
      modifiedAt: number;
      receivedAt: number;
      deleted: number;
      bytes: number;
      hasImage: number;
    }>();

  const all = rows.results.map((row) => ({
    ...row,
    deleted: row.deleted === 1,
    hasImage: row.hasImage === 1,
  }));
  const hasMore = all.length > limit;
  const findings = hasMore ? all.slice(0, limit) : all;
  const last = findings[findings.length - 1];
  return {
    findings,
    nextCursor: last ? `${last.receivedAt}.${last.id}` : cursor,
    hasMore,
  };
}
