# Findings sync — Cloudflare provisioning

One-time account setup for the findings-sync Worker (AIA-713 Phase 2). Both environments now exist
(staging since Phase 2, production since AIA-741); this records the provisioning steps so they are
not re-derived — and, more importantly, so the **irreversible** ones are not got wrong if they ever
have to be run again.

This is a **separate Worker** from `sentry-github-relay` in the parent folder. That one holds a
GitHub PAT and must not share a public endpoint's blast radius.

## Rule zero: nothing automated may touch production data

**No script, no test, and no AI agent may read, write, or delete objects in
`aia-findings-production`.** It holds real, irreplaceable fieldwork — a season of someone's
survey — and there is no undo: R2 has no recycle bin, and the app's own store is not a backup of
it.

This is enforced structurally in the Worker's test harness, not by remembering it:

- The harness resolves its bucket from configuration and **asserts the name ends in `-staging`
  before any write or delete**, aborting otherwise. Fail closed: an unset or unexpected value
  refuses to run rather than defaulting to anything.
- Test credentials are scoped to the staging environment only. Production secrets are never placed
  where a test can reach them (`wrangler secret put --env staging`, never `--env production`).
- No cleanup helper takes a bucket name as a free parameter that could be pointed at production.
- Production carries **no lifecycle expiry rule**, so no automated policy can delete from it either.

Anything that needs to touch production is a deliberate, human, one-off action — not a script
committed to this repo.

## Read this first: the two things that cannot be undone

1. **R2 jurisdiction is fixed at bucket creation.** There is no move, no copy-in-place, no setting
   to change afterwards — a bucket created in the default jurisdiction has to be deleted and
   recreated, and anything already in it re-uploaded. The findings payload is site coordinates and
   personal notes attached to a named person, so it is **EU**. Always pass `--jurisdiction eu`.
2. **The Cloudflare MCP cannot do this.** Its `r2_bucket_create` tool takes only a name and has no
   jurisdiction parameter, so it silently produces a default-jurisdiction bucket. Use `wrangler`
   or the dashboard's jurisdiction dropdown. Do not use the MCP for bucket creation.

## Prerequisites

- R2 activated on the account. It is free at our scale (10 GB-month storage, 1M Class A and 10M
  Class B operations per month, **no egress charges**), but activation requires a payment method on
  file. Activating R2 is not a plan change; the Workers plan stays Free.
- `wrangler` authenticated: `npx wrangler whoami`.
- The OAuth token needs **`r2:write` and `d1:write`**. A token minted before R2/D1 were used may
  carry only `workers`/`workers_kv` scopes; a `403` on the commands below means exactly that. Fix
  with `npx wrangler login` and consent to R2 and D1.

## Buckets (one per environment)

```sh
npx wrangler r2 bucket create aia-findings-staging    --jurisdiction eu
npx wrangler r2 bucket create aia-findings-production --jurisdiction eu
```

**Both already exist.** Verify jurisdiction the way that actually proves it — the buckets must appear
in the EU listing and be ABSENT from the default one. Trusting the create command's output would not
catch a flag that silently failed to apply:

```sh
npx wrangler r2 bucket list --jurisdiction eu   # expect both
npx wrangler r2 bucket list                     # expect NEITHER
```

The jurisdiction must be repeated in the Worker's binding or it will not resolve the bucket:

```jsonc
"r2_buckets": [
  { "binding": "FINDINGS", "bucket_name": "aia-findings-staging", "jurisdiction": "eu" }
]
```

## D1 (one per environment)

```sh
npx wrangler d1 create aia-findings-staging
npx wrangler d1 create aia-findings-production
```

**Both already exist**, and their ids are recorded in the matching `env` block of
`wrangler.jsonc`:

| | |
|-|-|
| `aia-findings-staging` | `8a5550ce-673c-4ba2-bcb7-57337d5e0009` |
| `aia-findings-production` | `ff7411c4-3add-42aa-836f-eae0b06b6366` |

D1 has no jurisdiction setting today — `wrangler d1 list` prints an empty jurisdiction column for
both. That is an open question for the DPIA, not a residency guarantee, and it is the one place
where EU-pinned R2 does not settle the matter.

Migrations live in `migrations/` and are applied per environment:

```sh
npx wrangler d1 migrations apply aia-findings-staging --env staging --remote
```

