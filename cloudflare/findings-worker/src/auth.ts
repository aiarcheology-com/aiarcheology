import { createRemoteJWKSet, jwtVerify } from 'jose';
import { ApiError } from './errors';
import type { Env } from './env';

type JWKSet = ReturnType<typeof createRemoteJWKSet>;

/// Cached per isolate, keyed by URL so a configuration change cannot be served by a stale key set.
/// `jose` handles rotation and its own fetch caching behind this.
let cachedUrl: string | null = null;
let cachedKeys: JWKSet | null = null;

function keySet(url: string): JWKSet {
  if (cachedUrl !== url || cachedKeys === null) {
    cachedUrl = url;
    cachedKeys = createRemoteJWKSet(new URL(url));
  }
  return cachedKeys;
}

/// Verifies a Clerk session token and returns the user id it asserts.
///
/// The Worker holds no Clerk secret: verification needs only the issuer and its public JWKS. The
/// user id always comes from the token's `sub`, never from a path segment, header or body field, so
/// there is no request a client can shape that reaches another user's data.
export async function authenticate(request: Request, env: Env): Promise<string> {
  if (!env.CLERK_ISSUER?.startsWith('https://') || !env.CLERK_JWKS_URL?.startsWith('https://')) {
    // Fails closed: an unconfigured environment refuses every request rather than trusting tokens
    // from whatever instance happens to answer.
    throw new ApiError('config_error', 'This environment has no Clerk issuer configured.');
  }

  const header = request.headers.get('authorization');
  const token = header?.match(/^Bearer (.+)$/i)?.[1]?.trim();
  if (!token) {
    throw new ApiError('unauthorized', 'A Clerk session token is required.');
  }

  let subject: unknown;
  try {
    const { payload } = await jwtVerify(token, keySet(env.CLERK_JWKS_URL), {
      issuer: env.CLERK_ISSUER,
      clockTolerance: 30,
    });
    subject = payload.sub;
  } catch {
    // Deliberately opaque: distinguishing "expired" from "bad signature" tells an attacker which
    // half of a forged token to work on.
    throw new ApiError('unauthorized', 'The session token is not valid.');
  }

  if (typeof subject !== 'string' || subject.length === 0 || subject.length > 128) {
    throw new ApiError('unauthorized', 'The session token carries no usable subject.');
  }
  return subject;
}
