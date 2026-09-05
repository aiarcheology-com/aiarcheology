# findings-worker

The backend for cloud findings (AIA-713 Phase 2). It authenticates a user, enforces a quota, and
stores revisioned finding objects in R2 with an index in D1.

Provisioning, jurisdiction and cost constraints live in [PROVISIONING.md](./PROVISIONING.md). Read
its "Rule zero" before touching anything: **no script, test or agent may reach
`aia-findings-production`.**

## Shape

| | |
|-|-|
| Auth | Clerk session token, verified against the instance's public JWKS. No Clerk secret. |
| Objects | `findings/<clerk-user-id>/<finding-id>/<modified-at>/{meta.json,image.jpg}` in R2 |
| Index | D1: `finding` (sync truth and selected object revisions), `finding_revision` (stable future-clock ordering), `object_bytes` (storage truth), `counter` (account total) |
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
| `DELETE /v1/me/data` | erases everything this account has stored |
| `POST /v1/webhooks/clerk` | svix-verified; runs the same purge on `user.deleted` |

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
| `account_deleting` | 410 | terminal — the account is being erased; there is nowhere for this to go |

`meta.json` is stored and returned verbatim; the Worker checks only that it parses and fits the cap.
Its schema belongs to the client, and keeping the server incurious about it means site coordinates
and author names are never parsed, logged or indexed here.

## Three things that look like details and are not

**Clients page on `receivedAt`, never on `modifiedAt`.** A finding created offline three weeks ago
and uploaded today carries a three-week-old `modifiedAt`. A cursor over `modifiedAt` would file it
behind another device's high-water mark and that device would never see it. `received_at` is a
per-user monotonic server clock, and the cursor is the `(received_at, id)` pair so a page boundary
cannot fall between two findings that share an instant.

**The index row is the commit point.** Image, then metadata, then the row. Every R2 key includes
the request's `modifiedAt`, and the winning row records the exact metadata and image revision it
publishes. A losing writer can therefore leave only an unreferenced revision; it can never overwrite
the winner's bytes. Byte accounting runs *before* each R2 write, so a failed write over-counts --
the safe direction for a cost guard -- rather than under-counts.

**A future client timestamp is clamped once.** Its first request records the server-bounded ordering
value; an idempotent retry reuses it. A lost response therefore cannot let an old revision become
newer merely because the server clock advanced.

**Uncommitted bytes have a bounded lifetime.** Each object reservation has a non-renewable timestamp.
A dedicated quarter-hourly run reclaims no-longer-referenced objects after 24 hours, releasing their
R2 keys and quota together. It claims up to 500 D1 rows before deleting R2, so a very late retry
receives a retryable error instead of racing cleanup into deleting a revision that just became live;
a full batch is logged as backlog for operations to investigate.

**Bodies are buffered under a hard cap, not streamed.** `Content-Length` is not trusted, so the cap
is enforced against bytes actually read, and refusing before anything reaches the bucket is the
simplest thing that is obviously correct. The cost is memory — a Worker's 128 MB is shared across
concurrent requests — so streaming through a counting transform is the answer if enough
simultaneous 16 MB uploads ever appear.

**Byte accounting is one transaction.** The size record and both counters move together in a single
`db.batch()`, guarded so they apply or don't as a unit. Split apart, a counter that rises while the
size record doesn't makes the next retry compute its delta against a stale size and add the bytes
again — permanently, account-wide, with nothing to reconcile it.

## Erasing an account

**Purge here, verify it finished, and only then delete the Clerk user.** The other order destroys
the session token, and that token is the only credential that can name this user's objects — they
would sit in the bucket for ever with nothing able to reach them. A purge that did not finish
answers retryably and the caller must not proceed.

Setting the fence (`user_state.deleting`) is the first thing the purge does, and it is never
cleared: Clerk does not reuse user ids, so there is nothing an un-fence would be for. The fence is a
predicate **inside** the write statements, not a check before them — a check that runs first is a
race the purge wins, and the write commits behind the deletion with nothing left to clean it up.

