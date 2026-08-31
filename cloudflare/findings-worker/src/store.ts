import { ApiError } from './errors';
import type { Env } from './env';

export type ObjectKind = 'meta' | 'image';

export interface FindingRow {
  id: string;
  modifiedAt: number;
  receivedAt: number;
  deleted: boolean;
  bytes: number;
  /// Whether the index names an image revision. A finding can legitimately have none, and a
  /// resurrected one has lost the image its delete removed.
  hasImage: boolean;
}

export interface Usage {
  used: number;
  limit: number;
}

interface StoredObject {
  userId: string;
  findingId: string;
  revision: number;
  kind: ObjectKind;
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

export function objectKey(userId: string, findingId: string, revision: number, kind: ObjectKind): string {
  return `findings/${userId}/${findingId}/${revision}/${kind === 'image' ? 'image.jpg' : 'meta.json'}`;
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

/// Per-user byte totals are DERIVED from `object_bytes` inside the writing transaction, and cached
/// in `counter` under `user:<id>` so a read does not have to sum anything. Object rows include live
/// revisions, superseded revisions and staged reservations: every one names bytes that may be in R2.
function userCounterKey(userId: string): string {
  return `user:${userId}`;
}

const RECOMPUTE_USER = `UPDATE counter SET value =
  (SELECT COALESCE(SUM(bytes), 0) FROM object_bytes WHERE user_id = ?2) WHERE key = ?1`;

const RECOMPUTE_GLOBAL = `UPDATE counter SET value =
  (SELECT COALESCE(SUM(value), 0) FROM counter WHERE key LIKE 'user:%') WHERE key = 'global_bytes'`;

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

/// Returns the immutable last-write-wins value for one client revision.
///
/// A timestamp at or before receipt time is already deterministic. Only a future timestamp needs
/// durable state: its first arrival is clamped to receipt time and every retry must reuse that
/// value. Otherwise a lost-response retry could become newer than a genuine later edit merely by
/// waiting for the server clock to catch up.
export async function modifiedAtForRevision(
  env: Env,
  userId: string,
  findingId: string,
  revision: number,
  now: number,
): Promise<number> {
  const stored = await env.DB.prepare(
    `SELECT lww_at AS modifiedAt FROM finding_revision
      WHERE user_id = ?1 AND finding_id = ?2 AND revision = ?3`,
  )
    .bind(userId, findingId, revision)
    .first<{ modifiedAt: number }>();
  if (stored !== null) return stored.modifiedAt;
  if (revision <= now) return revision;

  await env.DB
    .prepare(
      `INSERT INTO finding_revision (user_id, finding_id, revision, lww_at)
       SELECT ?1, ?2, ?3, ?4
        WHERE NOT EXISTS (SELECT 1 FROM user_state WHERE user_id = ?1 AND deleting = 1)
       ON CONFLICT (user_id, finding_id, revision) DO NOTHING`,
    )
    .bind(userId, findingId, revision, now)
    .run();

  const row = await env.DB.prepare(
    `SELECT lww_at AS modifiedAt FROM finding_revision
      WHERE user_id = ?1 AND finding_id = ?2 AND revision = ?3`,
  )
    .bind(userId, findingId, revision)
    .first<{ modifiedAt: number }>();
  if (row !== null) return row.modifiedAt;
  if (await isDeleting(env, userId)) {
    throw new ApiError('account_deleting', 'This account is being deleted.');
  }
  throw new ApiError('internal', 'The revision could not be assigned an ordering timestamp.');
}

export async function bytesForObject(
  env: Env,
  userId: string,
  findingId: string,
  revision: number,
  kind: ObjectKind,
): Promise<{ bytes: number; reapingAt: number | null } | null> {
  return env.DB
    .prepare(
      `SELECT bytes, reaping_at AS reapingAt FROM object_bytes
        WHERE user_id = ?1 AND finding_id = ?2 AND revision = ?3 AND kind = ?4`,
    )
    .bind(userId, findingId, revision, kind)
    .first<{ bytes: number; reapingAt: number | null }>();
}

/// Reserves storage for one immutable revision before it is written to R2.
///
/// An equal `modifiedAt` is the outbox's idempotency key. A retry retains the original reservation
/// time and may not silently change its byte size: R2 accepts this key only once, so accepting a
/// different body would make D1 account for bytes it cannot possibly publish. A changed body must
/// receive a new revision from the client.
export async function reserveBytes(
  env: Env,
  userId: string,
  findingId: string,
  revision: number,
  kind: ObjectKind,
  incoming: number,
  now: number,
): Promise<Usage> {
  const key = userCounterKey(userId);
  const existing = await bytesForObject(env, userId, findingId, revision, kind);
  if (existing?.reapingAt !== null && existing?.reapingAt !== undefined) {
    throw new ApiError('internal', 'This upload is being reclaimed; retry it shortly.');
  }
  if (existing !== null && existing.bytes !== incoming) {
    throw new ApiError('internal', 'A different upload already reserved this revision.');
  }

  const existingBytes = existing?.bytes ?? 0;
  const delta = incoming - existingBytes;
  const currentBytes = `COALESCE((SELECT bytes FROM object_bytes
    WHERE user_id = ?1 AND finding_id = ?2 AND revision = ?3 AND kind = ?4), 0)`;

  const results = await env.DB.batch([
    env.DB.prepare('INSERT INTO counter (key, value) VALUES (?1, 0) ON CONFLICT (key) DO NOTHING').bind(key),

    // The one gate. It checks the size this request observed, the account fence and both projected
    // quotas in the same statement that records the reservation. A reaper lease makes this update
    // refuse, so it can never delete an object a late retry is about to publish.
    env.DB
      .prepare(
        `INSERT INTO object_bytes (user_id, finding_id, revision, kind, bytes, created_at)
           SELECT ?1, ?2, ?3, ?4, ?5, ?6
            WHERE ${currentBytes} = ?7
              AND NOT EXISTS (SELECT 1 FROM user_state WHERE user_id = ?1 AND deleting = 1)
              AND (SELECT COALESCE(SUM(bytes), 0) FROM object_bytes WHERE user_id = ?1) - ?7 + ?5 <= ?8
              AND (SELECT COALESCE(SUM(value), 0) FROM counter WHERE key LIKE 'user:%' AND key <> ?10)
                  + (SELECT COALESCE(SUM(bytes), 0) FROM object_bytes WHERE user_id = ?1) - ?7 + ?5 <= ?9
           ON CONFLICT (user_id, finding_id, revision, kind) DO UPDATE SET
             created_at = object_bytes.created_at
           WHERE object_bytes.reaping_at IS NULL AND object_bytes.bytes = excluded.bytes`,
      )
      .bind(
        userId,
        findingId,
        revision,
        kind,
        incoming,
        now,
        existingBytes,
        env.USER_BYTE_LIMIT,
        env.GLOBAL_BYTE_CEILING,
        key,
      ),

    env.DB.prepare(RECOMPUTE_USER).bind(key, userId),
    env.DB.prepare(RECOMPUTE_GLOBAL),
  ]);

  const stored = results[1]?.meta.changes ?? 0;
  if (stored !== 1) {
    if (await isDeleting(env, userId)) {
      throw new ApiError('account_deleting', 'This account is being deleted.');
    }
    const current = await bytesForObject(env, userId, findingId, revision, kind);
    if (current?.reapingAt !== null && current?.reapingAt !== undefined) {
      throw new ApiError('internal', 'This upload is being reclaimed; retry it shortly.');
    }
    const usage = await usageFor(env, userId);
    if (usage.used + delta > env.USER_BYTE_LIMIT) {
      throw new ApiError('quota_exceeded', 'This account has no room left for that finding.', { usage });
    }
    if ((await globalBytes(env)) + delta > env.GLOBAL_BYTE_CEILING) {
      throw new ApiError('global_capacity', 'The service is at its storage ceiling. Try again later.');
    }
    throw new ApiError('internal', 'A concurrent write to the same finding interrupted this one.');
  }

  return usageFor(env, userId);
}

/// Whether this account is being erased.
///
/// Read only to explain a refusal. The refusal itself happens inside the write statements, because
/// a check that runs before the write is a race the purge wins.
export async function isDeleting(env: Env, userId: string): Promise<boolean> {
  const row = await env.DB.prepare('SELECT deleting FROM user_state WHERE user_id = ?1')
    .bind(userId)
    .first<{ deleting: number }>();
  return row?.deleting === 1;
}

const FINDING_COLUMNS = `f.id AS id, f.modified_at AS modifiedAt, f.received_at AS receivedAt, f.deleted AS deleted,
  COALESCE((SELECT bytes FROM object_bytes o
     WHERE o.user_id = f.user_id AND o.finding_id = f.id AND o.kind = 'meta'
       AND o.revision = f.meta_revision), 0)
  + COALESCE((SELECT bytes FROM object_bytes o
     WHERE o.user_id = f.user_id AND o.finding_id = f.id AND o.kind = 'image'
       AND o.revision = f.image_revision), 0) AS bytes,
  CASE WHEN f.image_revision IS NULL THEN 0 ELSE 1 END AS hasImage`;

interface RawFindingRow {
  id: string;
  modifiedAt: number;
  receivedAt: number;
  deleted: number;
  bytes: number;
  hasImage: number;
}

function toFindingRow(row: RawFindingRow): FindingRow {
  return { ...row, deleted: row.deleted === 1, hasImage: row.hasImage === 1 };
}

export async function findingRow(env: Env, userId: string, findingId: string): Promise<FindingRow | null> {
  const row = await env.DB.prepare(`SELECT ${FINDING_COLUMNS} FROM finding f WHERE f.user_id = ?1 AND f.id = ?2`)
    .bind(userId, findingId)
    .first<RawFindingRow>();
  return row === null ? null : toFindingRow(row);
}

/// Looks up the exact storage revision selected by a live finding. The route performs this lookup
/// before R2 reads, so it never guesses from a missing object or lets an uncommitted upload become
/// visible merely because its key happens to exist.
export async function objectReference(
  env: Env,
  userId: string,
  findingId: string,
  kind: ObjectKind,
): Promise<number | null> {
  const revisionColumn = kind === 'meta' ? 'meta_revision' : 'image_revision';
  const row = await env.DB.prepare(
    `SELECT ${revisionColumn} AS revision
       FROM finding WHERE user_id = ?1 AND id = ?2 AND deleted = 0`,
  )
    .bind(userId, findingId)
    .first<{ revision: number | null }>();
  if (row === null || row.revision === null) return null;
  return row.revision;
}

/// Commits a finding after its immutable metadata object is in R2. The index row names the winning
/// metadata revision and, when supplied, the matching image revision. Its compare-and-set means an
/// older revision can never publish itself over a newer index row.
export async function commitFinding(
  env: Env,
  userId: string,
  findingId: string,
  modifiedAt: number,
  deleted: boolean,
  now: number,
  revision = modifiedAt,
): Promise<FindingRow> {
  const incomingMeta = `EXISTS (SELECT 1 FROM object_bytes o
    WHERE o.user_id = ?1 AND o.finding_id = ?2 AND o.revision = ?5
      AND o.kind = 'meta' AND o.reaping_at IS NULL)`;
  const incomingImage = `EXISTS (SELECT 1 FROM object_bytes o
    WHERE o.user_id = ?1 AND o.finding_id = ?2 AND o.revision = ?5
      AND o.kind = 'image' AND o.reaping_at IS NULL)`;

  const statement = deleted
    ? `INSERT INTO finding (
         user_id, id, modified_at, received_at, deleted, meta_revision, image_revision
       )
       SELECT ?1, ?2, ?3,
              MAX(?4, COALESCE((SELECT MAX(received_at) FROM finding WHERE user_id = ?1), 0) + 1),
              1, NULL, NULL
        WHERE NOT EXISTS (SELECT 1 FROM user_state WHERE user_id = ?1 AND deleting = 1)
       ON CONFLICT (user_id, id) DO UPDATE SET
         modified_at = excluded.modified_at,
         received_at = excluded.received_at,
         deleted = 1,
         meta_revision = NULL,
         image_revision = NULL
       WHERE excluded.modified_at >= finding.modified_at`
    : `INSERT INTO finding (
         user_id, id, modified_at, received_at, deleted, meta_revision, image_revision
       )
       SELECT ?1, ?2, ?3,
              MAX(?4, COALESCE((SELECT MAX(received_at) FROM finding WHERE user_id = ?1), 0) + 1),
              0, ?5, CASE WHEN ${incomingImage} THEN ?5 ELSE NULL END
        WHERE NOT EXISTS (SELECT 1 FROM user_state WHERE user_id = ?1 AND deleting = 1)
          AND ${incomingMeta}
       ON CONFLICT (user_id, id) DO UPDATE SET
         modified_at = excluded.modified_at,
         received_at = excluded.received_at,
         deleted = 0,
         meta_revision = excluded.meta_revision,
         image_revision = CASE WHEN ${incomingImage} THEN excluded.image_revision ELSE finding.image_revision END
       WHERE excluded.modified_at >= finding.modified_at`;

  const bindings = deleted ? [userId, findingId, modifiedAt, now] : [userId, findingId, modifiedAt, now, revision];
  const committed = await env.DB.prepare(statement).bind(...bindings).run();
  if (committed.meta.changes !== 1) {
    if (await isDeleting(env, userId)) {
      throw new ApiError('account_deleting', 'This account is being deleted.');
    }
    const winner = await findingRow(env, userId, findingId);

    // Genuine staleness first, and it is decidable rather than guessed: the compare-and-set is
    // `excluded.modified_at >= finding.modified_at`, so a strictly older write is exactly the case
    // it refuses on ordering. Terminal is the right answer there -- no retry makes it newer.
    if (winner !== null && modifiedAt < winner.modifiedAt) {
      throw new ApiError('stale', 'A newer version of this finding is already stored.', { winner });
    }

    // Not older than the winner, so ordering cannot be why this was declined -- what failed was
    // `incomingMeta`, i.e. the reservation was reclaimed underneath an in-flight commit. Calling
    // that `stale` is not a cosmetic mislabel: `stale` is terminal, so the outbox would park an
    // edit that is genuinely the newest there is and name an older tombstone as its winner. The
    // revision bound in `reapUnreferencedObjectsForFinding` closes the race that made this common;
    // this keeps the answer honest for whatever still reaches it.
    if (deleted === false) {
      const reservation = await bytesForObject(env, userId, findingId, revision, 'meta');
      if (reservation === null || reservation.reapingAt !== null) {
        throw new ApiError('internal', 'This upload was reclaimed before it committed; retry it.');
      }
    }
    if (winner !== null) {
      throw new ApiError('stale', 'A newer version of this finding is already stored.', { winner });
    }
    throw new ApiError('internal', 'The finding could not be committed.');
  }

  const stored = await findingRow(env, userId, findingId);
  if (stored === null) {
    throw new ApiError('internal', 'The finding was written but could not be read back.');
  }
  return stored;
}

export interface Page {
  findings: FindingRow[];
  nextCursor: string | null;
  hasMore: boolean;
}

/// Keyset pagination over (received_at, id).
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
    `SELECT ${FINDING_COLUMNS}
       FROM finding f
      WHERE f.user_id = ?1 AND (f.received_at > ?2 OR (f.received_at = ?2 AND f.id > ?3))
      ORDER BY f.received_at ASC, f.id ASC
      LIMIT ?4`,
  )
    .bind(userId, afterReceived, afterId, limit + 1)
    .all<RawFindingRow>();

