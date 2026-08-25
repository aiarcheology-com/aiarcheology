import { ApiError } from './errors';
import type { Env } from './env';

export type ObjectKind = 'meta' | 'image';

export interface FindingRow {
  id: string;
  modifiedAt: number;
  receivedAt: number;
  deleted: boolean;
  bytes: number;
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
/// The body is buffered rather than streamed into R2 because an aborted streaming `put` leaves a
/// partial object behind: there is no way to un-write it. Both caps sit far under the Worker's
/// 128 MB memory limit.
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

export async function usageFor(env: Env, userId: string): Promise<Usage> {
  const row = await env.DB.prepare('SELECT COALESCE(SUM(bytes), 0) AS used FROM object_bytes WHERE user_id = ?1')
    .bind(userId)
    .first<{ used: number }>();
  return { used: row?.used ?? 0, limit: env.USER_BYTE_LIMIT };
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
/// Accounting runs BEFORE the R2 write on purpose. If the write then fails, the account is
/// over-counted, which is the safe direction for a cost guard and self-heals on the client's retry;
/// accounting afterwards would under-count exactly when a crash left the bytes in the bucket.
///
/// Replacing an object charges only the delta, so re-uploading the same finding cannot walk a user
/// over their cap.
export async function reserveBytes(
  env: Env,
  userId: string,
  findingId: string,
  kind: ObjectKind,
  incoming: number,
): Promise<Usage> {
  const existing = await bytesForObject(env, userId, findingId, kind);
  const delta = incoming - existing;
  const usage = await usageFor(env, userId);

  if (usage.used + delta > env.USER_BYTE_LIMIT) {
    throw new ApiError('quota_exceeded', 'This account has no room left for that finding.', {
      usage: { used: usage.used, limit: env.USER_BYTE_LIMIT },
    });
  }

  // One conditional statement is both the ceiling check and the reservation, so two uploads
  // racing cannot each read "under the ceiling" and both proceed. A missing counter row changes
  // nothing and reports 0 -- which is why the migration seeds it and this treats 0 as a refusal.
  const reserved = await env.DB.prepare(
    `UPDATE counter SET value = value + ?1
      WHERE key = 'global_bytes' AND value + ?1 <= ?2`,
  )
    .bind(delta, env.GLOBAL_BYTE_CEILING)
    .run();

  if (reserved.meta.changes !== 1) {
    throw new ApiError('global_capacity', 'The service is at its storage ceiling.');
  }

  await env.DB.prepare(
    `INSERT INTO object_bytes (user_id, finding_id, kind, bytes) VALUES (?1, ?2, ?3, ?4)
       ON CONFLICT (user_id, finding_id, kind) DO UPDATE SET bytes = excluded.bytes`,
  )
    .bind(userId, findingId, kind, incoming)
    .run();

  return { used: usage.used + delta, limit: env.USER_BYTE_LIMIT };
}

/// Releases every byte recorded for a finding. Without this a delete would free space in the bucket
/// but not in the quota, and "storage full -- prune findings" would be a lie.
export async function releaseBytes(env: Env, userId: string, findingId: string): Promise<void> {
  const row = await env.DB.prepare(
    'SELECT COALESCE(SUM(bytes), 0) AS total FROM object_bytes WHERE user_id = ?1 AND finding_id = ?2',
  )
    .bind(userId, findingId)
    .first<{ total: number }>();
  const total = row?.total ?? 0;
  if (total === 0) return;

  await env.DB.batch([
    env.DB.prepare("UPDATE counter SET value = MAX(0, value - ?1) WHERE key = 'global_bytes'").bind(total),
    env.DB.prepare('DELETE FROM object_bytes WHERE user_id = ?1 AND finding_id = ?2').bind(userId, findingId),
  ]);
}

export async function findingRow(env: Env, userId: string, findingId: string): Promise<FindingRow | null> {
  const row = await env.DB.prepare(
    `SELECT f.id AS id, f.modified_at AS modifiedAt, f.received_at AS receivedAt, f.deleted AS deleted,
            COALESCE((SELECT SUM(bytes) FROM object_bytes o WHERE o.user_id = f.user_id AND o.finding_id = f.id), 0) AS bytes
       FROM finding f WHERE f.user_id = ?1 AND f.id = ?2`,
  )
    .bind(userId, findingId)
    .first<{ id: string; modifiedAt: number; receivedAt: number; deleted: number; bytes: number }>();
  return row ? { ...row, deleted: row.deleted === 1 } : null;
}

/// A per-user receipt clock that never goes backwards, even if two writes land in the same
/// millisecond or the platform clock does something surprising. Clients page on this.
async function nextReceivedAt(env: Env, userId: string, now: number): Promise<number> {
  const row = await env.DB.prepare('SELECT COALESCE(MAX(received_at), 0) AS high FROM finding WHERE user_id = ?1')
    .bind(userId)
    .first<{ high: number }>();
  return Math.max(now, (row?.high ?? 0) + 1);
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
  const receivedAt = await nextReceivedAt(env, userId, now);
  await env.DB.prepare(
    `INSERT INTO finding (user_id, id, modified_at, received_at, deleted) VALUES (?1, ?2, ?3, ?4, ?5)
       ON CONFLICT (user_id, id) DO UPDATE SET
         modified_at = excluded.modified_at,
         received_at = excluded.received_at,
         deleted     = excluded.deleted`,
  )
    .bind(userId, findingId, modifiedAt, receivedAt, deleted ? 1 : 0)
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
            COALESCE((SELECT SUM(bytes) FROM object_bytes o WHERE o.user_id = f.user_id AND o.finding_id = f.id), 0) AS bytes
       FROM finding f
      WHERE f.user_id = ?1 AND (f.received_at > ?2 OR (f.received_at = ?2 AND f.id > ?3))
      ORDER BY f.received_at ASC, f.id ASC
      LIMIT ?4`,
  )
    .bind(userId, afterReceived, afterId, limit + 1)
    .all<{ id: string; modifiedAt: number; receivedAt: number; deleted: number; bytes: number }>();

  const all = rows.results.map((row) => ({ ...row, deleted: row.deleted === 1 }));
  const hasMore = all.length > limit;
  const findings = hasMore ? all.slice(0, limit) : all;
  const last = findings[findings.length - 1];
  return {
    findings,
    nextCursor: last ? `${last.receivedAt}.${last.id}` : cursor,
    hasMore,
  };
}
