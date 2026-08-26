import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { sessionToken, subject } from './clerk';
import { stagingTarget } from './config';

/// End-to-end against the DEPLOYED staging Worker: a real Clerk token, real R2 objects, real D1
/// rows. `stagingTarget()` refuses to run against anything that is not plainly the staging host,
/// and everything this suite creates is deleted in teardown -- the bucket's 7-day expiry rule is a
/// backstop for a crashed run, not the mechanism.
const target = stagingTarget();

/// Every finding this run creates, so teardown can remove them even if a test failed part-way.
const created = new Set<string>();
let baselineUsed = 0;
/// The cursor at the head of the stream when this run began.
///
/// Tombstones are kept for ever and listing starts from the oldest, so a suite that asserted on
/// the first page would quietly start failing once this test account had accumulated a page of
/// them. Every assertion here is a delta from where this run started, which is also how a real
/// client reads the stream.
let headCursor: string | null = null;

async function call(path: string, init: RequestInit = {}): Promise<Response> {
  const token = await sessionToken();
  return fetch(`${target}${path}`, {
    ...init,
    headers: { ...(init.headers ?? {}), authorization: `Bearer ${token}` },
  });
}

async function usedBytes(): Promise<number> {
  const response = await call('/v1/me/usage');
  expect(response.status).toBe(200);
  return ((await response.json()) as { usage: { used: number } }).usage.used;
}

async function remove(id: string): Promise<number> {
  const response = await call(`/v1/findings/${id}?modifiedAt=${Date.now()}`, { method: 'DELETE' });
  return response.status;
}

async function headOfStream(): Promise<string | null> {
  let cursor: string | null = null;
  for (;;) {
    const response = await call(`/v1/findings?limit=500${cursor === null ? '' : `&cursor=${encodeURIComponent(cursor)}`}`);
    expect(response.status).toBe(200);
    const page = (await response.json()) as { nextCursor: string | null; hasMore: boolean };
    cursor = page.nextCursor;
    if (!page.hasMore) return cursor;
  }
}

beforeAll(async () => {
  baselineUsed = await usedBytes();
  headCursor = await headOfStream();
});

afterAll(async () => {
  const failures: string[] = [];
  for (const id of created) {
    const status = await remove(id);
    // A delete is idempotent here -- deleting an id that was never committed simply writes a
    // tombstone -- so 200 is the normal answer even for a finding a failed test never created.
    // 409 would mean something newer arrived, and that would leave bytes behind.
    if (status !== 200) failures.push(`${id} -> ${status}`);
  }
  const finalUsed = await usedBytes();
  if (failures.length > 0) throw new Error(`Teardown could not delete: ${failures.join(', ')}`);
  if (finalUsed !== baselineUsed) {
    throw new Error(`Teardown left ${finalUsed - baselineUsed} bytes behind in staging.`);
  }
});

