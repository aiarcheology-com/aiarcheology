import { SELF, env } from 'cloudflare:test';
import { describe, expect, it } from 'vitest';
import { reapUnreferencedObjects, STAGING_LIFETIME_MS } from '../../src/store';
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
  it('keeps the newer R2 bytes when a stale metadata commit loses its D1 compare-and-set', async () => {
    // This is the race AIA-0754 found. Both image requests pass their initial stale check while no
    // index row exists. The newer metadata commits first; the older metadata then loses D1's CAS.
    // The old layout still returned the stale request's R2 bytes because both requests overwrote the
    // same key before that CAS. Revision keys make the winner's index refer only to its own bytes.
    const token = await tokenFor(nextUser());
    const id = findingId('01');
    const early = Date.now() - 1_000;
    const late = early + 500;

    expect((await putImage(token, id, early, bytes(64, 1))).status).toBe(200);
    expect((await putImage(token, id, late, bytes(96, 2))).status).toBe(200);
    expect((await putMeta(token, id, late, { note: 'newer' })).status).toBe(200);

    const stale = await putMeta(token, id, early, { note: 'older' });
    expect(stale.status).toBe(409);

    const image = await SELF.fetch(`${BASE}/v1/findings/${id}/image`, { headers: auth(token) });
    expect(new Uint8Array(await image.arrayBuffer())).toEqual(bytes(96, 2));
    const meta = await SELF.fetch(`${BASE}/v1/findings/${id}/meta`, { headers: auth(token) });
    expect(await meta.json()).toEqual({ note: 'newer' });
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

    expect(await reapUnreferencedObjects(env, now)).toBe(1);
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

    expect(await reapUnreferencedObjects(env, now)).toBe(2);
    const image = await SELF.fetch(`${BASE}/v1/findings/${id}/image`, { headers: auth(token) });
    expect(new Uint8Array(await image.arrayBuffer())).toEqual(bytes(96, 4));
    const meta = await SELF.fetch(`${BASE}/v1/findings/${id}/meta`, { headers: auth(token) });
    expect(await meta.json()).toEqual({ note: 'new' });
  });
});