  const all = rows.results.map(toFindingRow);
  const hasMore = all.length > limit;
  const findings = hasMore ? all.slice(0, limit) : all;
  const last = findings[findings.length - 1];
  return {
    findings,
    nextCursor: last ? `${last.receivedAt}.${last.id}` : cursor,
    hasMore,
  };
}

/// A reservation is given a full day to finish image then metadata. The quarter-hourly cron normally
/// reclaims it within the following 15 minutes, while a crashed or uninstalled client can never
/// renew its lifetime by replaying the same revision.
export const STAGING_LIFETIME_MS = 24 * 60 * 60 * 1000;
const REAP_LEASE_MS = 15 * 60 * 1000;
const MAX_REAPED_OBJECTS_PER_RUN = 500;


const IS_ACTIVE_REFERENCE = `EXISTS (
  SELECT 1 FROM finding f
   WHERE f.user_id = object_bytes.user_id
     AND f.id = object_bytes.finding_id
     AND f.deleted = 0
     AND ((object_bytes.kind = 'meta'
           AND f.meta_revision = object_bytes.revision)
       OR (object_bytes.kind = 'image'
           AND f.image_revision = object_bytes.revision))
)`;

const CANDIDATE_IS_ACTIVE_REFERENCE = `EXISTS (
  SELECT 1 FROM finding f
   WHERE f.user_id = candidate.user_id
     AND f.id = candidate.finding_id
     AND f.deleted = 0
     AND ((candidate.kind = 'meta' AND f.meta_revision = candidate.revision)
       OR (candidate.kind = 'image' AND f.image_revision = candidate.revision))
)`;