`0003_revisioned_objects.sql` changes both D1 and the R2 key layout. A human applies that migration
before deploying the matching Worker, first in staging and then in production through the normal
release gate. Existing R2 objects are retained at their old paths; the deployed Worker's bounded
daily maintenance copies each live object to its revision path before the D1 reference switches and
the legacy copy is removed, so there is no bulk script that reads or mutates production data.

`0001_init.sql` seeds the `global_bytes` counter row. That seed is load-bearing: the ceiling is a
conditional `UPDATE ... WHERE key = 'global_bytes'`, and against a missing row it changes nothing
and reports no error, so an unseeded counter would fail OPEN.

## Environments: bindings are NOT inherited

Every binding declared at the top level must be **re-declared inside each `env` block** with that
environment's own resource id. Wrangler does not inherit them, and the failure mode is staging
writing into production storage.

- Deploy only with `--env`: `wrangler deploy --env staging` / `--env production`. The bare
  top-level config is itself a separate deployment; do not deploy it.
- Validate before committing: `npx wrangler deploy --env staging --dry-run` (and `production`).
- Secrets are per-Worker, and each environment deploys as its own Worker:
  `npx wrangler secret put NAME --env staging`.
- Never edit production's existing resource ids or routes when adding an environment.

## Deployed

| | |
|-|-|
| Staging | `https://aia-findings-staging.vladimir-slavik.workers.dev` |
| Production | `https://aia-findings-production.vladimir-slavik.workers.dev` — deployed 2026-08-26 against the real Clerk issuer (AIA-741) |

## Clerk

The Worker verifies session tokens and needs **no Clerk secret** — only the issuer and JWKS of the
instance it trusts. Only the integration tests need a credential, because they have to *mint* a
token.

Development instance (`advanced-tetra-5`), stored as `op://Personal/ML Browser API Key Clerk`:

| Value | |
|-|-|
| Issuer | `https://advanced-tetra-5.clerk.accounts.dev` |
| JWKS | `https://advanced-tetra-5.clerk.accounts.dev/.well-known/jwks.json` |

Both values are stored correctly on that item; verify with `op read` rather than eyeballing a
truncated display — `/.well-known/jwks` (no suffix) 404s, `/.well-known/jwks.json` is the endpoint.

The staging end-to-end suite mints a token instead of verifying one, and does it **without the
`sk_test_` backend secret**: a development instance issues a dev-browser token from
`POST /v1/dev_browser`, and password sign-in through the Clerk Frontend API proceeds from there —
the same public flow the iOS app uses. The suite reads the test user's credentials from an
untracked `.dev.vars`; see `.dev.vars.example`.

The backend secret below is therefore no longer needed by anything in this repository. It is kept
here only because a future task that has to act *as* the backend (creating or deleting users, say)
would need it. Reference it — never copy it:

| Purpose | Reference |
|-|-|
| Publishable key | `op://Personal/ML Browser API Key Clerk/credential` |
| Backend API secret (tests only) | `op://Personal/ML Browser API Key Clerk/development secret key` |

Resolve with `op read` at runtime and feed it through `wrangler secret put --env staging`, exactly
as `ios/asc.env.template` does for App Store Connect. It is a **development** instance key: it must
never reach a production environment, and never a committed file.

## Clerk webhook (AIA-728)

The findings Worker takes Clerk's `user.deleted` as the backstop for deletions that never go through
the app. Add the endpoint in the Clerk dashboard (Webhooks → add endpoint,
`https://<worker>/v1/webhooks/clerk`, subscribed to `user.deleted`), then put its signing secret
where the Worker can read it:

Clerk generates the secret; you never invent one. Copy it from the endpoint's **Signing Secret**
(`whsec_…`), keep it on the same 1Password item as the rest of the Clerk credentials, and pipe it
straight in — **from this directory**, or wrangler has no configuration file and therefore no Worker
name:

```sh
cd cloudflare/findings-worker
op read "op://Personal/ML Browser API Key Clerk/webhook signing secret" \
  | npx wrangler secret put CLERK_WEBHOOK_SECRET --env staging

npx wrangler secret list --env staging   # names only; the value never comes back
```

**Where it lives, and where it does not.** Cloudflare is the only place the deployed Worker reads it
from. 1Password is the human source of truth, so it can be re-provisioned without regenerating it in
Clerk. `.dev.vars` (untracked) holds it only if you want to exercise the webhook locally under
`wrangler dev`. It never belongs in a committed file, and it is **not** an app secret: nothing in
the iOS bundle should carry a credential that would let it forge deletion webhooks.

