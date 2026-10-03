// Run: node --test cloudflare/sentry-github-relay-worker.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import worker from "./sentry-github-relay-worker.js";

const USER_ID = "id:6F1C2B8E-USER-0000-0000-000000000001";
const DEVICE_ID = "A1B2C3D4-DEVICE-IDFV-0000-000000000002";
const VISITED_URL = "https://private.example/visited?q=secret";

const event = {
  id: "ev1",
  tags: [
    { key: "environment", value: "production" },
    { key: "release", value: "1.0.8 (42)" },
    { key: "device", value: "iPhone16,1" },
    { key: "os", value: "iOS 26.0" },
    { key: "user", value: USER_ID },
    { key: "device_id", value: DEVICE_ID },
    { key: "url", value: VISITED_URL },
  ],
  user: { id: USER_ID, ip_address: "203.0.113.9" },
  contexts: { device: { device_unique_identifier: DEVICE_ID }, app: { device_app_hash: DEVICE_ID } },
  request: { url: VISITED_URL },
  entries: [
    {
      type: "exception",
      data: {
        values: [
          {
            type: "NSInvalidArgumentException",
            value: `failed to load ${VISITED_URL}`,
            stacktrace: {
              frames: [
                { function: "main", filename: "/Users/builder/app/main.swift", lineNo: 3, inApp: true },
                { function: "objc_exception_throw", filename: "libobjc", inApp: false, package: "/private/var/containers/X" },
                { function: "BrowserView.load(_:)", filename: "/Users/builder/app/BrowserView.swift", lineNo: 88, inApp: true },
              ],
            },
          },
        ],
      },
    },
  ],
};

async function enrichedBodyFor(latestEvent) {
  const issueApiUrl = "https://sentry.io/api/0/organizations/org/issues/123/";
  const payload = JSON.stringify({ action: "created", data: { issue: { id: "123", title: "Crash", url: issueApiUrl } } });
  const ts = String(Math.floor(Date.now() / 1000));
  const sig = createHmac("sha256", "whsec").update(`${ts}.${payload}`).digest("hex");

  const patches = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    const u = String(url);
    const json = (o) => new Response(JSON.stringify(o), { status: 200 });
    if (u.includes("/search/issues")) return json({ items: [] });
    if (u.endsWith("/issues") && init.method === "POST") return json({ number: 7, html_url: "gh/7" });
    if (u.includes("/issues/7") && init.method === "PATCH") {
      patches.push(JSON.parse(init.body).body);
      return json({});
    }
    if (u === issueApiUrl) return json({ project: { slug: "ios" }, userCount: 1, metadata: { value: VISITED_URL } });
    if (u.includes("/events/?per_page=1")) return json([{ id: "ev1", tags: latestEvent.tags }]);
    if (u.includes("/projects/org/ios/events/ev1/")) return json(latestEvent);
    throw new Error(`unexpected fetch ${u}`);
  };

  const pending = [];
  try {
    const request = new Request("https://relay/sentry/webhook", {
      method: "POST",
      headers: { "sentry-hook-signature": sig, "sentry-hook-timestamp": ts, "sentry-hook-resource": "issue" },
      body: payload,
    });
    const env = { GH_OWNER: "o", GH_REPO: "r", GITHUB_TOKEN: "t", SENTRY_WEBHOOK_SECRET: "whsec", SENTRY_API_TOKEN: "s" };
    const resp = await worker.fetch(request, env, { waitUntil: (p) => pending.push(p) });
    assert.equal(resp.status, 200);
    await Promise.all(pending);
  } finally {
    globalThis.fetch = originalFetch;
  }

  assert.equal(patches.length, 1);
  return patches[0];
}

test("enriched GitHub body keeps allowlisted tags and in-app frames only", async () => {
  const body = await enrichedBodyFor(event);
  assert.match(body, /Sentry issue id: 123/);
  assert.match(body, /\*\*environment\*\*: production/);
  assert.match(body, /\*\*release\*\*: 1\.0\.8 \(42\)/);
  assert.match(body, /\*\*device\*\*: iPhone16,1/);
  assert.match(
    body,
    /- \*\*NSInvalidArgumentException\*\*\n  - `BrowserView\.load\(_:\)` \(BrowserView\.swift:88\)\n  - `main` \(main\.swift:3\)/,
  );
  assert.doesNotMatch(body, /objc_exception_throw/);
});

test("enriched GitHub body contains no user, device, URL or path data", async () => {
  const body = await enrichedBodyFor(event);
  for (const leaked of [USER_ID, DEVICE_ID, VISITED_URL, "private.example", "203.0.113.9", "/Users/builder", "/private/var"]) {
    assert.ok(!body.includes(leaked), `body leaked ${leaked}`);
  }
});

test("enrichment tolerates events without tags or exception data", async () => {
  const body = await enrichedBodyFor({ id: "ev1", entries: [{ type: "exception", data: { values: [{}] } }] });
  assert.match(body, /_No event tag values available/);
  assert.match(body, /_No exception data available\._/);
});
