import { authenticate } from './auth';
import { purgeAccount } from './purge';
import { sweepIncompleteFences } from './sweep';
import { handleClerkWebhook } from './webhook';
import { ApiError, errorResponse, json } from './errors';
import {
  commitFinding,
  findingRow,
  isDeleting,
  listSince,
  modifiedAtForRevision,
  objectKey,
  objectReference,
  readBodyWithCap,
  reapUnreferencedObjects,
  reapUnreferencedObjectsForFinding,
  requireFindingId,
  reserveBytes,
  usageFor,
  type FindingRow,
} from './store';
import type { Env } from './env';

const DEFAULT_PAGE = 200;
const MAX_PAGE = 500;
const PURGE_CRON = '0 3 * * *';
const REAPER_CRON = '*/15 * * * *';
const MAX_DELETE_REAP_BATCHES = 10;

/// Every write carries `?modifiedAt=<ms since epoch>`.
///
/// It is a query parameter rather than a field inside meta.json because DELETE has no body and
/// still needs an ordering key -- a tombstone is just another row carrying `modifiedAt`, and it has
/// to be comparable with the edit it is racing.
interface ModifiedAt {
  /// The client timestamp that names the immutable R2 revision. Image and metadata requests from
  /// one outbox item carry the same value.
  revision: number;
}

function requireModifiedAt(url: URL): ModifiedAt {
  const raw = url.searchParams.get('modifiedAt');
  const value = Number(raw);
  if (raw === null || !Number.isFinite(value) || value < 0) {
    throw new ApiError('bad_request', 'A numeric modifiedAt (ms since epoch) is required.');
  }
  const revision = Math.trunc(value);
  if (!Number.isSafeInteger(revision)) {
    throw new ApiError('bad_request', 'The modifiedAt value is outside the supported range.');
  }
  return { revision };
}

/// Last-write-wins, decided server-side so a stale device cannot clobber a newer cloud copy.
///
/// Equal timestamps are accepted rather than refused: a retried upload replays the same
/// `modifiedAt`, and an idempotent retry is the whole point of the outbox.
async function refuseIfStale(env: Env, userId: string, id: string, incoming: number): Promise<FindingRow | null> {
  const existing = await findingRow(env, userId, id);
  if (existing !== null && incoming < existing.modifiedAt) {
    throw new ApiError('stale', 'A newer version of this finding is already stored.', { winner: existing });
  }
  return existing;
}

/// Cleans up after an upload that was admitted before a purge began and landed after it.
///
/// The fence inside `reserveBytes` refuses everything that reaches it afterwards, but a request
/// that had already passed it can still be inside `FINDINGS.put` when the purge starts. R2 listing
/// is point-in-time: it cannot see a write that has not landed yet, so such an object survives a
/// purge that reported success -- unindexed, and past the credential that could name it.
///
/// So the write checks the fence again on the other side and removes itself. The purge's own
/// re-listing catches the opposite ordering, and between them nothing outlives an erasure.
async function refuseIfAccountVanished(
  env: Env,
  userId: string,
  id: string,
  revision: number,
  kind: 'meta' | 'image',
): Promise<void> {
  if ((await isDeleting(env, userId)) === false) return;
  await env.FINDINGS.delete(objectKey(userId, id, revision, kind));
  throw new ApiError('account_deleting', 'This account is being deleted.');
}

/// Removes only revisions that still have no live index reference after the tombstone. A later
/// metadata commit can resurrect the finding between these steps, so deleting the whole prefix or
/// all storage rows would corrupt that newer state.
async function deleteFindingObjects(env: Env, userId: string, id: string): Promise<void> {
  for (let batch = 0; batch < MAX_DELETE_REAP_BATCHES; batch += 1) {
    const reaped = await reapUnreferencedObjectsForFinding(env, userId, id);
    if (reaped.atCapacity === false) return;
  }
  throw new ApiError('internal', 'The finding has too many stored revisions; delete it again to finish.');
}

