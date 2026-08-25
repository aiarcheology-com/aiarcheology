# Findings sync — Cloudflare provisioning

One-time account setup for the findings-sync Worker (AIA-713 Phase 2). The Worker itself does not
exist yet; this records the provisioning steps so they are not re-derived — and, more importantly,
so the **irreversible** ones are not got wrong.

This is a **separate Worker** from `sentry-github-relay` in the parent folder. That one holds a
GitHub PAT and must not share a public endpoint's blast radius.

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

Record each `database_id` in the matching `env` block. D1 has no jurisdiction setting today — note
it as an open question for the DPIA rather than assuming EU residency.

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

For the integration tests, which must *mint* a token rather than verify one, the same item carries
a `development secret key` (`sk_test_…`). Reference it — never copy it:

| Purpose | Reference |
|-|-|
| Publishable key | `op://Personal/ML Browser API Key Clerk/credential` |
| Backend API secret (tests only) | `op://Personal/ML Browser API Key Clerk/development secret key` |

Resolve with `op read` at runtime and feed it through `wrangler secret put --env staging`, exactly
as `ios/asc.env.template` does for App Store Connect. It is a **development** instance key: it must
never reach a production environment, and never a committed file.

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

  **Production must never get an expiry rule** — it holds real fieldwork. Verify the asymmetry
  after any change: `lifecycle list` on production should show only Cloudflare's default
  multipart-abort rule.
- Integration tests should delete what they upload, in teardown, rather than relying on the rule.
- The global ceiling below must count **both** buckets, not production alone.

## Cost guard — not optional

The 50 MB per-user cap bounds ONE user; it is not a spend cap. 10 GB free ÷ 50 MB is **exactly 200
users** — production alone can consume the entire account allowance, before staging takes any of it
— **and nothing stops user 201** — R2 then bills $0.015/GB-month with no ceiling. Before
production traffic:

- a **global** byte ceiling in the Worker (a cheap D1 aggregate, checked when a user's first upload
  provisions storage), and
- a Cloudflare billing notification as the backstop.