export interface ReapResult {
  reaped: number;
  /// The batch was full, so another run may have more eligible objects to collect.
  atCapacity: boolean;
}

async function deleteClaimedObjects(env: Env, token: string): Promise<ReapResult> {
  const claimed = await env.DB.prepare(
    `SELECT user_id AS userId, finding_id AS findingId, revision, kind
       FROM object_bytes WHERE reaping_token = ?1`,
  )
    .bind(token)
    .all<StoredObject>();
  if (claimed.results.length === 0) return { reaped: 0, atCapacity: false };

  await env.FINDINGS.delete(
    claimed.results.map((candidate) => objectKey(candidate.userId, candidate.findingId, candidate.revision, candidate.kind)),
  );

  const users = [...new Set(claimed.results.map((candidate) => candidate.userId))];
  await env.DB.batch([
    // Recompute before deleting the claimed rows, excluding this lease. A concurrent reaper's
    // lease remains charged until that reaper actually deletes its R2 objects.
    ...users.map((userId) =>
      env.DB
        .prepare(
          `UPDATE counter SET value =
             (SELECT COALESCE(SUM(bytes), 0) FROM object_bytes
               WHERE user_id = ?2 AND (reaping_token IS NULL OR reaping_token <> ?3))
           WHERE key = ?1`,
        )
        .bind(userCounterKey(userId), userId, token),
    ),
    env.DB.prepare('DELETE FROM object_bytes WHERE reaping_token = ?1').bind(token),
    env.DB.prepare(RECOMPUTE_GLOBAL),
  ]);

  return { reaped: claimed.results.length, atCapacity: claimed.results.length === MAX_REAPED_OBJECTS_PER_RUN };
}

