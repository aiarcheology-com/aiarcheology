import { SELF, env } from 'cloudflare:test';
import { describe, expect, it } from 'vitest';
import { auth, bytes, tokenFor } from './helpers';
import { commitFinding } from '../../src/store';

const BASE = 'https://worker.test';

interface FindingRow {
  id: string;
  modifiedAt: number;
  receivedAt: number;
  deleted: boolean;
  bytes: number;
  hasImage: boolean;
}

interface Page {
  findings: FindingRow[];
  nextCursor: string | null;
  hasMore: boolean;
}

let sequence = 0;
function nextUser(): string {
  sequence += 1;
  return `user_sync_${sequence}`;
}

function findingId(suffix: string): string {
  return `2f9a6e${suffix.padStart(2, '0')}-0000-4000-8000-000000000000`;
}

async function putMeta(token: string, id: string, modifiedAt: number, meta: unknown = { note: 'a wall' }) {
  return SELF.fetch(`${BASE}/v1/findings/${id}/meta?modifiedAt=${modifiedAt}`, {
    method: 'PUT',
    headers: auth(token),
    body: JSON.stringify(meta),
  });
}

async function putImage(token: string, id: string, modifiedAt: number, size = 64) {
  return SELF.fetch(`${BASE}/v1/findings/${id}/image?modifiedAt=${modifiedAt}`, {
    method: 'PUT',
    headers: auth(token),
    body: bytes(size),
  });
}

async function list(token: string, cursor: string | null = null, limit?: number): Promise<Page> {
  const params = new URLSearchParams();
  if (cursor !== null) params.set('cursor', cursor);
  if (limit !== undefined) params.set('limit', String(limit));
  const response = await SELF.fetch(`${BASE}/v1/findings?${params.toString()}`, { headers: auth(token) });
  expect(response.status).toBe(200);
  return (await response.json()) as Page;
}

describe('storing and reading a finding', () => {
  it('round-trips an image and its metadata', async () => {
    const token = await tokenFor(nextUser());
    const id = findingId('01');
    const modifiedAt = Date.now() - 1000;

    expect((await putImage(token, id, modifiedAt, 128)).status).toBe(200);
    const committed = await putMeta(token, id, modifiedAt, { note: 'a ditch', gps_lat: 49.1 });
    expect(committed.status).toBe(200);

    const image = await SELF.fetch(`${BASE}/v1/findings/${id}/image`, { headers: auth(token) });
    expect(image.status).toBe(200);
    expect(image.headers.get('content-type')).toBe('image/jpeg');
    expect(new Uint8Array(await image.arrayBuffer())).toEqual(bytes(128));

    const meta = await SELF.fetch(`${BASE}/v1/findings/${id}/meta`, { headers: auth(token) });
    expect(await meta.json()).toEqual({ note: 'a ditch', gps_lat: 49.1 });
  });

  it('never lets one user reach the findings of another', async () => {
    const owner = await tokenFor(nextUser());
    const stranger = await tokenFor(nextUser());
    const id = findingId('02');
    await putMeta(owner, id, Date.now());

    const response = await SELF.fetch(`${BASE}/v1/findings/${id}/meta`, { headers: auth(stranger) });
    // 404 rather than 403: telling a stranger the finding exists but is not theirs is itself a
    // disclosure, and these are site coordinates.
    expect(response.status).toBe(404);
    expect((await list(stranger)).findings).toEqual([]);
  });

  it('keeps two accounts apart even when they claim the same finding id', async () => {
    // The index row is not the only thing standing between two users: a client can send any id it
    // likes, so the storage key itself has to be namespaced. This is the test that fails if it is
    // not -- the "stranger reads a finding" case above is refused by the index lookup first and
    // would pass either way.
    const first = await tokenFor(nextUser());
    const second = await tokenFor(nextUser());
    const id = findingId('05');
    const now = Date.now();

    await putImage(first, id, now, 100);
    await putMeta(first, id, now, { note: 'the first account' });
    await putImage(second, id, now, 200);
    await putMeta(second, id, now, { note: 'the second account' });

    const firstImage = await SELF.fetch(`${BASE}/v1/findings/${id}/image`, { headers: auth(first) });
    expect(new Uint8Array(await firstImage.arrayBuffer())).toHaveLength(100);
    const firstMeta = await SELF.fetch(`${BASE}/v1/findings/${id}/meta`, { headers: auth(first) });
    expect(await firstMeta.json()).toEqual({ note: 'the first account' });

    const secondImage = await SELF.fetch(`${BASE}/v1/findings/${id}/image`, { headers: auth(second) });
    expect(new Uint8Array(await secondImage.arrayBuffer())).toHaveLength(200);
  });

  it('refuses a malformed finding id before it can reach a storage key', async () => {
    const token = await tokenFor(nextUser());
    const response = await SELF.fetch(`${BASE}/v1/findings/..%2F..%2Fetc/meta?modifiedAt=1`, {
      method: 'PUT',
      headers: auth(token),
      body: '{}',
    });
    expect(response.status).toBe(400);
  });

  it('refuses metadata that is not valid JSON', async () => {
    const token = await tokenFor(nextUser());
    const response = await SELF.fetch(`${BASE}/v1/findings/${findingId('03')}/meta?modifiedAt=1`, {
      method: 'PUT',
      headers: auth(token),
      body: 'not json at all',
    });
    expect(response.status).toBe(400);
  });

  it('requires modifiedAt on every write', async () => {
    const token = await tokenFor(nextUser());
    const response = await SELF.fetch(`${BASE}/v1/findings/${findingId('04')}/meta`, {
      method: 'PUT',
      headers: auth(token),
      body: '{}',
    });
    expect(response.status).toBe(400);
  });
});

