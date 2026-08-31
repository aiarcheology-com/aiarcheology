import { SELF, env } from 'cloudflare:test';
import { describe, expect, it } from 'vitest';
import {
  commitFinding,
  modifiedAtForRevision,
  reapUnreferencedObjects,
  reapUnreferencedObjectsForFinding,
  STAGING_LIFETIME_MS,
} from '../../src/store';
import { auth, bytes, tokenFor } from './helpers';

const BASE = 'https://worker.test';

let sequence = 0;
function nextUser(): string {
  sequence += 1;
  return `user_revision_${sequence}`;
}

function findingId(suffix: string): string {
  return `8d7a44${suffix.padStart(2, '0')}-0000-4000-8000-000000000000`;
}

function putImage(token: string, id: string, modifiedAt: number, body: Uint8Array): Promise<Response> {
  return SELF.fetch(`${BASE}/v1/findings/${id}/image?modifiedAt=${modifiedAt}`, {
    method: 'PUT',
    headers: auth(token),
    body,
  });
}

function putMeta(token: string, id: string, modifiedAt: number, body: unknown): Promise<Response> {
  return SELF.fetch(`${BASE}/v1/findings/${id}/meta?modifiedAt=${modifiedAt}`, {
    method: 'PUT',
    headers: auth(token),
    body: JSON.stringify(body),
  });
}

async function usage(token: string): Promise<number> {
  const response = await SELF.fetch(`${BASE}/v1/me/usage`, { headers: auth(token) });
  return ((await response.json()) as { usage: { used: number } }).usage.used;
}

