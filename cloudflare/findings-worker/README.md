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
| Quota | 50 MB per user, plus an account-wide ceiling. Every response carries `usage`. |

## API

All paths need `Authorization: Bearer <clerk session token>` except `/health`. Every write carries
`?modifiedAt=<ms since epoch>`.

| | |
|-|-|
| `GET /health` | liveness only, unauthenticated |
| `GET /v1/me/usage` | `{usage:{used,limit}}` |
| `GET /v1/findings?cursor=&limit=` | a page of `{id,modifiedAt,receivedAt,deleted,bytes}` plus `nextCursor`, `hasMore`, `usage` |
| `GET /v1/findings/:id/meta` | the stored `meta.json` |
| `GET /v1/findings/:id/image` | the stored JPEG |
| `PUT /v1/findings/:id/image` | stores the image. Writes no index row. |
| `PUT /v1/findings/:id/meta` | stores the metadata, **then** commits the index row |
| `DELETE /v1/findings/:id` | tombstones the finding and frees its bytes |

Errors are `{"error":{"code","message","retryable"}}`. `retryable` is part of the contract, not a
hint: the client outbox parks a finding on a terminal error and backs off on a retryable one.
`unauthorized` is retryable (refresh the token); `quota_exceeded`, `payload_too_large`, `stale` and
`bad_request` are terminal.

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
is enforced against bytes actually read; and an aborted streaming `put` leaves a partial object
that cannot be un-written. Both caps sit far below the Worker's memory limit.

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
Worker. It refuses to start unless the target is plainly a staging host, and it deletes everything
it created; the bucket's 7-day expiry rule is a backstop for a crashed run, not the mechanism.

### Deploying

```sh
npm run migrate:staging
npm run deploy:staging
```

Production is configured but deliberately not deployed. Its Clerk values are placeholders, so a
premature production deploy refuses every request rather than trusting development-instance tokens;
set a real production issuer and JWKS first.
