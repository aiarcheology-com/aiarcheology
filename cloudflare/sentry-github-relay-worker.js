// Cloudflare Worker: Sentry issue webhooks -> GitHub Issues
//
// Features:
// - Verifies Sentry webhook signature (best-effort across common formats)
// - Handles `sentry-hook-resource: issue` webhooks only
// - Filters out simulator AppHang issues (local dev environment noise)
// - Dedupes by searching for a stable marker in existing GitHub issues
// - Creates a GitHub issue on `action: created` with label `bug`
// - Adds the issue to a GitHub Project V2 board (if GH_PROJECT_ID is set)
// - Sanitizes title by stripping leading "ISO_TIMESTAMP File.swift:123 " when present
// - Enriches GitHub body from the latest Sentry event (best-effort), copying only
//   allowlisted tag values and in-app exception frames; no user, device-identifier,
//   context, request or raw JSON data leaves Sentry
//
// Required Cloudflare env vars (Settings -> Variables/Secrets):
// - GH_OWNER
// - GH_REPO
// - GITHUB_TOKEN (needs repo scope; project scope only required if GH_PROJECT_ID is set)
// - SENTRY_WEBHOOK_SECRET
//
// Optional Cloudflare env vars:
// - SENTRY_API_TOKEN (required only for enrichment: fetching the Sentry issue + latest event)
// - GH_PROJECT_ID (GitHub Project V2 node ID, e.g., PVT_kwDODw8uZM4BMCyN)
//   Get this via: gh api graphql -f query='{ organization(login: "YOUR_ORG") { projectsV2(first: 10) { nodes { id number title } } } }'
//
// Notes:
// - If enrichment shows "no issue details fetched", check Worker logs for:
//   - `hasSentryApiToken: false` (env var not applied to the environment), or
//   - Sentry API errors (401/403/404) in `Sentry enrichment failed: ...`.
// - If issues are not added to the project, check that GITHUB_TOKEN has `project` scope.

function hexFrom(buf) {
  return [...new Uint8Array(buf)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

async function hmacSha256Hex(secret, message) {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const mac = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(message)
  );
  return hexFrom(mac);
}

function timingSafeEqual(a, b) {
  if (!a || !b || a.length !== b.length) return false;
  let out = 0;
  for (let i = 0; i < a.length; i++) out |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return out === 0;
}

async function verifySentry(request, rawBody, secret) {
  const sigHeader = request.headers.get("sentry-hook-signature") || "";
  const ts = request.headers.get("sentry-hook-timestamp") || "";
  if (!secret || !sigHeader || !ts) return false;

  const sig = sigHeader.trim().replace(/^sha256=/, "").replace(/^v0=/, "");

  // Replay window: 10 minutes
  const now = Math.floor(Date.now() / 1000);
  const tsInt = Number(ts);
  if (!Number.isFinite(tsInt) || Math.abs(now - tsInt) > 600) return false;

  // Try a few common signing formats
  const candidates = [
    `${ts}.${rawBody}`,
    `${ts}:${rawBody}`,
    `v0:${ts}:${rawBody}`,
    `v0:${ts}.${rawBody}`,
    rawBody,
  ];

  for (const msg of candidates) {
    const expected = await hmacSha256Hex(secret, msg);
    if (timingSafeEqual(expected, sig)) return true;
  }

  return false;
}

async function ghFetch(env, path, init = {}) {
  const resp = await fetch(`https://api.github.com${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${env.GITHUB_TOKEN}`,
      Accept: "application/vnd.github+json",
      "User-Agent": "sentry-github-relay",
      ...(init.headers || {}),
    },
  });

  const text = await resp.text();
  if (!resp.ok) throw new Error(`GitHub API ${resp.status} ${path} ${text}`);
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