describe('the sync cursor', () => {
  it('delivers a finding created offline long ago, even to a device already past that date', async () => {
    // The regression this guards: paging on modifiedAt instead of receipt order. A finding edited
    // three weeks ago and uploaded today would sort behind a device's existing high-water mark and
    // that device would never see it -- silent, permanent data loss between two devices.
    const token = await tokenFor(nextUser());
    const now = Date.now();

    await putMeta(token, findingId('10'), now);
    const afterFirst = await list(token);
    expect(afterFirst.findings).toHaveLength(1);

    const threeWeeksAgo = now - 21 * 24 * 60 * 60 * 1000;
    await putMeta(token, findingId('11'), threeWeeksAgo);

    const delta = await list(token, afterFirst.nextCursor);
    expect(delta.findings.map((row) => row.id)).toEqual([findingId('11')]);
    expect(delta.findings[0]?.modifiedAt).toBe(threeWeeksAgo);
  });

  it('pages without dropping or repeating a finding', async () => {
    const token = await tokenFor(nextUser());
    const ids = ['20', '21', '22', '23', '24'].map(findingId);
    for (const id of ids) await putMeta(token, id, Date.now());

    const seen: string[] = [];
    let cursor: string | null = null;
    for (let page = 0; page < 10; page += 1) {
      const result: Page = await list(token, cursor, 2);
      seen.push(...result.findings.map((row) => row.id));
      cursor = result.nextCursor;
      if (!result.hasMore) break;
    }
    expect(seen.sort()).toEqual([...ids].sort());
  });

  it('returns an empty delta when nothing has changed', async () => {
    const token = await tokenFor(nextUser());
    await putMeta(token, findingId('30'), Date.now());
    const first = await list(token);
    const second = await list(token, first.nextCursor);
    expect(second.findings).toEqual([]);
    expect(second.hasMore).toBe(false);
  });
});

describe('last-write-wins', () => {
  it('refuses an edit older than the stored one and names the winner', async () => {
    const token = await tokenFor(nextUser());
    const id = findingId('40');
    const now = Date.now();
    await putMeta(token, id, now, { note: 'newer' });

    const response = await putMeta(token, id, now - 5000, { note: 'older' });
    expect(response.status).toBe(409);
    const body = (await response.json()) as { error: { code: string; retryable: boolean; winner: FindingRow } };
    expect(body.error.code).toBe('stale');
    expect(body.error.retryable).toBe(false);
    expect(body.error.winner.modifiedAt).toBe(now);

    const meta = await SELF.fetch(`${BASE}/v1/findings/${id}/meta`, { headers: auth(token) });
    expect(await meta.json()).toEqual({ note: 'newer' });
  });

  it('accepts a replay of the same timestamp, so a retried upload is idempotent', async () => {
    const token = await tokenFor(nextUser());
    const id = findingId('41');
    const modifiedAt = Date.now();
    expect((await putMeta(token, id, modifiedAt)).status).toBe(200);
    expect((await putMeta(token, id, modifiedAt)).status).toBe(200);
  });

  it('guards the image with the same rule, so a finding cannot be torn', async () => {
    // Without this an older device's image would overwrite the newer one already paired with a
    // committed meta: new notes, old picture, and nothing to signal it.
    const token = await tokenFor(nextUser());
    const id = findingId('42');
    const now = Date.now();
    await putImage(token, id, now, 64);
    await putMeta(token, id, now);

    const stale = await putImage(token, id, now - 5000, 96);
    expect(stale.status).toBe(409);

    const image = await SELF.fetch(`${BASE}/v1/findings/${id}/image`, { headers: auth(token) });
    expect(new Uint8Array(await image.arrayBuffer())).toHaveLength(64);
  });

  it('clamps a future-dated client clock to receipt time and echoes what it stored', async () => {
    // A device with a fast clock would otherwise win every conflict for ever. The echo matters as
    // much as the clamp: a client that kept its own future value would see the row as perpetually
    // older than local and re-upload it on every sync.
    const token = await tokenFor(nextUser());
    const id = findingId('43');
    const beforeRequest = Date.now();
    const response = await putMeta(token, id, beforeRequest + 60 * 60 * 1000);
    expect(response.status).toBe(200);

    const body = (await response.json()) as { finding: FindingRow };
    expect(body.finding.modifiedAt).toBeGreaterThanOrEqual(beforeRequest);
    expect(body.finding.modifiedAt).toBeLessThanOrEqual(Date.now());
  });
});