describe('immutable finding revisions', () => {
  it('retains a future revision\'s first clamp even after that clock value passes', async () => {
    const user = nextUser();
    const id = findingId('09');
    const revision = 2_000;

    expect(await modifiedAtForRevision(env, user, id, revision, 1_000)).toBe(1_000);
    expect(await modifiedAtForRevision(env, user, id, revision, 3_000)).toBe(1_000);
  });

  it('keeps the winner\'s R2 bytes when the LOSING image write lands last', async () => {
    // This is the race AIA-0754 found, and the order of the two image writes is the whole test.
    //
    // Both pass `refuseIfStale` because neither has committed metadata yet, so no index row exists
    // to compare against -- that is what lets a loser still be in flight. Under the old layout both
    // wrote `findings/<user>/<id>/image.jpg`, so whichever landed SECOND owned the bytes, and the
    // index committed afterwards named a revision it did not actually hold: new notes, old picture,
    // no error anywhere. Revision-scoped keys make the two writes disjoint.
    //
    // Writing `early` first instead would assert nothing: the newer bytes would land second and be
    // returned under either layout, which is exactly how the original version of this test passed
    // against the very code it was meant to pin.
    const token = await tokenFor(nextUser());
    const id = findingId('01');
    const early = Date.now() - 1_000;
    const late = early + 500;

    expect((await putImage(token, id, late, bytes(96, 2))).status).toBe(200);
    expect((await putImage(token, id, early, bytes(64, 1))).status).toBe(200);
    expect((await putMeta(token, id, late, { note: 'newer' })).status).toBe(200);

    const stale = await putMeta(token, id, early, { note: 'older' });
    expect(stale.status).toBe(409);

    // Under the shared-key layout this reads bytes(64, 1) -- the loser's.
    const image = await SELF.fetch(`${BASE}/v1/findings/${id}/image`, { headers: auth(token) });
    expect(new Uint8Array(await image.arrayBuffer())).toEqual(bytes(96, 2));
    const meta = await SELF.fetch(`${BASE}/v1/findings/${id}/meta`, { headers: auth(token) });
    expect(await meta.json()).toEqual({ note: 'newer' });
  });

  it('will not reap a revision at or above the tombstone that made it unreferenced', async () => {
    // The per-finding reap runs on DELETE, where a tombstone makes a *fresh* reservation
    // unreferenced the instant it commits -- so unlike the scheduled reaper it has no age floor to
    // hide behind. Without the revision bound this collects an upload that is still in flight: the
    // image row goes, and the metadata commit that follows succeeds with `image_revision = NULL`,
    // returning 200 for a finding whose photograph was just deleted.
    const token = await tokenFor(nextUser());
    const user = `user_revision_${sequence}`;
    const id = findingId('11');
    const doomed = Date.now() - 2_000;
    const tombstone = doomed + 100;
    const inFlight = tombstone + 100;

    expect((await putImage(token, id, doomed, bytes(64, 3))).status).toBe(200);
    expect((await putMeta(token, id, doomed, { note: 'doomed' })).status).toBe(200);

    // Device B deletes while device A has already staged a newer image and not yet committed it.
    await commitFinding(env, user, id, tombstone, true, Date.now());
    expect((await putImage(token, id, inFlight, bytes(96, 4))).status).toBe(200);

    // Only the revisions the tombstone actually beat are collected: image + meta at `doomed`.
    expect((await reapUnreferencedObjectsForFinding(env, user, id, tombstone)).reaped).toBe(2);

    // A's metadata now commits and must carry its image, not a NULL where the picture used to be.
    expect((await putMeta(token, id, inFlight, { note: 'in flight' })).status).toBe(200);
    const image = await SELF.fetch(`${BASE}/v1/findings/${id}/image`, { headers: auth(token) });
    expect(image.status).toBe(200);
    expect(new Uint8Array(await image.arrayBuffer())).toEqual(bytes(96, 4));
  });

  it('keeps one immutable revision when a fast client clock is clamped between image and metadata', async () => {
    // The two requests naturally reach the server at different milliseconds. If each path used the
    // clamped timestamp, a future-dated client would store an image at one key and commit metadata
    // at another, dropping the image. The raw request timestamp remains the shared storage revision;
    // only D1's conflict-ordering timestamp is clamped.
    const token = await tokenFor(nextUser());
    const id = findingId('05');
    const future = Date.now() + 60 * 60 * 1000;

    expect((await putImage(token, id, future, bytes(96, 5))).status).toBe(200);
    expect((await putMeta(token, id, future, { note: 'clock corrected' })).status).toBe(200);

    const image = await SELF.fetch(`${BASE}/v1/findings/${id}/image`, { headers: auth(token) });
    expect(new Uint8Array(await image.arrayBuffer())).toEqual(bytes(96, 5));
  });

  it('does not let a future revision become newer when its response is retried later', async () => {
    const token = await tokenFor(nextUser());
    const id = findingId('06');
    const future = Date.now() + 60 * 60 * 1000;

    expect((await putImage(token, id, future, bytes(64, 6))).status).toBe(200);
    expect((await putMeta(token, id, future, { note: 'first future revision' })).status).toBe(200);

    // The later edit is genuinely newer in the server's LWW order. The old implementation
    // re-clamped the future retry here, letting it win merely because this clock had advanced.
    await new Promise<void>((resolve) => setTimeout(resolve, 2));
    const later = Date.now();
    expect((await putMeta(token, id, later, { note: 'genuinely newer' })).status).toBe(200);

    const staleRetry = await putMeta(token, id, future, { note: 'first future revision' });
    expect(staleRetry.status).toBe(409);
    const meta = await SELF.fetch(`${BASE}/v1/findings/${id}/meta`, { headers: auth(token) });
    expect(await meta.json()).toEqual({ note: 'genuinely newer' });
  });

  it('keeps a future tombstone stale when a later edit resurrects the finding', async () => {
    const token = await tokenFor(nextUser());
    const id = findingId('08');
    const initial = Date.now() - 2_000;
    const future = Date.now() + 60 * 60 * 1000;
    expect((await putMeta(token, id, initial, { note: 'before delete' })).status).toBe(200);
    expect(
      (
        await SELF.fetch(`${BASE}/v1/findings/${id}?modifiedAt=${future}`, {
          method: 'DELETE',
          headers: auth(token),
        })
      ).status,
    ).toBe(200);

    await new Promise<void>((resolve) => setTimeout(resolve, 2));
    const later = Date.now();
    expect((await putMeta(token, id, later, { note: 'resurrected' })).status).toBe(200);

    const staleRetry = await SELF.fetch(`${BASE}/v1/findings/${id}?modifiedAt=${future}`, {
      method: 'DELETE',
      headers: auth(token),
    });
    expect(staleRetry.status).toBe(409);
    const meta = await SELF.fetch(`${BASE}/v1/findings/${id}/meta`, { headers: auth(token) });
    expect(await meta.json()).toEqual({ note: 'resurrected' });
  });

  it('reclaims an interrupted upload after its bounded staging lifetime', async () => {
    // The image is deliberately not followed by metadata, simulating an app crash or uninstall.
    // A subsequent device cannot name this id, so the maintenance job is the only way to release
    // both R2 bytes and the quota reservation.
    const user = nextUser();
    const token = await tokenFor(user);
    const id = findingId('02');
    const revision = Date.now() - 2_000;
    expect((await putImage(token, id, revision, bytes(128))).status).toBe(200);
    expect(await usage(token)).toBe(128);

    const now = Date.now();
    await env.DB.prepare(
      `UPDATE object_bytes SET created_at = ?1
        WHERE user_id = ?2 AND finding_id = ?3 AND revision = ?4 AND kind = 'image'`,
    )
      .bind(now - STAGING_LIFETIME_MS - 1, user, id, revision)
      .run();

    // A replay must not renew this lifetime: otherwise a client that keeps retrying after a lost
    // response could retain unreachable R2 bytes for ever.
    expect((await putImage(token, id, revision, bytes(128))).status).toBe(200);
    expect((await reapUnreferencedObjects(env, now)).reaped).toBe(1);
    expect(await usage(token)).toBe(0);
    expect((await env.FINDINGS.list({ prefix: `findings/${user}/${id}/` })).objects).toEqual([]);
  });

  it('reaps a superseded revision without touching the index-selected revision', async () => {
    const user = nextUser();
    const token = await tokenFor(user);
    const id = findingId('03');
    const oldRevision = Date.now() - 2_000;
    const newRevision = oldRevision + 500;

    expect((await putImage(token, id, oldRevision, bytes(64, 3))).status).toBe(200);
    expect((await putMeta(token, id, oldRevision, { note: 'old' })).status).toBe(200);
    expect((await putImage(token, id, newRevision, bytes(96, 4))).status).toBe(200);
    expect((await putMeta(token, id, newRevision, { note: 'new' })).status).toBe(200);

    const now = Date.now();
    await env.DB.prepare(
      `UPDATE object_bytes SET created_at = ?1
        WHERE user_id = ?2 AND finding_id = ?3 AND revision = ?4`,
    )
      .bind(now - STAGING_LIFETIME_MS - 1, user, id, oldRevision)
      .run();

    expect((await reapUnreferencedObjects(env, now)).reaped).toBe(2);
    const image = await SELF.fetch(`${BASE}/v1/findings/${id}/image`, { headers: auth(token) });
    expect(new Uint8Array(await image.arrayBuffer())).toEqual(bytes(96, 4));
    const meta = await SELF.fetch(`${BASE}/v1/findings/${id}/meta`, { headers: auth(token) });
    expect(await meta.json()).toEqual({ note: 'new' });
  });

  it('does not delete a live revision that commits after a tombstone', async () => {
    const user = nextUser();
    const token = await tokenFor(user);
    const id = findingId('07');
    const oldRevision = Date.now() - 2_000;
    const tombstoneRevision = oldRevision + 100;
    const newRevision = tombstoneRevision + 100;

    expect((await putImage(token, id, oldRevision, bytes(64, 7))).status).toBe(200);
    expect((await putMeta(token, id, oldRevision, { note: 'old' })).status).toBe(200);

    // This is the state immediately before DELETE's cleanup. A newer metadata write then
    // resurrects the finding, exactly as a second device can do between a real DELETE's D1 commit
    // and its former prefix-wide R2 deletion.
    await commitFinding(env, user, id, tombstoneRevision, true, Date.now());
    expect((await putImage(token, id, newRevision, bytes(96, 8))).status).toBe(200);
    expect((await putMeta(token, id, newRevision, { note: 'new' })).status).toBe(200);

    expect((await reapUnreferencedObjectsForFinding(env, user, id, tombstoneRevision)).reaped).toBe(2);
    const image = await SELF.fetch(`${BASE}/v1/findings/${id}/image`, { headers: auth(token) });
    expect(new Uint8Array(await image.arrayBuffer())).toEqual(bytes(96, 8));
    const meta = await SELF.fetch(`${BASE}/v1/findings/${id}/meta`, { headers: auth(token) });
    expect(await meta.json()).toEqual({ note: 'new' });
  });
});