async function addIssueToProject(env, issueNodeId) {
  const projectId = env.GH_PROJECT_ID;
  if (!projectId || !issueNodeId) return null;

  const query = `
    mutation AddItemToProject($projectId: ID!, $contentId: ID!) {
      addProjectV2ItemById(input: {projectId: $projectId, contentId: $contentId}) {
        item { id }
      }
    }
  `;

  const resp = await fetch("https://api.github.com/graphql", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.GITHUB_TOKEN}`,
      "Content-Type": "application/json",
      "User-Agent": "sentry-github-relay",
    },
    body: JSON.stringify({
      query,
      variables: { projectId, contentId: issueNodeId },
    }),
  });

  if (!resp.ok) {
    const bodyText = await resp.text().catch(() => "");
    const snippet = bodyText.length > 500 ? bodyText.slice(0, 500) + "…" : bodyText;
    throw new Error(
      `GitHub GraphQL HTTP error ${resp.status} ${resp.statusText || ""}`.trim() +
        (snippet ? `: ${snippet}` : "")
    );
  }
  const result = await resp.json();
  if (result.errors) {
    throw new Error(
      `GraphQL error adding issue ${issueNodeId} to project ${projectId}: ${JSON.stringify(result.errors)}`
    );
  }
  return result;
}

async function fetchWithTimeout(url, init, timeoutMs) {
  const controller = new AbortController();
  const t = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...init, signal: controller.signal });
  } finally {
    // clearTimeout is safe even if the timeout has already fired (no-op in that case).
    // This ensures the timer is cleaned up when the fetch completes successfully before timeout.
    clearTimeout(t);
  }
}

async function sentryFetch(env, url, timeoutMs = 7000) {
  const resp = await fetchWithTimeout(
    url,
    {
      headers: {
        Authorization: `Bearer ${env.SENTRY_API_TOKEN}`,
        Accept: "application/json",
        "User-Agent": "sentry-github-relay",
      },
    },
    timeoutMs
  );

  const text = await resp.text();
  if (!resp.ok) throw new Error(`Sentry API ${resp.status} ${url} ${text}`);
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

// Only these event tag values are copied into GitHub issues. Everything else
// (user ids, device identifiers, contexts, request data, raw issue/event JSON)
// stays in Sentry, reachable through the console link.
const ALLOWED_TAG_KEYS = [
  "environment",
  "release",
  "dist",
  "distribution_channel",
  "build_configuration",
  "app_version",
  "app_build",
  "os",
  "os.name",
  "os.build",
  "device",
  "device.family",
  "device.class",
  "mechanism",
  "handled",
  "level",
];

const MAX_TAG_VALUE_CHARS = 200;
const MAX_FRAMES = 25;

function cleanValue(value) {
  if (typeof value !== "string" && typeof value !== "number" && typeof value !== "boolean") return null;
  const s = String(value).replace(/[\r\n`]/g, " ").trim();
  if (!s) return null;
  return s.length > MAX_TAG_VALUE_CHARS ? `${s.slice(0, MAX_TAG_VALUE_CHARS)}…` : s;
}

function basename(path) {
  if (typeof path !== "string") return null;
  return path.split(/[\\/]/).pop() || null;
}

// Exception types and in-app stack frames (function, file name, line) only.
// Exception messages are omitted: in a browser app they can carry visited URLs.
function exceptionSummary(eventDetails) {
  const entries = Array.isArray(eventDetails?.entries) ? eventDetails.entries : [];
  const exception = entries.find((e) => e?.type === "exception");
  const values = Array.isArray(exception?.data?.values) ? exception.data.values : [];
  const lines = [];
  for (const v of values) {
    const type = cleanValue(v?.type);
    if (type) lines.push(`- **${type}**`);
    const frames = Array.isArray(v?.stacktrace?.frames) ? v.stacktrace.frames : [];
    const inApp = frames.filter((f) => f?.inApp === true).reverse().slice(0, MAX_FRAMES);
    for (const f of inApp) {
      const fn = cleanValue(f?.function) || "?";
      const file = cleanValue(basename(f?.filename));
      const line = Number.isInteger(f?.lineNo) ? f.lineNo : null;
      const loc = file ? ` (${file}${line !== null ? `:${line}` : ""})` : "";
      lines.push(`  - \`${fn}\`${loc}`);
    }
  }
  return lines;
}

