import { readFileSync } from 'node:fs';

/// Reads `.dev.vars` (untracked) and the process environment, environment winning.
///
/// The suite needs a test user's password, so it is never committed and never printed.
function settings(): Record<string, string> {
  const found: Record<string, string> = {};
  try {
    const file = readFileSync(new URL('../../.dev.vars', import.meta.url), 'utf8');
    for (const line of file.split('\n')) {
      const match = line.match(/^\s*([A-Z0-9_]+)\s*=\s*"?(.*?)"?\s*$/);
      if (match?.[1] !== undefined) found[match[1]] = match[2] ?? '';
    }
  } catch {
    // Absent file is fine: the environment may carry everything.
  }
  return { ...found, ...(process.env as Record<string, string>) };
}

function required(name: string): string {
  const value = settings()[name];
  if (!value) {
    // Fails closed. An unset target must abort, never fall back to a default that could be
    // anything -- including production.
    throw new Error(`${name} is not set. Copy .dev.vars.example to .dev.vars and fill it in.`);
  }
  return value;
}

/// The one guard that keeps this suite away from production data.
///
/// It is a check on the target itself rather than a promise in a comment: the suite uploads and
/// deletes real objects, so it refuses to run against any host that is not plainly the staging
/// deployment. No helper here takes a bucket or environment as a parameter that could be pointed
/// somewhere else.
const STAGING_WORKER = 'aia-findings-staging';

export function stagingTarget(): string {
  const target = required('E2E_TARGET');
  const url = new URL(target);
  // The check is on the Worker's name, not a substring of the host. Wrangler derives the deployed
  // name from the environment, and only `--env staging` produces this one -- which is as close as a
  // black-box client can get to asserting the binding behind it. A looser pattern would accept
  // something merely named like staging.
  if (url.protocol !== 'https:' || !url.hostname.startsWith(`${STAGING_WORKER}.`)) {
    throw new Error(`Refusing to run: ${url.hostname} is not the ${STAGING_WORKER} Worker.`);
  }
  return target.replace(/\/$/, '');
}

export const clerkFrontendApi = (): string => required('CLERK_FRONTEND_API').replace(/\/$/, '');
export const clerkIdentifier = (): string => required('E2E_CLERK_IDENTIFIER');
export const clerkPassword = (): string => required('E2E_CLERK_PASSWORD');
