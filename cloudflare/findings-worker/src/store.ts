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
  bytes: number;
  createdAt: number;
}

type ReapCandidate = StoredObject;

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

async function bytesForObject(
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
/// An equal `modifiedAt` is the outbox's idempotency key. A retry may renew the reservation, but it
/// may not silently change its byte size: R2 accepts this key only once, so accepting a different
/// body would make D1 account for bytes it cannot possibly publish. A changed body must receive a
/// new revision from the client.
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
             created_at = excluded.created_at
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

/// Releases every revision recorded for a finding. The caller tombstones it and removes the R2
/// prefix first; this only releases the quota after that durable deletion succeeds.
export async function releaseBytes(env: Env, userId: string, findingId: string): Promise<void> {
  await env.DB.batch([
    env.DB.prepare('DELETE FROM object_bytes WHERE user_id = ?1 AND finding_id = ?2').bind(userId, findingId),
    env.DB.prepare(RECOMPUTE_USER).bind(userCounterKey(userId), userId),
    env.DB.prepare(RECOMPUTE_GLOBAL),
  ]);
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

/// A reservation is given a full day to finish image then metadata. The daily cron makes the true
/// maximum just under two days, while a crashed or uninstalled client can never hold quota forever.
export const STAGING_LIFETIME_MS = 24 * 60 * 60 * 1000;
const REAP_LEASE_MS = 15 * 60 * 1000;
const MAX_REAPED_OBJECTS_PER_RUN = 20;

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

/// Reclaims staged reservations and revisions no longer referenced by a live index row.
///
/// D1 and R2 cannot share a transaction. Claiming a row with `reaping_at` before deleting its R2
/// key closes that gap: reservation and commit both refuse a claimed row, so no request can publish
/// the key after it has been selected for deletion. An abandoned claim becomes eligible again after
/// its short lease, making a crash in this Worker recoverable too.
export async function reapUnreferencedObjects(env: Env, now = Date.now()): Promise<number> {
  const cutoff = now - STAGING_LIFETIME_MS;
  const leaseCutoff = now - REAP_LEASE_MS;
  const candidates = await env.DB.prepare(
    `SELECT user_id AS userId, finding_id AS findingId, revision, kind, bytes, created_at AS createdAt
       FROM object_bytes
      WHERE created_at <= ?1
        AND (reaping_at IS NULL OR reaping_at <= ?2)
        AND NOT ${IS_ACTIVE_REFERENCE}
      ORDER BY created_at ASC
      LIMIT ?3`,
  )
    .bind(cutoff, leaseCutoff, MAX_REAPED_OBJECTS_PER_RUN)
    .all<ReapCandidate>();

  const claimed: StoredObject[] = [];
  for (const candidate of candidates.results) {
    const claim = await env.DB.prepare(
      `UPDATE object_bytes SET reaping_at = ?5
        WHERE user_id = ?1 AND finding_id = ?2 AND revision = ?3 AND kind = ?4
          AND created_at <= ?6
          AND (reaping_at IS NULL OR reaping_at <= ?7)
          AND NOT ${IS_ACTIVE_REFERENCE}`,
    )
      .bind(
        candidate.userId,
        candidate.findingId,
        candidate.revision,
        candidate.kind,
        now,
        cutoff,
        leaseCutoff,
      )
      .run();
    if (claim.meta.changes === 1) {
      claimed.push(candidate);
    }
  }

  if (claimed.length === 0) return 0;

  await env.FINDINGS.delete(
    claimed.map((candidate) => objectKey(candidate.userId, candidate.findingId, candidate.revision, candidate.kind)),
  );

  const users = [...new Set(claimed.map((candidate) => candidate.userId))];
  await env.DB.batch([
    ...claimed.map((candidate) =>
      env.DB
        .prepare(
          `DELETE FROM object_bytes
            WHERE user_id = ?1 AND finding_id = ?2 AND revision = ?3 AND kind = ?4 AND reaping_at = ?5`,
        )
        .bind(candidate.userId, candidate.findingId, candidate.revision, candidate.kind, now),
    ),
    ...users.map((userId) => env.DB.prepare(RECOMPUTE_USER).bind(userCounterKey(userId), userId)),
    env.DB.prepare(RECOMPUTE_GLOBAL),
  ]);
  return claimed.length;
}