Keeping the fence row is also what makes the endpoint idempotent, which matters more than it sounds:
`user.delete()` fires Clerk's `user.deleted` webhook, so an in-app deletion normally runs the purge
twice at once. The D1 half is a single `db.batch()` with the global decrement computed in SQL,
because reading the counter and writing it back would double-decrement on exactly that race.

**Whether a purge finished is recorded on the fence row, not inferred from the rows it erases**
(`user_state.purged`, AIA-0842). The purge marks itself pending and stamps the attempt as its first
statement; only after a listing has shown the prefix empty does it drop the index, release the
quota and mark itself done, in that one batch. Every crash point in between leaves the account
pending, which is what the daily sweep selects — so an account that outgrows one invocation's
batch budget, or whose purge dies at the boundary, stays discoverable with no credential and no
webhook. Completion is conditional on the attempt's own random ID (not just its millisecond
timestamp), so an overlapping attempt that re-stamped the row and died is not papered over by an
earlier one finishing.

The webhook is the backstop for deletions that never touch the app — the Clerk dashboard, or support
acting on a request. A verified event it does not handle is **acknowledged, not refused**: svix counts
every non-2xx as a failure and retries on a finite schedule (immediately, 5s, 5min, 30min, 2h, 5h,
10h, 10h), then disables an endpoint whose deliveries all fail for five days — which would remove the
backstop silently. Spending that budget refusing events we do not care about buys nothing.

## Known gaps, written down rather than discovered later

- **An image write is only published by the metadata write that follows it.** A client that sends an
  image and never commits its metadata leaves the index row advertising the old state, and no other
  device can tell until the 24-hour staging lifetime expires. The client contract is image *then* metadata,
  always.
- **Staleness is checked before the body is read**, so a 16 MB upload is refused only after it has
  been sent. A client should compare against the list endpoint's `modifiedAt` before uploading.
- **The staging expiry rule deletes R2 objects without touching D1**, so a forgotten test run can
  leave index rows pointing at objects that are gone. Teardown is the mechanism; the rule is the
  backstop for a crashed run.
- **A purge that keeps failing is retried by the sweep, not by svix.** svix's schedule is finite, and
  after it no client can authenticate as the deleted user. So a daily cron re-runs the purge for
  any fence whose purge is not confirmed (`src/sweep.ts`, AIA-0773, AIA-0842). It needs no
  credential: the pending mark on the fence row is the record that a purge was owed, and the purge
  is idempotent. One run confirms up to four already-empty accounts or finishes 7,500 objects of a
  large one, least-recently-attempted first. What is still missing is an alert on the sweep's own
  `{"sweep":"incomplete","remaining":N}` line — a `remaining` that never falls is the one thing this
  service can say about itself that warrants a human, and nothing reads it yet.
- **One object can survive a confirmed purge.** An upload admitted before the fence can finish its
  R2 write after the confirming listing; `refuseIfAccountVanished` then deletes it, but a crash
  between the write and that delete leaves the object behind a fence already marked done. Nothing
  enumerates R2 by prefix outside a purge, so nothing would find it. Pre-existing, and recorded
  here rather than fixed: the fix is a prefix reaper, which is deliberately not built.
- **D1 Time Travel retains purged rows for about 30 days**, and the fence row keeps a Clerk user id
  after erasure. Both belong in the retention record rather than behind a claim of instantaneous
  complete erasure.

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
npm run deploy:staging
```

`deploy:staging` applies pending migrations first and deploys only if they succeed: the Worker reads
columns its migrations add, so a deploy that lands before its migration answers every purge and
sweep with "no such column". Production keeps the same order by hand — the migration gate in
`RELEASE_CHECK.md` comes before the deploy gate. There is no down migration; rolling back means
redeploying the previous Worker, whose statements still work against the newer schema because each
added column has a default.

The production configuration carries the real Clerk issuer (`clerk.aiarcheology.com`, AIA-741). The
placeholder values are therefore not a safety net: the only thing standing between a mistaken deploy
and live traffic is the cloud-findings gate list in `RELEASE_CHECK.md`, so treat that list as the
guard it is.