describe('the deployed staging Worker', () => {
  it('is reachable and reports nothing but liveness', async () => {
    const response = await fetch(`${target}/health`);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true });
  });

  it('refuses an unauthenticated request', async () => {
    const response = await fetch(`${target}/v1/me/usage`);
    expect(response.status).toBe(401);
  });

  it('refuses a token this instance did not issue', async () => {
    const response = await fetch(`${target}/v1/me/usage`, {
      headers: { authorization: 'Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c2VyX2ZvcmdlcnkifQ.nope' },
    });
    expect(response.status).toBe(401);
  });

  it('accepts a real Clerk session token', async () => {
    expect(await subject()).toMatch(/^user_/);
    const response = await call('/v1/me/usage');
    expect(response.status).toBe(200);
    const body = (await response.json()) as { usage: { used: number; limit: number } };
    expect(body.usage.limit).toBe(52_428_800);
  });

  it('round-trips a finding through real R2 and D1', async () => {
    const id = randomUUID();
    created.add(id);
    const modifiedAt = Date.now();
    const image = new Uint8Array(2048).fill(9);
    const meta = { note: 'staging integration test', gps_lat: 49.2, gps_lon: 16.6 };

    const uploadedImage = await call(`/v1/findings/${id}/image?modifiedAt=${modifiedAt}`, {
      method: 'PUT',
      body: image,
    });
    expect(uploadedImage.status).toBe(200);

    const committed = await call(`/v1/findings/${id}/meta?modifiedAt=${modifiedAt}`, {
      method: 'PUT',
      body: JSON.stringify(meta),
    });
    expect(committed.status).toBe(200);
    const committedBody = (await committed.json()) as {
      finding: { id: string; deleted: boolean; bytes: number };
      usage: { used: number };
    };
    expect(committedBody.finding.deleted).toBe(false);
    expect(committedBody.usage.used).toBeGreaterThanOrEqual(baselineUsed + 2048);

    const downloadedImage = await call(`/v1/findings/${id}/image`);
    expect(downloadedImage.status).toBe(200);
    expect(new Uint8Array(await downloadedImage.arrayBuffer())).toEqual(image);

    const downloadedMeta = await call(`/v1/findings/${id}/meta`);
    expect(await downloadedMeta.json()).toEqual(meta);
  });

  it('lists what it stored, and serves a delta from a cursor', async () => {
    const first = randomUUID();
    created.add(first);
    await call(`/v1/findings/${first}/meta?modifiedAt=${Date.now()}`, { method: 'PUT', body: '{"note":"one"}' });

    const page = await call(`/v1/findings?cursor=${encodeURIComponent(headCursor ?? '')}`);
    expect(page.status).toBe(200);
    const body = (await page.json()) as {
      findings: { id: string }[];
      nextCursor: string;
      usage: { used: number; limit: number };
    };
    expect(body.findings.map((row) => row.id)).toContain(first);
    expect(body.usage.limit).toBe(52_428_800);

    const second = randomUUID();
    created.add(second);
    await call(`/v1/findings/${second}/meta?modifiedAt=${Date.now()}`, { method: 'PUT', body: '{"note":"two"}' });

    const delta = await call(`/v1/findings?cursor=${encodeURIComponent(body.nextCursor)}`);
    const deltaBody = (await delta.json()) as { findings: { id: string }[] };
    expect(deltaBody.findings.map((row) => row.id)).toEqual([second]);
  });

  it('refuses an edit older than the one already stored', async () => {
    const id = randomUUID();
    created.add(id);
    const now = Date.now();
    await call(`/v1/findings/${id}/meta?modifiedAt=${now}`, { method: 'PUT', body: '{"note":"newer"}' });

    const stale = await call(`/v1/findings/${id}/meta?modifiedAt=${now - 10_000}`, {
      method: 'PUT',
      body: '{"note":"older"}',
    });
    expect(stale.status).toBe(409);
    expect(((await stale.json()) as { error: { code: string } }).error.code).toBe('stale');
  });

  it('deletes a finding, frees its bytes, and leaves a tombstone that syncs', async () => {
    const id = randomUUID();
    created.add(id);
    const now = Date.now();
    await call(`/v1/findings/${id}/image?modifiedAt=${now}`, { method: 'PUT', body: new Uint8Array(1024).fill(3) });
    await call(`/v1/findings/${id}/meta?modifiedAt=${now}`, { method: 'PUT', body: '{"note":"doomed"}' });
    const withFinding = await usedBytes();

    const deleted = await call(`/v1/findings/${id}?modifiedAt=${now + 1}`, { method: 'DELETE' });
    expect(deleted.status).toBe(200);
    const body = (await deleted.json()) as { finding: { deleted: boolean }; usage: { used: number } };
    expect(body.finding.deleted).toBe(true);
    expect(body.usage.used).toBeLessThan(withFinding);

    expect((await call(`/v1/findings/${id}/image`)).status).toBe(404);

    const page = await call(`/v1/findings?cursor=${encodeURIComponent(headCursor ?? '')}`);
    const listed = ((await page.json()) as { findings: { id: string; deleted: boolean }[] }).findings;
    expect(listed.find((row) => row.id === id)?.deleted).toBe(true);
  });
});
