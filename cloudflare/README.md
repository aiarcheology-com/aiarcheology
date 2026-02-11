# Sentry → Cloudflare Worker → GitHub Issues (+ Project) Relay

This folder contains the Cloudflare Worker that turns **Sentry Issue webhooks** into **GitHub Issues**, plus optional **Sentry API enrichment** (issue + event JSON) stored in the GitHub issue body.

- Worker source: `cloudflare/sentry-github-relay-worker.js`

## Architecture (high level)

```mermaid
flowchart LR
  A[iOS app<br>Observability → Sentry SDK] -->|event/crash| B[Sentry Project<br>Issues grouping]
  B -->|issue.created webhook<br>sentry-hook-resource: issue| C[Cloudflare Worker<br>sentry-github-relay]
  C -->|create issue label: bug| D[GitHub Issues<br>aiarcheology-com/aiarcheology]
  C -->|fetch issue + latest event JSON<br>Sentry API token| B
  C -->|PATCH body with enrichment| D
  C -->|GraphQL: addProjectV2ItemById<br>if GH_PROJECT_ID set| E[GitHub Project V2]
  D -->|AIA-#### title normalization<br>repo workflow| F[GitHub Actions<br>auto-issue-key.yml]
```

## What this pipeline does

- **Event-driven**: no polling / no scheduled GitHub Actions to fetch Sentry.
- **Dedupe**: one GitHub issue per Sentry issue group (uses a stable marker in the GitHub issue body).
- **Readable titles**: strips a leading `ISO_TIMESTAMP File.swift:line` prefix from Sentry titles (when present) and moves those details into the body.
- **Richer context**: fetches additional structured data via Sentry REST API and stores a redacted + size-capped JSON snapshot in the GitHub issue body.
- **Project integration**: automatically adds issues to GitHub Project V2 via GraphQL (optional, requires `GH_PROJECT_ID` env var).

## 1) Cloudflare Worker setup

1. Create a Cloudflare Worker (start with “Hello World”).
2. Copy/paste the code from `cloudflare/sentry-github-relay-worker.js` into the Worker editor.
3. Deploy.

### Worker URL

Your Sentry webhook URL should point to:

- `https://<worker>.<subdomain>.workers.dev/sentry/webhook`

## 2) Sentry: create an Internal Integration (Custom Integration)

In Sentry:

1. Go to **Settings → Developer Settings → Custom Integrations**
2. Create an **Internal Integration**
3. Set:
   - **Name**: `GitHub Issue Relay` (any)
   - **Webhook URL**: your Worker URL (example above)
   - **Alert Rule Action**: optional (not required for issue webhooks; useful for separate notifications)
4. Webhook subscriptions:
   - Enable **`issue: created`** (required)
   - Optional: `resolved`, `unresolved`, `assigned`, `archived` (only if you later add state syncing)
   - Disable noisy types like `error.created` unless you explicitly want per-event webhooks

### Webhook signature secret

Sentry signs webhook requests and sends headers such as:

- `sentry-hook-signature`
- `sentry-hook-timestamp`
- `sentry-hook-resource`

The Worker validates this signature using `SENTRY_WEBHOOK_SECRET`.

## 3) Sentry: create an API token (for enrichment)

This is used by the Worker to fetch JSON from Sentry’s REST API (issue details + events).

1. In the same Internal Integration, create a **Token** (“New Token”).
2. Scopes/permissions:
   - Minimum: **Issue & Event → Read**
   - If Sentry requires it in your org: also enable **Project → Read**
3. Copy the token and store it in Cloudflare as `SENTRY_API_TOKEN` (Secret).

## 4) Cloudflare Worker environment variables / secrets

In Cloudflare Worker **Settings → Variables**, set:

### GitHub

- `GH_OWNER`: `aiarcheology-com` (organization name)
- `GH_REPO`: `aiarcheology` (repository name)
- `GITHUB_TOKEN`: GitHub Personal Access Token with `repo` and `project` scopes (store as **Secret**)
  - Required scopes: `repo` (create/update issues), `project` (add to Projects V2)
  - Create at: GitHub → Settings → Developer settings → Personal access tokens
- `GH_PROJECT_ID` (optional): GitHub Project V2 node ID (e.g., `PVT_kwDODw8uZM4BMCyN`)
  - Get via: `gh api graphql -f query='{ organization(login: "aiarcheology-com") { projectsV2(first: 10) { nodes { id number title } } } }'`
  - If not set, issues will still be created but not automatically added to the project

### Sentry

- `SENTRY_WEBHOOK_SECRET`: secret used for verifying Sentry webhook signature (store as **Secret**)
- `SENTRY_API_TOKEN`: Sentry API token for enrichment (store as **Secret**)

## 5) GitHub: repository + project automation

### Labels

The Worker creates issues with label:

- `bug`

Adjust in `cloudflare/sentry-github-relay-worker.js` if you want different labeling.

### Adding issues to GitHub Project V2

**Option 1: Direct integration (recommended)**

The Worker automatically adds issues to your project when `GH_PROJECT_ID` is configured:
- Uses GitHub GraphQL API (`addProjectV2ItemById` mutation)
- Requires `GITHUB_TOKEN` with `project` scope
- Adds issue immediately after creation

**Option 2: GitHub Project workflow (alternative)**

If you prefer not to use direct integration, you can use GitHub's built-in automation:

1. Open Project → **Workflows**
2. Add **Auto-add to project** workflow
3. Filter example: `is:issue is:open label:bug`

Note: Both methods work, but direct integration is faster and more reliable.

### Optional: title normalization / key prefix

This repository uses `.github/workflows/auto-issue-key.yml` to prefix titles with `AIA-####:` and add a share/branch comment.

The Worker sanitizes the base title before GitHub Actions prefixes it.

## Operational notes

- **Sentry grouping**: GitHub issues are created on `issue.created`. If you trigger the same stacktrace again, Sentry will usually group it into an existing issue and no new GitHub issue will be created.
- **Time limits**: the Worker responds quickly and runs enrichment in the background to avoid webhook cancellations.
- **Privacy**: enrichment JSON is **redacted** and **size-capped**. If you want more/less redaction, edit `redact()` and `jsonBlock()` in the Worker.


