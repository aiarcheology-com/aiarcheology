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
  actor?: Record<string, unknown>;
}

export async function tokenFor(subject: string, options: TokenOptions = {}): Promise<string> {
  if (signingKey === null) throw new Error('installTestKeySet() has not run.');
  const nowSeconds = Math.floor(Date.now() / 1000);
  return new SignJWT(options.actor === undefined ? {} : { act: options.actor })
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

export interface BucketFaults {
  /// Caps every listing at this many objects, so a purge reaches its batch budget with a handful
  /// of objects instead of thousands.
  listLimit?: number;
  /// Makes the N-th listing (1-based) throw, to inject a failure at a chosen point of a purge.
  failListAt?: number;
  /// Makes every listing throw.
  failEveryList?: boolean;
  /// Runs before the N-th listing (1-based) is answered, to interleave another actor at that point.
  beforeListing?: { at: number; run: () => Promise<void> };
}

/// The real bucket with faults injected into `list`. Every other method is the real one, bound to
/// the real bucket: a native binding method invoked with the proxy as `this` throws.
export function faultyBucket(real: R2Bucket, faults: BucketFaults): R2Bucket {
  let listings = 0;
  return new Proxy(real, {
    get(target, property) {
      if (property === 'list') {
        return async (options?: R2ListOptions): Promise<R2Objects> => {
          listings += 1;
          if (faults.failEveryList === true || faults.failListAt === listings) {
            throw new Error('injected R2 failure');
          }
          if (faults.beforeListing?.at === listings) await faults.beforeListing.run();
          return target.list(faults.listLimit === undefined ? options : { ...options, limit: faults.listLimit });
        };
      }
      const value = (target as unknown as Record<PropertyKey, unknown>)[property];
      return typeof value === 'function' ? (value as (...args: unknown[]) => unknown).bind(target) : value;
    },
  });
}

/// The real database with `batch` made to throw, to inject a failure at the purge's index wipe.
export function databaseWithFailingBatch(real: D1Database): D1Database {
  return new Proxy(real, {
    get(target, property) {
      if (property === 'batch') {
        return async (): Promise<never> => {
          throw new Error('injected D1 failure');
        };
      }
      const value = (target as unknown as Record<PropertyKey, unknown>)[property];
      return typeof value === 'function' ? (value as (...args: unknown[]) => unknown).bind(target) : value;
    },
  });
}