/// Reclaims staged reservations and revisions no longer referenced by a live index row.
///
/// D1 and R2 cannot share a transaction. Claiming a row with `reaping_at` before deleting its R2
/// key closes that gap: reservation and commit both refuse a claimed row, so no request can publish
/// the key after it has been selected for deletion. An abandoned claim becomes eligible again after
/// its short lease, making a crash in this Worker recoverable too.
export async function reapUnreferencedObjects(env: Env, now = Date.now()): Promise<ReapResult> {
  const cutoff = now - STAGING_LIFETIME_MS;
  const leaseCutoff = now - REAP_LEASE_MS;
  const token = crypto.randomUUID();
  await env.DB.prepare(
    `UPDATE object_bytes
        SET reaping_at = ?1, reaping_token = ?2
      WHERE rowid IN (
        SELECT candidate.rowid FROM object_bytes candidate
         WHERE candidate.created_at <= ?3
           AND (candidate.reaping_at IS NULL OR candidate.reaping_at <= ?4)
           AND NOT ${CANDIDATE_IS_ACTIVE_REFERENCE}
         ORDER BY candidate.created_at ASC
         LIMIT ?5
      )
        AND (reaping_at IS NULL OR reaping_at <= ?4)
        AND NOT ${IS_ACTIVE_REFERENCE}`,
  )
    .bind(now, token, cutoff, leaseCutoff, MAX_REAPED_OBJECTS_PER_RUN)
    .run();
  return deleteClaimedObjects(env, token);
}