async function handle(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const now = Date.now();

  if (url.pathname === '/health') {
    // Unauthenticated by necessity, so it reports liveness and nothing else -- no version, no
    // binding names, no configuration.
    return json({ ok: true });
  }

  // Dispatched before authentication: it carries an svix signature, not a session token, and
  // everything past this point requires one.
  if (url.pathname === '/v1/webhooks/clerk') {
    return handleClerkWebhook(request, env);
  }

  const userId = await authenticate(request, env);

  if (url.pathname === '/v1/me/data' && request.method === 'DELETE') {
    // The ordering this whole phase exists for: purge here, verify it finished, and only then
    // delete the Clerk user. The other way round destroys the session token, and with it the only
    // credential that can reach this data -- which would be orphaned in the bucket for ever.
    return json({ purged: await purgeAccount(env, userId) });
  }

  if (url.pathname === '/v1/me/usage' && request.method === 'GET') {
    return json({ usage: await usageFor(env, userId) });
  }

  if (url.pathname === '/v1/findings' && request.method === 'GET') {
    const rawLimit = Number(url.searchParams.get('limit') ?? DEFAULT_PAGE);
    const limit = Number.isFinite(rawLimit) ? Math.min(Math.max(Math.trunc(rawLimit), 1), MAX_PAGE) : DEFAULT_PAGE;
    const page = await listSince(env, userId, url.searchParams.get('cursor'), limit);
    return json({ ...page, usage: await usageFor(env, userId) });
  }

  const match = url.pathname.match(/^\/v1\/findings\/([^/]+)(?:\/(meta|image))?$/);
  if (match === null) {
    throw new ApiError('not_found', 'No such endpoint.');
  }
  let rawId: string;
  try {
    rawId = decodeURIComponent(match[1] ?? '');
  } catch {
    // `decodeURIComponent` throws on malformed percent-encoding. Unhandled it would surface as a
    // retryable 500 for what is a client mistake that retrying cannot fix.
    throw new ApiError('bad_request', 'The finding id is malformed.');
  }
  const id = requireFindingId(rawId);
  const kind = match[2] as 'meta' | 'image' | undefined;

  if (request.method === 'GET' && kind !== undefined) {
    const reference = await objectReference(env, userId, id, kind);
    if (reference === null) throw new ApiError('not_found', 'That part of the finding is not stored.');
    const object = await env.FINDINGS.get(objectKey(userId, id, reference, kind));
    if (object === null) {
      throw new ApiError('not_found', 'That part of the finding is not stored.');
    }
    return new Response(object.body, {
      headers: {
        'content-type': kind === 'meta' ? 'application/json; charset=utf-8' : 'image/jpeg',
        'content-length': String(object.size),
        'x-content-type-options': 'nosniff',
        // The same reasoning as every JSON response, and it matters most here: these two carry the
        // coordinates, the finder's name and the photograph. A cache keying on URL alone would hand
        // one user another's fieldwork, and the URL is identical for every account.
        'cache-control': 'private, no-store',
        vary: 'Authorization',
        etag: object.httpEtag,
      },
    });
  }

  if (request.method === 'PUT' && kind === 'image') {
    const modified = requireModifiedAt(url);
    const modifiedAt = await modifiedAtForRevision(env, userId, id, modified.revision, now);
    // The image is guarded by the same staleness rule as the meta it belongs to. Without it, an
    // older device's image could overwrite the newer one already paired with a committed meta,
    // and the finding would be torn: new notes, old picture.
    await refuseIfStale(env, userId, id, modifiedAt);
    const body = await readBodyWithCap(request, env.IMAGE_BYTE_LIMIT);
    const usage = await reserveBytes(env, userId, id, modified.revision, 'image', body.byteLength, now);
    await env.FINDINGS.put(objectKey(userId, id, modified.revision, 'image'), body, {
      // Equal timestamps are idempotent retries. A different request can never replace an object
      // that already owns this revision key, even if the index compare-and-set later refuses it.
      onlyIf: new Headers({ 'if-none-match': '*' }),
      httpMetadata: { contentType: 'image/jpeg' },
    });
    await refuseIfAccountVanished(env, userId, id, modified.revision, 'image');
    return json({ modifiedAt, bytes: body.byteLength, usage });
  }

  if (request.method === 'PUT' && kind === 'meta') {
    const modified = requireModifiedAt(url);
    const modifiedAt = await modifiedAtForRevision(env, userId, id, modified.revision, now);
    await refuseIfStale(env, userId, id, modifiedAt);
    const body = await readBodyWithCap(request, env.META_BYTE_LIMIT);
    try {
      JSON.parse(new TextDecoder().decode(body));
    } catch {
      throw new ApiError('bad_request', 'The metadata is not valid JSON.');
    }
    const usage = await reserveBytes(env, userId, id, modified.revision, 'meta', body.byteLength, now);
    await env.FINDINGS.put(objectKey(userId, id, modified.revision, 'meta'), body, {
      onlyIf: new Headers({ 'if-none-match': '*' }),
      httpMetadata: { contentType: 'application/json' },
    });
    await refuseIfAccountVanished(env, userId, id, modified.revision, 'meta');
    // The index row is written last and is the commit point. `deleted` returns to 0 here on
    // purpose: an edit that outlives a tombstone brings the finding back, which is what
    // last-write-wins means when one of the writes was a delete.
    const finding = await commitFinding(env, userId, id, modifiedAt, false, now, modified.revision);
    return json({ finding, usage });
  }

  if (request.method === 'DELETE' && kind === undefined) {
    const modified = requireModifiedAt(url);
    const modifiedAt = await modifiedAtForRevision(env, userId, id, modified.revision, now);
    await refuseIfStale(env, userId, id, modifiedAt);
    // Tombstone first. A crash after this point leaves bytes that are merely unreachable and are
    // reclaimed by a retry; the other order would leave a live index row pointing at objects that
    // are already gone, which reads as corruption on every device that syncs it.
    const finding = await commitFinding(env, userId, id, modifiedAt, true, now);
    await deleteFindingObjects(env, userId, id);
    return json({ finding, usage: await usageFor(env, userId) });
  }

  throw new ApiError('not_found', 'No such endpoint.');
}

