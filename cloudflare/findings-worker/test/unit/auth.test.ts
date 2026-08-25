import { SELF } from 'cloudflare:test';
import { describe, expect, it } from 'vitest';
import { auth, tokenFor } from './helpers';

describe('authentication', () => {
  it('answers the health probe without a token, and tells the caller nothing else', async () => {
    const response = await SELF.fetch('https://worker.test/health');
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true });
  });

  it('refuses a request with no Authorization header', async () => {
    const response = await SELF.fetch('https://worker.test/v1/me/usage');
    expect(response.status).toBe(401);
    const body = (await response.json()) as { error: { code: string; retryable: boolean } };
    expect(body.error.code).toBe('unauthorized');
    // The outbox must refresh and retry rather than park the finding: an expired token is the
    // normal state of a device that has been offline.
    expect(body.error.retryable).toBe(true);
  });

  it('refuses a token minted by a different issuer', async () => {
    const token = await tokenFor('user_evil', { issuer: 'https://attacker.test' });
    const response = await SELF.fetch('https://worker.test/v1/me/usage', { headers: auth(token) });
    expect(response.status).toBe(401);
  });

  it('refuses an expired token', async () => {
    const token = await tokenFor('user_stale', { expiresAt: Math.floor(Date.now() / 1000) - 120 });
    const response = await SELF.fetch('https://worker.test/v1/me/usage', { headers: auth(token) });
    expect(response.status).toBe(401);
  });

  it('refuses a token whose signature has been tampered with', async () => {
    const token = await tokenFor('user_tampered');
    const [header, payload, signature] = token.split('.');
    const flipped = `${header}.${payload}.${(signature ?? '').slice(0, -2)}AA`;
    const response = await SELF.fetch('https://worker.test/v1/me/usage', { headers: auth(flipped) });
    expect(response.status).toBe(401);
  });

  it('accepts a well-formed token and reports an empty account', async () => {
    const token = await tokenFor('user_fresh');
    const response = await SELF.fetch('https://worker.test/v1/me/usage', { headers: auth(token) });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ usage: { used: 0, limit: 4096 } });
  });
});
