import { SignJWT, exportJWK, generateKeyPair } from 'jose';
import { vi } from 'vitest';

export const ISSUER = 'https://issuer.test';
const JWKS_URL = `${ISSUER}/.well-known/jwks.json`;

let signingKey: CryptoKey | null = null;

/// Stands up a local RSA key set at the issuer the test environment trusts, and blocks every other
/// outbound request.
///
/// The suite verifies real RS256 signatures against a real JWKS document; the only thing faked is
/// who published it. Stubbing verification itself would prove nothing about the code path that
/// keeps one user out of another user's findings. Refusing all other egress is the second half:
/// an unexpected outbound call from the Worker fails the test instead of reaching the network.
export async function installTestKeySet(): Promise<void> {
  const { publicKey, privateKey } = await generateKeyPair('RS256', { extractable: true });
  signingKey = privateKey;
  const body = JSON.stringify({
    keys: [{ ...(await exportJWK(publicKey)), kid: 'test-key', alg: 'RS256', use: 'sig' }],
  });

  vi.stubGlobal('fetch', async (input: RequestInfo | URL): Promise<Response> => {
    const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
    if (url === JWKS_URL) {
      return new Response(body, { headers: { 'content-type': 'application/json' } });
    }
    throw new Error(`The Worker made an unexpected outbound request to ${url}`);
  });
}

export interface TokenOptions {
  issuer?: string;
  expiresAt?: number;
}

export async function tokenFor(subject: string, options: TokenOptions = {}): Promise<string> {
  if (signingKey === null) throw new Error('installTestKeySet() has not run.');
  const nowSeconds = Math.floor(Date.now() / 1000);
  return new SignJWT({})
    .setProtectedHeader({ alg: 'RS256', kid: 'test-key' })
    .setSubject(subject)
    .setIssuer(options.issuer ?? ISSUER)
    .setIssuedAt(nowSeconds - 60)
    .setExpirationTime(options.expiresAt ?? nowSeconds + 600)
    .sign(signingKey);
}

export function auth(token: string): Record<string, string> {
  return { authorization: `Bearer ${token}` };
}

export function bytes(length: number, fill = 7): Uint8Array {
  return new Uint8Array(length).fill(fill);
}