function keyTagLines(eventTags) {
  return ALLOWED_TAG_KEYS.map((k) => [k, cleanValue(getTagValue(eventTags, k))])
    .filter(([, v]) => v !== null)
    .map(([k, v]) => `- **${k}**: ${v}`);
}

function getTagValue(tagsArray, key) {
  if (!Array.isArray(tagsArray)) return null;
  const found = tagsArray.find((t) => t && t.key === key);
  return found ? found.value ?? null : null;
}

// Check if an issue should be filtered out (not forwarded to GitHub)
// Returns { filtered: boolean, reason: string | null }
//
// Filter logic mirrors SentryCrashReportingService.swift:
// - options.environment is set to envName ("simulator", "production", "testflight", "development", "unknown")
// - AppHang issues from simulator are local dev noise and should not create GitHub issues
//
// Note: Issue webhooks don't include tag VALUES, only tag keys.
// We must fetch the latest event to get actual values for filtering.
async function shouldFilterIssue(env, issue) {
  // Need to fetch event data to get actual tag values
  const issueApiUrl = issue?.url;
  if (!issueApiUrl || !env.SENTRY_API_TOKEN) {
    // Can't fetch event data, don't filter
    return { filtered: false, reason: null };
  }

  try {
    const issueId = issue?.id;
    const org = issueApiUrl.match(/\/organizations\/([^/]+)\//)?.[1];
    if (!org || !issueId) {
      return { filtered: false, reason: null };
    }

    // Fetch latest event
    const eventsListUrl = `https://sentry.io/api/0/organizations/${org}/issues/${issueId}/events/?per_page=1`;
    const events = await sentryFetch(env, eventsListUrl, 4000);
    if (!Array.isArray(events) || events.length === 0) {
      return { filtered: false, reason: null };
    }

    // Event tags are in format: [{key: "...", value: "..."}, ...]
    const eventTags = events[0]?.tags || [];
    const mechanism = getTagValue(eventTags, "mechanism");
    const environment = getTagValue(eventTags, "environment");

    // Filter: AppHang + simulator environment (local dev noise)
    if (mechanism === "AppHang" && environment === "simulator") {
      return { filtered: true, reason: "AppHang from simulator" };
    }
  } catch (e) {
    console.log("Filter check failed (allowing issue):", e?.message || String(e));
  }

  return { filtered: false, reason: null };
}

function deriveSentryHtmlIssueUrlFromApiUrl(apiUrl) {
  // From: https://sentry.io/api/0/organizations/<org>/issues/<issueId>/
  // To:   https://<org>.sentry.io/issues/<issueId>/
  if (typeof apiUrl !== "string") return null;
  const m = apiUrl.match(
    /^https:\/\/sentry\.io\/api\/0\/organizations\/([^/]+)\/issues\/(\d+)\/?/
  );
  if (!m) return null;
  const org = m[1];
  const issueId = m[2];
  return `https://${org}.sentry.io/issues/${issueId}/`;
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    if (url.pathname !== "/sentry/webhook") return new Response("Not Found", { status: 404 });
    if (request.method === "GET") return new Response("ok", { status: 200 });
    if (request.method !== "POST") return new Response("Method Not Allowed", { status: 405 });

    // Validate required GitHub-related environment variables early to surface
    // configuration issues with a clear error instead of opaque runtime failures.
    const missingEnv = [];
    if (!env.GH_OWNER) missingEnv.push("GH_OWNER");
    if (!env.GH_REPO) missingEnv.push("GH_REPO");
    if (!env.GITHUB_TOKEN) missingEnv.push("GITHUB_TOKEN");

    if (missingEnv.length > 0) {
      return new Response(
        `Missing required environment variable(s): ${missingEnv.join(
          ", ",
        )}. Please configure them in the Cloudflare Worker settings.`,
        {
          status: 500,
          headers: {
            "content-type": "text/plain; charset=utf-8",
          },
        },
      );
    }

    const raw = await request.text();

    const ok = await verifySentry(request, raw, env.SENTRY_WEBHOOK_SECRET);
    if (!ok) return new Response("Unauthorized", { status: 401 });

    const hookResource = request.headers.get("sentry-hook-resource") || "unknown";
    if (hookResource !== "issue") {
      return new Response(`ok (ignored resource ${hookResource})`, { status: 200 });
    }

    let payload;
    try {
      payload = JSON.parse(raw);
    } catch {
      return new Response("Bad JSON", { status: 400 });
    }

    const action = String(payload.action || "unknown");
    const issue = payload?.data?.issue || payload?.issue;

    const issueId = String(issue?.id || "unknown");
    if (issueId === "unknown") return new Response("ok (no issue id)", { status: 200 });

    // Return early for non-created actions to avoid consuming GitHub search quota
    if (action !== "created") {
      return new Response(JSON.stringify({ ok: true, action }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }

    const marker = `Sentry issue id: ${issueId}`;

    // Dedupe by marker in existing GH issues (GitHub Search requires is:issue)
    // Check duplicates FIRST to avoid unnecessary Sentry API calls for already-tracked issues
    const q = encodeURIComponent(`repo:${env.GH_OWNER}/${env.GH_REPO} is:issue in:body "${marker}"`);
    const found = await ghFetch(env, `/search/issues?q=${q}&per_page=1&page=1`);
    const existing = found?.items?.[0] ?? null;

    const isDuplicate =
      !!existing &&
      typeof existing.body === "string" &&
      existing.body.includes(marker);

    if (isDuplicate) {
      return new Response(JSON.stringify({ ok: true, action, existing: existing?.html_url ?? null }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }

    // Filter out noise issues (e.g., AppHang from simulator)
    // This fetches the latest event to check actual tag values
    // Only runs for new issues (not duplicates) to save Sentry API quota
    const filterResult = await shouldFilterIssue(env, issue);
    if (filterResult.filtered) {
      console.log(`Filtered issue ${issueId}: ${filterResult.reason}`);
      return new Response(
        JSON.stringify({ ok: true, filtered: true, reason: filterResult.reason }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      );
    }

    const rawTitle = String(issue?.title || `Sentry issue ${issueId}`);

    // Sanitize leading "ISO_TIMESTAMP File.swift:123 " from Sentry titles
    const m = rawTitle.match(
      /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z)\s+([A-Za-z0-9_.-]+\.swift:\d+)\s+(.*)$/
    );
    const capturedAt = m ? m[1] : null;
    const sourceLoc = m ? m[2] : null;
    const issueTitle = m ? m[3] : rawTitle;

    // Prefer the API URL if Sentry provides it; else fallback to permalink.
    const issueApiUrl = issue?.url || null;
    const issueHtmlUrl =
      issue?.permalink ||
      deriveSentryHtmlIssueUrlFromApiUrl(issueApiUrl) ||
      null;

    // Create the GitHub issue fast (keep Sentry happy), then enrich asynchronously.
    const body = [
      `Created automatically from Sentry.`,
      ``,
      `## Sentry`,
      marker,
      issueHtmlUrl ? `Console: ${issueHtmlUrl}` : null,
      issueApiUrl ? `API: ${issueApiUrl}` : null,
      capturedAt ? `Captured at: ${capturedAt}` : null,
      sourceLoc ? `Source: ${sourceLoc}` : null,
      ``,
      `## Details`,
      `_Enrichment pending…_`,
    ]
      .filter((v) => v !== null && v !== "")
      .join("\n");

    let created = null;
    try {
      created = await ghFetch(env, `/repos/${env.GH_OWNER}/${env.GH_REPO}/issues`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ title: issueTitle, body, labels: ["bug"] }),
      });
    } catch (e) {
      console.error("GitHub issue creation failed:", e);
      return new Response(JSON.stringify({ ok: false, error: "GitHub issue creation failed" }), {
        status: 502,
        headers: { "Content-Type": "application/json" },
      });
    }

    // Add issue to project board
    if (created?.node_id && env.GH_PROJECT_ID) {
      try {
        await addIssueToProject(env, created.node_id);
        console.log(`Added issue ${created.number} to project ${env.GH_PROJECT_ID}`);
      } catch (e) {
        // Log as error for better monitoring visibility (e.g., may indicate permissions issue)
        console.error(`Failed to add issue ${created.number} to project ${env.GH_PROJECT_ID}:`, e?.message || String(e));
        // Don't fail the webhook if project addition fails
      }
    }

    // Background enrichment (best-effort). Will not delay webhook response.
    if (ctx && issueApiUrl && env.SENTRY_API_TOKEN && created?.number) {
      ctx.waitUntil(
        (async () => {
          let issueDetails = null;
          let eventDetails = null;

          try {
            console.log("enrich:", {
              hasIssueUrl: Boolean(issueApiUrl),
              hasSentryApiToken: Boolean(env.SENTRY_API_TOKEN),
              issueId,
            });

            // 1) Issue JSON
            issueDetails = await sentryFetch(env, issueApiUrl, 6000);

            // 2) Latest event JSON (best-effort)
            const org = issueApiUrl.match(/\/organizations\/([^/]+)\//)?.[1] || null;
            if (org) {
              const eventsListUrl = `https://sentry.io/api/0/organizations/${org}/issues/${issueId}/events/?per_page=1`;
              const events = await sentryFetch(env, eventsListUrl, 6000);
              const firstEventId =
                Array.isArray(events) && events.length > 0
                  ? events[0].id || events[0].eventID || events[0].eventId
                  : null;

              if (firstEventId) {
                // Event details endpoint typically requires project context.
                // Prefer: /api/0/projects/<org>/<project>/events/<eventId>/
                const projectSlug =
                  issueDetails?.project?.slug ||
                  issueDetails?.projectSlug ||
                  null;

                if (projectSlug) {
                  const eventUrl = `https://sentry.io/api/0/projects/${org}/${projectSlug}/events/${firstEventId}/`;
                  eventDetails = await sentryFetch(env, eventUrl, 6000);
                } else {
                  console.log("No project slug available for event fetch; skipping event details.");
                }
              }
            }
          } catch (e) {
            console.log("Sentry enrichment failed:", e?.message || String(e));
          }

          const tagLines = keyTagLines(eventDetails?.tags);
          const exceptionLines = exceptionSummary(eventDetails);

          const enrichedBody = [
            `Created automatically from Sentry.`,
            ``,
            `## Sentry`,
            marker,
            issueHtmlUrl ? `Console: ${issueHtmlUrl}` : null,
            issueApiUrl ? `API: ${issueApiUrl}` : null,
            capturedAt ? `Captured at: ${capturedAt}` : null,
            sourceLoc ? `Source: ${sourceLoc}` : null,
            ``,
            `## Key tags (from latest event)`,
            ...(tagLines.length
              ? tagLines
              : [`_No event tag values available (event fetch failed or returned no tags)._`]),
            ``,
            `## Exception (in-app frames, from latest event)`,
            ...(exceptionLines.length ? exceptionLines : [`_No exception data available._`]),
            ``,
            `_User, device-identifier, context and request data are not copied here; open the Sentry console link for full details._`,
          ]
            .filter((v) => v !== null && v !== "")
            .join("\n");

          try {
            await ghFetch(env, `/repos/${env.GH_OWNER}/${env.GH_REPO}/issues/${created.number}`, {
              method: "PATCH",
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify({ body: enrichedBody }),
            });
          } catch (e) {
            console.log("GitHub body update failed:", e?.message || String(e));
          }
        })()
      );
    }

    return new Response(JSON.stringify({ ok: true, created: created?.html_url }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  },
};