describe('deletion', () => {
  it('leaves a tombstone that syncs, frees the quota, and hides the objects', async () => {
    const token = await tokenFor(nextUser());
    const id = findingId('50');
    const now = Date.now();
    await putImage(token, id, now, 256);
    await putMeta(token, id, now);

    const before = await list(token);
    expect(before.findings[0]?.bytes).toBeGreaterThan(256);

    const deleted = await SELF.fetch(`${BASE}/v1/findings/${id}?modifiedAt=${now + 1}`, {
      method: 'DELETE',
      headers: auth(token),
    });
    expect(deleted.status).toBe(200);
    const body = (await deleted.json()) as { finding: FindingRow; usage: { used: number } };
    expect(body.finding.deleted).toBe(true);
    // A delete that frees bucket space but not quota would make "storage full -- prune findings"
    // advice that does not work.
    expect(body.usage.used).toBe(0);

    expect((await SELF.fetch(`${BASE}/v1/findings/${id}/meta`, { headers: auth(token) })).status).toBe(404);

    const after = await list(token);
    expect(after.findings.map((row) => [row.id, row.deleted])).toEqual([[id, true]]);
  });

  it('brings a finding back when an edit outlives the tombstone', async () => {
    // Delete-vs-edit is last-write-wins like every other conflict, so this is the intended
    // behaviour, not a bug to special-case away.
    const token = await tokenFor(nextUser());
    const id = findingId('51');
    const now = Date.now();
    await putMeta(token, id, now, { note: 'first' });
    await SELF.fetch(`${BASE}/v1/findings/${id}?modifiedAt=${now + 1}`, { method: 'DELETE', headers: auth(token) });

    const revived = await putMeta(token, id, now + 2, { note: 'edited elsewhere' });
    expect(revived.status).toBe(200);
    expect(((await revived.json()) as { finding: FindingRow }).finding.deleted).toBe(false);
    const meta = await SELF.fetch(`${BASE}/v1/findings/${id}/meta`, { headers: auth(token) });
    expect(await meta.json()).toEqual({ note: 'edited elsewhere' });
  });

  it('says a resurrected finding has no image, so the client knows to send one', async () => {
    // Deleting removes the objects; an edit newer than the tombstone brings the row back but not
    // the picture. Without `hasImage` the client would ask for it, get a terminal 404, and show a
    // finding with a permanently broken photo on every device.
    const token = await tokenFor(nextUser());
    const id = findingId('53');
    const now = Date.now();
    await putImage(token, id, now, 64);
    const alive = await putMeta(token, id, now);
    expect(((await alive.json()) as { finding: FindingRow }).finding.hasImage).toBe(true);

    await SELF.fetch(`${BASE}/v1/findings/${id}?modifiedAt=${now + 1}`, {
      method: 'DELETE',
      headers: auth(token),
    });

    const revived = await putMeta(token, id, now + 2);
    const finding = ((await revived.json()) as { finding: FindingRow }).finding;
    expect(finding.deleted).toBe(false);
    expect(finding.hasImage).toBe(false);
  });

  it('refuses a delete older than the stored edit', async () => {
    const token = await tokenFor(nextUser());
    const id = findingId('52');
    const now = Date.now();
    await putMeta(token, id, now);
    const response = await SELF.fetch(`${BASE}/v1/findings/${id}?modifiedAt=${now - 1000}`, {
      method: 'DELETE',
      headers: auth(token),
    });
    expect(response.status).toBe(409);
  });
});

describe('a write that was already stale when it arrived', () => {
  it('cannot resurrect a finding that was deleted after its staleness check passed', async () => {
    // The check is a read, and a read holds nothing still. `commitFinding` is called directly here
    // because that is precisely what the race produces: a request whose check passed, then paused,
    // then resumed behind a newer write. Driving it through the route would only re-run the check.
    const user = nextUser();
    const token = await tokenFor(user);
    const id = findingId('90');
    const early = Date.now();

    expect((await putMeta(token, id, early)).status).toBe(200);
    const removed = await SELF.fetch(`${BASE}/v1/findings/${id}?modifiedAt=${early + 500}`, {
      method: 'DELETE',
      headers: auth(token),
    });
    expect(removed.status).toBe(200);

    await expect(commitFinding(env, user, id, early, false, Date.now())).rejects.toMatchObject({
      code: 'stale',
    });

    const listed = await SELF.fetch(`${BASE}/v1/findings?cursor=0`, { headers: auth(token) });
    const page = (await listed.json()) as { findings: { id: string; deleted: boolean }[] };
    expect(page.findings.find((row) => row.id === id)?.deleted).toBe(true);
  });

  it('still accepts the identical timestamp an outbox retry replays', async () => {
    const user = nextUser();
    const token = await tokenFor(user);
    const id = findingId('91');
    const at = Date.now();
    expect((await putMeta(token, id, at)).status).toBe(200);
    const again = await commitFinding(env, user, id, at, false, Date.now());
    expect(again.modifiedAt).toBe(at);
  });
});
