# findings-worker

The backend for cloud findings (AIA-713 Phase 2). It authenticates a user, enforces a quota, and
stores one object per finding in R2 with an index in D1.

Provisioning, jurisdiction and cost constraints live in [PROVISIONING.md](./PROVISIONING.md). Read
its "Rule zero" before touching anything: **no script, test or agent may reach
`aia-findings-production`.**

## Shape

| | |
|-|-|
| Auth | Clerk session token, verified against the instance's public JWKS. No Clerk secret. |
| Objects | `findings/<clerk-user-id>/<finding-id>/{meta.json,image.jpg}` in R2 |
| Index | D1: `finding` (sync truth), `object_bytes` (storage truth), `counter` (account total) |
| Quota | 50 MB per user, plus an account-wide ceiling. Authenticated JSON responses carry `usage`. |

## API

All paths need `Authorization: Bearer <clerk session token>` except `/health`. Every write carries
`?modifiedAt=<ms since epoch>`.

| | |
|-|-|
| `GET /health` | liveness only, unauthenticated |
| `GET /v1/me/usage` | `{usage:{used,limit}}` |
| `GET /v1/findings?cursor=&limit=` | a page of `{id,modifiedAt,receivedAt,deleted,bytes,hasImage}` plus `nextCursor`, `hasMore`, `usage` |
| `GET /v1/findings/:id/meta` | the stored `meta.json` |
| `GET /v1/findings/:id/image` | the stored JPEG |
| `PUT /v1/findings/:id/image` | stores the image. Writes no index row. |
| `PUT /v1/findings/:id/meta` | stores the metadata, **then** commits the index row |
| `DELETE /v1/findings/:id` | tombstones the finding and frees its bytes |

Errors are `{"error":{"code","message","retryable"}}`. **`code` is the normative key** — a client's
state machine should branch on it — and `retryable` is the coarse summary derived from it, which the
outbox uses to decide between backing off and parking.

| code | | |
|-|-|-|
| `unauthorized` | 401 | retryable — refresh the token and try again |
| `global_capacity` | 507 | retryable — the *service* is full, not this user; it clears without them acting |
| `internal` | 500 | retryable — includes a concurrent write to the same finding |
| `quota_exceeded` | 507 | terminal — only pruning or exporting makes room |
| `stale` | 409 | terminal — carries `error.winner`; apply the winner instead of retrying |
| `payload_too_large` | 413 | terminal |
| `bad_request` | 400 | terminal |
| `not_found` | 404 | terminal — also the answer for another user's finding, deliberately |

`meta.json` is stored and returned verbatim; the Worker checks only that it parses and fits the cap.
Its schema belongs to the client, and keeping the server incurious about it means site coordinates
and author names are never parsed, logged or indexed here.

## Three things that look like details and are not

**Clients page on `receivedAt`, never on `modifiedAt`.** A finding created offline three weeks ago
and uploaded today carries a three-week-old `modifiedAt`. A cursor over `modifiedAt` would file it
behind another device's high-water mark and that device would never see it. `received_at` is a
per-user monotonic server clock, and the cursor is the `(received_at, id)` pair so a page boundary
cannot fall between two findings that share an instant.

**The index row is the commit point.** Image, then metadata, then the row. A crash between the R2
writes leaves orphan bytes that a retry overwrites; the reverse order leaves an index row pointing
at an object that is not there, which reads as corruption on every device that syncs it. Byte
accounting runs *before* each R2 write, so a failed write over-counts -- the safe direction for a
cost guard -- rather than under-counts.

**Bodies are buffered under a hard cap, not streamed.** `Content-Length` is not trusted, so the cap
is enforced against bytes actually read, and refusing before anything reaches the bucket is the
simplest thing that is obviously correct. The cost is memory — a Worker's 128 MB is shared across
concurrent requests — so streaming through a counting transform is the answer if enough
simultaneous 16 MB uploads ever appear.

**Byte accounting is one transaction.** The size record and both counters move together in a single
`db.batch()`, guarded so they apply or don't as a unit. Split apart, a counter that rises while the
size record doesn't makes the next retry compute its delta against a stale size and add the bytes
again — permanently, account-wide, with nothing to reconcile it.

## Known gaps, written down rather than discovered later

- **Orphan bytes are charged but cannot be listed.** An image uploaded whose metadata never commits
  occupies storage and counts against the user, deliberately — otherwise an abandoned upload would
  be free storage. But nothing enumerates them, so "prune findings" is not advice that reaches
  them. The uploading client knows the id and can `DELETE` it; another device cannot. A reaper is
  the missing half.
- **An image write is only published by the metadata write that follows it.** A client that sends an
  image and never commits its metadata leaves the index row advertising the old state, and no other
  device can tell. The client contract is image *then* metadata, always.
- **Staleness is checked before the body is read**, so a 16 MB upload is refused only after it has
  been sent. A client should compare against the list endpoint's `modifiedAt` before uploading.
- **The staging expiry rule deletes R2 objects without touching D1**, so a forgotten test run can
  leave index rows pointing at objects that are gone. Teardown is the mechanism; the rule is the
  backstop for a crashed run.
- **A stale check and the write that follows it are not one atomic step.** Immutable, revision-scoped
  keys would close it; at one-user-per-account that has not been worth the complexity.

## Working on it

```sh
npm install
npm run typecheck
npm test                 # Workers runtime, Miniflare-local R2 and D1, a local JWKS
npm run dry-run          # validates both environment configs without deploying
```

`npm test` never reaches a real bucket: `remoteBindings` is false, and the suite's caps and issuer
are overridden locally.

### Staging end to end

```sh
cp .dev.vars.example .dev.vars   # fill in; it holds a test-user password and is untracked
npm run test:e2e
```

This signs in through the Clerk Frontend API -- the same public flow the iOS app uses, needing no
`sk_test_` secret -- and drives real uploads, downloads and deletes against the deployed staging
Worker. That flow is chosen because it works without a backend credential, and it is sensitive to
things Clerk can change: bot protection, a password policy, MFA on the test user. If it starts
failing for a reason that is not this Worker, the durable alternative is minting a token with the
`sk_test_` backend key from 1Password. It refuses to start unless the target is plainly a staging host, and it deletes everything
it created; the bucket's 7-day expiry rule is a backstop for a crashed run, not the mechanism.

### Deploying

```sh
npm run migrate:staging
npm run deploy:staging
```

Production is configured but deliberately not deployed. Its Clerk values are placeholders, so a
premature production deploy refuses every request rather than trusting development-instance tokens;
set a real production issuer and JWKS first.
