import { ApiError, json } from './errors';
import { purgeAccount } from './purge';
import type { Env } from './env';

/// How far a webhook's timestamp may be from now.
///
/// This, plus a purge that is idempotent, is the whole replay defence. A seen-id cache would be
/// more state to get wrong for no gain: replaying a deletion deletes nothing twice.
const TOLERANCE_SECONDS = 300;

/// The Clerk user id shape, matching what `auth.ts` accepts from a token's `sub`.
const SUBJECT = /^[A-Za-z0-9_-]{1,128}$/;

/// Handles Clerk's `user.deleted`, so a deletion started outside the app -- from the Clerk
/// dashboard, or by support acting on a request -- still erases the findings.
///
/// **A verified event we do not handle is acknowledged, not refused.** Answering non-2xx makes svix
/// retry indefinitely and can get the endpoint disabled, which would silently remove the backstop.
/// Only an unverifiable request is refused.
export async function handleClerkWebhook(request: Request, env: Env): Promise<Response> {
  if (request.method !== 'POST') {
    throw new ApiError('not_found', 'No such endpoint.');
  }
  if (!env.CLERK_WEBHOOK_SECRET) {
    throw new ApiError('config_error', 'This environment has no webhook secret configured.');
  }

  const body = await request.text();
  await verify(request, body, env.CLERK_WEBHOOK_SECRET);

  let event: { type?: string; data?: { id?: unknown } };
  try {
    event = JSON.parse(body);
  } catch {
    throw new ApiError('bad_request', 'The webhook body is not JSON.');
  }

  if (event.type !== 'user.deleted') {
    return json({ ok: true, ignored: event.type ?? 'unknown' });
  }

  const userId = event.data?.id;
  if (typeof userId !== 'string' || !SUBJECT.test(userId)) {
    throw new ApiError('bad_request', 'The event names no usable user.');
  }

  const result = await purgeAccount(env, userId);
  return json({ ok: true, purged: result });
}

/// Verifies an svix signature: `v1,<base64>` over `<id>.<timestamp>.<body>`, HMAC-SHA256 with the
/// `whsec_`-prefixed secret.
async function verify(request: Request, body: string, secret: string): Promise<void> {
  const id = request.headers.get('svix-id');
  const timestamp = request.headers.get('svix-timestamp');
  const signatures = request.headers.get('svix-signature');
  if (!id || !timestamp || !signatures) {
    throw new ApiError('unauthorized', 'The webhook is not signed.');
  }

  const sent = Number(timestamp);
  if (!Number.isFinite(sent) || Math.abs(Date.now() / 1000 - sent) > TOLERANCE_SECONDS) {
    throw new ApiError('unauthorized', 'The webhook timestamp is outside the accepted window.');
  }

  const raw = secret.startsWith('whsec_') ? secret.slice('whsec_'.length) : secret;
  const key = await crypto.subtle.importKey(
    'raw',
    Uint8Array.from(atob(raw), (character) => character.charCodeAt(0)),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const signed = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(`${id}.${timestamp}.${body}`));
  const expected = btoa(String.fromCharCode(...new Uint8Array(signed)));

  // The header can carry several space-separated versioned signatures during a secret rotation.
  const accepted = signatures
    .split(' ')
    .some((candidate) => candidate.startsWith('v1,') && timingSafeEqual(candidate.slice(3), expected));
  if (!accepted) {
    throw new ApiError('unauthorized', 'The webhook signature does not match.');
  }
}

/// Constant-time for equal-length inputs. Comparing signatures with `===` leaks how much of a
/// forgery was right through how long the comparison took.
function timingSafeEqual(left: string, right: string): boolean {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
  }
  return difference === 0;
}
