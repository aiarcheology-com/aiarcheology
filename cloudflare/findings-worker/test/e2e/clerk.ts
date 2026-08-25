import { clerkFrontendApi, clerkIdentifier, clerkPassword } from './config';

const API_VERSION = '__clerk_api_version=2021-02-05&_clerk_js_version=5.0.0';

/// Clerk session tokens live about a minute, so they are minted on demand and re-minted well
/// before they expire rather than held for the length of a suite.
const TOKEN_LIFETIME_MS = 30_000;

let devBrowserToken: string | null = null;
let sessionId: string | null = null;
let cachedToken: { value: string; mintedAt: number } | null = null;

function query(): string {
  const dev = devBrowserToken === null ? '' : `&__clerk_db_jwt=${encodeURIComponent(devBrowserToken)}`;
  return `?${API_VERSION}${dev}`;
}

/// Signs in through the Clerk Frontend API -- the same public flow the iOS app uses.
///
/// This needs no `sk_test_` backend secret: a development instance issues a dev-browser token,
/// and password sign-in proceeds from there. Minting a token rather than hand-crafting one is the
/// point: the Worker verifies real signatures against Clerk's real JWKS, and a suite that faked
/// either would not be testing authentication at all.
async function signIn(): Promise<void> {
  const api = clerkFrontendApi();

  const browser = await fetch(`${api}/v1/dev_browser`, { method: 'POST', headers: { origin: api } });
  if (!browser.ok) throw new Error(`Clerk dev_browser failed: ${browser.status}`);
  devBrowserToken = ((await browser.json()) as { token?: string }).token ?? null;
  if (devBrowserToken === null) throw new Error('Clerk returned no dev-browser token.');

  const response = await fetch(`${api}/v1/client/sign_ins${query()}`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded', origin: api },
    body: new URLSearchParams({
      strategy: 'password',
      identifier: clerkIdentifier(),
      password: clerkPassword(),
    }),
  });
  const body = (await response.json()) as {
    response?: { status?: string; created_session_id?: string };
    errors?: unknown;
  };
  if (!response.ok || body.response?.status !== 'complete') {
    // Never echo the body: it can carry identifiers, and the password is in the request.
    throw new Error(`Clerk sign-in failed with ${response.status} (${body.response?.status ?? 'no status'}).`);
  }
  sessionId = body.response.created_session_id ?? null;
  if (sessionId === null) throw new Error('Clerk sign-in produced no session.');
}

export async function sessionToken(): Promise<string> {
  if (cachedToken !== null && Date.now() - cachedToken.mintedAt < TOKEN_LIFETIME_MS) {
    return cachedToken.value;
  }
  if (sessionId === null) await signIn();

  const response = await fetch(`${clerkFrontendApi()}/v1/client/sessions/${sessionId}/tokens${query()}`, {
    method: 'POST',
    headers: { origin: clerkFrontendApi() },
  });
  if (!response.ok) throw new Error(`Clerk token mint failed: ${response.status}`);
  const jwt = ((await response.json()) as { jwt?: string }).jwt;
  if (!jwt) throw new Error('Clerk returned no session token.');
  cachedToken = { value: jwt, mintedAt: Date.now() };
  return jwt;
}

/// The Clerk user id the tokens assert, read from the token rather than configured, so the suite
/// cannot be pointed at one account while cleaning up another.
export async function subject(): Promise<string> {
  const [, payload] = (await sessionToken()).split('.');
  return JSON.parse(Buffer.from(payload ?? '', 'base64url').toString()).sub as string;
}