Per environment, and **never** `--env production` for a development instance's secret — Clerk's
development and production instances are separate instances with separate endpoints and separate
secrets, and the pairing has to hold:

| Clerk instance | Worker environment | When |
|-|-|-|
| `advanced-tetra-5` (development) | `--env staging` | now |
| production | `--env production` | when the production Worker is first deployed, alongside its real issuer and JWKS |

Without the secret the webhook route answers `503` and refuses everything. It fails closed, so a
missing secret costs the backstop, never the data.

### Noticing a purge that never finished (AIA-0773)

The Worker retries these itself: a daily cron sweeps fences whose data is still there and
re-runs the purge (`src/sweep.ts`). That is the mechanism — **not** a notification, because there is
no notification available to us:

- svix's `message.attempt.exhausted` and `endpoint.disabled` are **operational** webhooks. They go to
  the webhook *sender's* svix account — Clerk's — not to Clerk's customers. They are not in Clerk's
  event catalogue and cannot be subscribed here.
- Workers Observability has metrics, a query builder and export, but **no alert rules on log
  queries**. Alerting means exporting first — Logpush, OTel, or a Tail Worker — into something that
  pages.

So the sweep is the recovery, and the thing worth watching is the sweep's own output. It logs
`{"sweep":"incomplete","remaining":N}` when it finds work and `{"sweep":"failed"}` when it cannot
run. **A `remaining` that does not fall across successive runs is the alertable condition** — one
straggler surviving four runs in a day is a real problem, and it is the only such signal this
service can raise about itself.

Manual recovery, if it ever comes to that: the Clerk dashboard can replay a failed `user.deleted`
message, which needs none of the deleted user's credentials because the route authenticates by
signature and takes the user id from the event. It is bounded by svix's payload retention — 90 days
by default, 30 on the free plan — so it is a fallback, not the plan.

## The free tier is per ACCOUNT, not per bucket

Staging and production draw from **one shared allowance** — 10 GB-month storage, 1M Class A, 10M
Class B per month, across the whole account. 500 MB of test data in staging leaves 9.5 GB for
production; there is no per-bucket quota to isolate them.

Two details make this sharper than a subtraction:

- **Storage bills on the PEAK storage per day, averaged over the month.** Test data that exists for
  an afternoon still counts toward that day's peak; deleting it afterwards does not undo it.
- **Usage rounds up to the next billing unit.** 1.1 GB-month bills as 2 GB-month.

So staging must be actively bounded, not merely tidied occasionally:

- `aia-findings-staging` carries an **object lifecycle rule** that expires objects after 7 days, so
  forgotten test data cannot accumulate into the production allowance. Already applied:

  ```sh
  npx wrangler r2 bucket lifecycle add aia-findings-staging expire-test-data "" \
      --expire-days 7 --jurisdiction eu
  npx wrangler r2 bucket lifecycle list aia-findings-staging --jurisdiction eu   # verify
  ```

  It expires R2 objects without touching D1, so a run that dies before teardown can leave index
  rows pointing at objects that are gone. That is acceptable for staging and is exactly why
  teardown, not the rule, is the mechanism.

  **Production must never get an expiry rule** — it holds real fieldwork. Verify the asymmetry
  after any change: `lifecycle list` on production should show only Cloudflare's default
  multipart-abort rule.
- Integration tests **must delete what they uploaded in teardown**. The 7-day rule is a backstop
  for what teardown misses (a crashed run, a killed process), never the primary mechanism: a test
  suite run twenty times in an afternoon would otherwise hold twenty runs' worth of objects against
  the shared allowance until the rule caught up.
- The global ceiling below must count **both** buckets, not production alone.

## Cost guard — not optional

The 50 MB per-user cap bounds ONE user; it is not a spend cap. 10 GB free ÷ 50 MB is **exactly 200
users** — production alone can consume the entire account allowance, before staging takes any of it
— **and nothing stops user 201** — R2 then bills $0.015/GB-month with no ceiling. Before
production traffic:

- a **global** byte ceiling in the Worker (a cheap D1 aggregate, checked when a user's first upload
  provisions storage), and
- a Cloudflare billing notification as the backstop.