/// The route this request matched, as a template.
///
/// A template, never the URL: a real path carries a finding's id, and a log line naming findings is
/// a record of what somebody surveyed sitting in a log aggregator.
function routeTemplate(url: URL, method: string): string {
  if (url.pathname === '/health') return 'GET /health';
  if (url.pathname === '/v1/webhooks/clerk') return 'POST /v1/webhooks/clerk';
  if (url.pathname === '/v1/me/usage') return 'GET /v1/me/usage';
  if (url.pathname === '/v1/me/data') return 'DELETE /v1/me/data';
  if (url.pathname === '/v1/findings') return 'GET /v1/findings';
  const match = url.pathname.match(/^\/v1\/findings\/[^/]+(?:\/(meta|image))?$/);
  if (match !== null) return `${method} /v1/findings/:id${match[1] === undefined ? '' : `/${match[1]}`}`;
  return `${method} <unmatched>`;
}

export default {
  /// Finishes purges the webhook never completed (AIA-0773).
  ///
  /// The only actor left once a Clerk user is gone: no client can authenticate as them, and svix's
  /// retry schedule is finite. Logged distinctly so the line is worth alerting on -- a sweep that
  /// keeps finding the same straggler is the signal that something needs a human, and it is the
  /// only such signal this service can raise for itself.
  async scheduled(event: ScheduledController, env: Env): Promise<void> {
    const started = Date.now();
    try {
      if (event.cron === PURGE_CRON) {
        const result = await sweepIncompleteFences(env);
        if (result.incomplete === 0) return;
        console.log(
          JSON.stringify({
            sweep: result.purged === true ? 'purged' : 'incomplete',
            remaining: result.incomplete,
            durationMs: Date.now() - started,
          }),
        );
        return;
      }

      if (event.cron === REAPER_CRON) {
        const result = await reapUnreferencedObjects(env);
        if (result.reaped > 0 || result.atCapacity) {
          console.log(
            JSON.stringify({
              sweep: 'reap',
              reaped: result.reaped,
              backlog: result.atCapacity,
              durationMs: Date.now() - started,
            }),
          );
        }
      }
    } catch (error) {
      console.log(
        JSON.stringify({
          sweep: 'failed',
          error: error instanceof Error ? error.message : 'unknown',
          durationMs: Date.now() - started,
        }),
      );
    }
  },

  async fetch(request: Request, env: Env): Promise<Response> {
    const started = Date.now();
    const url = new URL(request.url);
    let response: Response;
    try {
      response = await handle(request, env);
    } catch (error) {
      response = errorResponse(error);
    }

    // One structured line per request. Route template, status, error code and duration -- and
    // nothing else. No URL, no ids, no subject, no headers, no body: the payload behind this
    // service is site coordinates attached to a named person.
    console.log(
      JSON.stringify({
        route: routeTemplate(url, request.method),
        status: response.status,
        error: response.headers.get('x-error-code') ?? undefined,
        durationMs: Date.now() - started,
      }),
    );
    return response;
  },
} satisfies ExportedHandler<Env>;