/// Deletes the revisions a tombstone made unreachable without touching a finding that has since
/// been resurrected. The same D1 claim used by scheduled cleanup is the hand-off to R2 deletion:
/// a later metadata commit sees the lease and cannot publish a row this deletion is about to erase.
///
/// `belowRevision` is the tombstone's own ordering value, and it is what keeps this from reaping an
/// upload that is still in flight. The scheduled reaper is protected by `STAGING_LIFETIME_MS` --
/// nothing younger than a day is ever a candidate -- but a tombstone makes a *fresh* reservation
/// unreferenced the instant it commits, so this path had no floor at all. Device A uploads an image
/// and then its metadata while device B deletes the same finding:
///
///   * claim between A's `reserveBytes` and `commitFinding` and A's commit fails `incomingMeta`,
///     which reported terminal `stale` naming B's older tombstone as the winner -- a genuinely
///     newer edit parked forever, when a hundred milliseconds the other way would have resurrected
///     it;
///   * claim only A's image row and A's metadata commit SUCCEEDS with `image_revision = NULL` --
///     200 returned, photograph silently reaped.
///
/// A time-based grace window would have fixed both and broken something else: a delete must return
/// the bytes to the user's quota *now*, or "storage full -- delete findings you no longer need" is
/// advice that does not work. The revision bound costs nothing there. A revision at or above the
/// tombstone can still win the commit compare-and-set and resurrect the finding, so it is left
/// alone; everything strictly below it lost to this tombstone already and is collected immediately,
/// which is every revision the deleted finding itself owned. The few rows this declines are not
/// leaked, only deferred to the scheduled reaper.
export async function reapUnreferencedObjectsForFinding(
  env: Env,
  userId: string,
  findingId: string,
  belowRevision: number,
  now = Date.now(),
): Promise<ReapResult> {
  const leaseCutoff = now - REAP_LEASE_MS;
  const token = crypto.randomUUID();
  await env.DB.prepare(
    `UPDATE object_bytes
        SET reaping_at = ?1, reaping_token = ?2
      WHERE rowid IN (
        SELECT candidate.rowid FROM object_bytes candidate
         WHERE candidate.user_id = ?3 AND candidate.finding_id = ?4
           AND candidate.revision < ?7
           AND (candidate.reaping_at IS NULL OR candidate.reaping_at <= ?5)
           AND NOT ${CANDIDATE_IS_ACTIVE_REFERENCE}
         ORDER BY candidate.created_at ASC
         LIMIT ?6
      )
        AND revision < ?7
        AND (reaping_at IS NULL OR reaping_at <= ?5)
        AND NOT ${IS_ACTIVE_REFERENCE}`,
  )
    .bind(now, token, userId, findingId, leaseCutoff, MAX_REAPED_OBJECTS_PER_RUN, belowRevision)
    .run();
  return deleteClaimedObjects(env, token);
}
