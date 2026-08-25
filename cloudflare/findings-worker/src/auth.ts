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
      // An explicit allowlist, so a key set that ever advertises a weaker algorithm cannot talk
      // this Worker into accepting it.
      algorithms: ['RS256'],
      clockTolerance: 5,
    });
    // An impersonation token carries `act`. Support staff acting as a user is a real Clerk feature
    // and a reasonable thing to want -- but it would silently grant read and write over someone's
    // site coordinates, so it is refused until it is a decision somebody made on purpose.
    if (payload.act !== undefined) {
      throw new Error('actor session');
    }
    subject = payload.sub;
  } catch {
    // Deliberately opaque: distinguishing "expired" from "bad signature" tells an attacker which
    // half of a forged token to work on.
    throw new ApiError('unauthorized', 'The session token is not valid.');
  }

  // The subject becomes a path segment of every storage key this user owns, and that prefix is the
  // isolation boundary account deletion and export will list on. A `/` in it would nest one user's
  // namespace inside another's. Clerk subjects are `user_...` today, but a JWT template can
  // override `sub`, so the shape is checked rather than assumed.
  if (typeof subject !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(subject)) {
    throw new ApiError('unauthorized', 'The session token carries no usable subject.');
  }
  return subject;
}
