# User data synchronization

How a user's findings get from a phone in a field to the cloud and back, and the rules that decide
what happens when two devices disagree.

Scope: the findings a user records — a screenshot, a bounding box, notes, an author credit, and GPS
coordinates. **That payload is the reason most of the rules below exist.** Precise coordinates of an
archaeological site attached to a named person is personal data under GDPR, and it is also exactly
what looters want. Losing it is bad; leaking it is worse.

Implemented across AIA-713: the Worker in `cloudflare/findings-worker/` (#726), the client in
`ios/MLBrowser/iOS/State/FindingsSyncCoordinator.swift` and
`ios/MLBrowser/iOS/Services/FindingsSyncLedger.swift` (#727), account deletion (#728). Storage became
revisioned and self-reclaiming in #806 (AIA-0753, AIA-0754), deployed to production 2026-08-31 by
`0003_revisions.sql`.

D1 holds five tables: `finding` (sync truth, and the revisions it selects), `finding_revision`
(stable ordering for a future-dated client clock), `object_bytes` (storage truth, one row per
immutable revision), `counter` (per-account and global byte totals) and `user_state` (the
account-deletion fences).

## 1. Shape

```
iOS app ──HTTPS, Clerk session token──▶ Cloudflare Worker ──▶ R2 (EU)   objects
                                                          └─▶ D1        index + quota
```

One object per finding **revision**, never an archive:

```
findings/<clerk-user-id>/<finding-id>/<modified-at>/meta.json
findings/<clerk-user-id>/<finding-id>/<modified-at>/image.jpg
```

A zip would force a full read-modify-write to change one finding, break per-item retry, and make
quota accounting impossible without unzipping it. The export ZIP remains the user-facing backup;
individual objects are the sync format.

**Objects are immutable, and the `<modified-at>` segment is what makes them so** (AIA-0754). Without
it both devices in a conflict write the same key, and the loser's bytes can land *after* the winner's
— so the index commits one revision while R2 holds another's content. A finding torn that way looks
perfectly healthy: new notes, old photograph, no error anywhere. Each write now owns its own key, the
index row records exactly which metadata and image revision it publishes, and a losing writer can
leave only an unreferenced object. Reads resolve through the index (`objectReference`), so a key that
exists but was never committed is never visible.

Storage keys are namespaced by the **verified** Clerk `sub`, never by anything the client supplies.
Two accounts using the same finding id stay apart — a case the index lookup alone would not catch.

## 2. Opting in

**Signing in enables account-backed sync; upload authorization remains separate.** The account's
ledger `backUpEnabled` preference controls uploads, and each finding must satisfy the ownership
or explicit-consent rules below. Signing in does not grant permission to upload every finding
already on the device. Sign-in stays a sheet, never a gate (AIA-0536).

Turning backup off suppresses uploads; it does not disable cloud pulls or pending remote deletions.
Signing out stops account-backed sync and leaves local data untouched. A user who never signs in
does not upload findings through this sync service; explicit sharing/export is a separate action.
The [repository privacy boundary](AGENTS.md#data-and-privacy) distinguishes saved-finding sync from
transient detection frames, which are never uploaded.

## 3. Whose findings are these

The local store is shared by everyone who uses the device. So an account may upload a finding only
when one of these is true:

1. it created that finding on this device while signed in, or
2. it has already sent that finding before, or
3. the user explicitly agreed to back up that finding, by id.

Anything else is somebody else's until the user says otherwise, and the app asks once, naming the
exact findings and the account it is asking about. Declining is remembered.

This is per finding rather than per account on purpose. A single "already answered" flag would mean
one *yes* authorised every finding that appeared on the device afterwards — including the next
person's.

## 4. Ordering: last-write-wins on `modifiedAt`

Every finding carries `modifiedAt`, stamped from a single choke point in `Finding.willSave()`, so no
writer can persist a change without advancing the ordering key. The explicit bypass is
`preservesModifiedAt`, and the download path uses it: applying a cloud copy must not stamp it "now"
and hand this device a false win over the edit it just received.

- The newer `modifiedAt` wins. Equal timestamps are accepted rather than refused, so a retried
  upload is idempotent.
- The server refuses a strictly older write with `409 stale` and returns the winning row, which the
  client applies immediately — a rejected write creates no new receipt, so waiting for it to come
  round on a poll would leave the loser wrong for ever if the cursor had already passed it.
- A future-dated client clock is **clamped to receipt time**, and the client adopts what the server
  stored. A device that kept its own value would see the row as perpetually newer and re-upload it
  on every sync. The clamp is recorded in `finding_revision` and reused for that revision for ever:
  a lost response retried an hour later must not become newer merely because the server clock caught
  up in the meantime. Only future timestamps need a row — one already at or before receipt time is
  its own answer. Note the raw client value, not the clamped one, remains the R2 key, so a finding's
  image and metadata always share a revision even though they arrive in separate requests.
- Timestamps are compared and stored in **whole milliseconds**. `Date` carries sub-millisecond
  precision and the wire carries integers; `1000.7 > 1000` is a difference that never closes.
- Rows migrated from model 0.0.0/0.0.1 arrive with `modifiedAt == nil`. Fall back to
  `creationDate_`, then stamp and persist a real timestamp. **Never treat nil as the epoch** — that
  would lose every legacy finding to any cloud copy at all.

### Delete versus edit

A tombstone is just another indexed row carrying `modifiedAt`, and the same rule decides it. A
delete at T1 loses to an edit at T2 > T1 — the finding comes back — and wins when T1 > T2. No
special-casing, no "delete always wins", no resurrection prompt.

**Tombstones are kept for ever.** Garbage-collecting them resurrects deletes on long-offline
devices.

**An empty local store never deletes cloud data.** Only an explicit per-finding delete, or account
deletion, removes anything.

### The accepted limit

Concurrent edits to the *same* finding on two devices discard the loser silently: no merge, no
field-level reconciliation, no conflict UI. Clock skew decides the winner, and clamping bounds only
the pathological case. Accepted at single-user-per-account scale.

## 5. Paging: receipt order, not edit order

Clients page on `receivedAt`, a per-user monotonic server clock assigned inside the row's own
`INSERT`, using the `(receivedAt, id)` pair as an opaque cursor.

It cannot be `modifiedAt`. A finding created offline three weeks ago and uploaded today carries a
three-week-old timestamp, so a cursor over edit time would file it behind another device's
high-water mark and **that device would never see it**. Receipt order is the only order every
device agrees on.

The pair, not the instant alone, because two findings can share a receipt instant and a page
boundary falling between them would drop one for ever.

A page stops at the first row that did not apply. Advancing past it would move the cursor beyond a
finding this device never received, and nothing would look at it again.

## 6. The outbox

What is owed to the cloud is **derived** from the findings themselves — a finding needs upload when
its `modifiedAt` is newer than what the ledger says was confirmed — so there is no queue to drift
out of step with the store.

Deletes are the exception: a deleted finding leaves nothing to derive from. Unsent tombstones are
the one piece of sync state that is authoritative. They are written **synchronously, before the
Core Data delete commits**, and a tombstone that cannot be written stops the delete. Any suspension
point between recording a delete and performing it is a window where a crash loses the delete, and
the finding returns from another device after the user was told it was gone.

A delete is recorded for the signed-in account *and* for any account whose ledger says it holds
that finding, so deleting while signed out — or as somebody else — still reaches the cloud copy.

### Order of writes, and why

`image.jpg` → `meta.json` → **index row**. The index row is the commit point.

The reverse order leaves an index row pointing at an object that is not there, which reads as
corruption on every device that syncs it.

A crash between the two R2 writes leaves bytes with no index row. Those are **not** overwritten by
the next retry — a retry carrying changed content gets a new revision and therefore a new key, so
nothing is ever clobbered. They are reclaimed instead; see *Reclaiming what was never committed*.

Byte accounting runs *before* each R2 write, so a failed write over-counts — the safe direction for
a cost guard — rather than under-counts exactly when a crash left bytes in the bucket.

Each write also re-checks its own reservation on the **far** side of the R2 put, and deletes the
object it just wrote if that reservation is gone (AIA-0753). The near-side check cannot cover this:
cleanup can claim the row and delete the key *between* the reservation and the write, and the write
then succeeds against an absent key. What that leaves is an object no index row names and no cleanup
pass enumerates — invisible, uncounted, and removable only by erasing the whole account. For this
payload that is a photograph outliving its own deletion, so the write cleans up after itself.

### Retry and parking

| | |
|-|-|
| Retryable | network, 5xx, `unauthorized` (refresh the token), `global_capacity`, anything unrecognised |
| Terminal for that finding | `quota_exceeded`, `payload_too_large`, `bad_request` |
| Neither | `stale` — apply the winner instead |

Parking is deliberately narrow. An outbox that parks on an ambiguous failure quietly stops backing
somebody up. Editing a parked finding un-parks it: the user changed the thing that was refused.

Which is why `stale` is decided on **ordering alone**. A commit is refused for two different
reasons — the write really is older, or its reservation was reclaimed underneath it — and the second
is not staleness at all. Reporting it as `stale` would hand the outbox a terminal answer for an edit
that is genuinely the newest there is, and name an older tombstone as the winner it should apply.
The compare-and-set refuses only strictly older writes, so anything at or above the stored value that
still fails must have failed on its reservation, and gets a retryable error instead.

Triggers are the app coming to the front, connectivity returning, and a local save. A trigger that
arrives mid-cycle schedules another cycle rather than being dropped. There is no timer — a sync with
nothing changed and nothing reconnected has nothing to do.

**The acceptance case:** save a finding in airplane mode, relaunch with a network, and the upload
completes without the user doing anything.

## 7. Quota

50 MB per user, enforced server-side and reported on every authenticated JSON response as
`{used, limit}`. The client does **not** pre-check: it uploads, and parks the finding if the
server refuses. Only the server can decide, because two devices each holding 40 MB will both
believe they are under the cap.

The check and the reservation are a single guarded transaction, and the totals it checks are
recomputed from the recorded object sizes inside that same transaction. Read-then-write let three
concurrent 2 KB uploads all succeed against a 4 KB cap in testing; incrementing a counter under a
post-image guard let two devices writing one object at the same size both charge for it, for ever
(AIA-751).

A quota park is not permanent. Deleting a backed-up finding frees room, and the parks it caused are
lifted on the same cycle — otherwise the advice the app gives ("remove or export findings") would
not work.

Storage is accounted separately from sync: `object_bytes` records what is actually stored — one row
per immutable revision, live and superseded and merely staged alike — so an abandoned upload is not
free storage.

### Reclaiming what was never committed

An upload that reserves bytes and never commits, and a revision the index has moved past, both hold
storage that nothing will ever read. Left alone they are permanent: a reinstalled app never learns
the id, so it cannot delete or even see them, and an account could be storage-blocked by objects its
owner has no way to reach (AIA-0753).

A reservation therefore has a **bounded, non-renewable** lifetime of 24 hours. A quarter-hourly
scheduled run claims expired rows that no live index row references, deletes their R2 keys, and
releases their bytes — up to 500 per run. Replaying the same revision does not extend the clock: the
original `created_at` is preserved, so a crashed or uninstalled client cannot renew a reservation
indefinitely.

D1 and R2 cannot share a transaction, so the claim is the hand-off. A claimed row is refused by both
reservation and commit, which is what stops a request publishing a key that is about to be deleted;
an abandoned claim expires after a short lease, so a crash mid-sweep is recoverable.

Deleting a finding runs the same reclamation immediately for that finding, so the quota comes back
at once rather than a day later — otherwise "storage full, delete findings you no longer need" would
be advice that does not work. It collects only revisions **strictly older than the tombstone**. A
revision at or above it can still win the commit compare-and-set and resurrect the finding, and
collecting one would either park a genuinely newer edit as terminal `stale` or commit its metadata
with the image silently removed behind a `200`.

Above 80% the app warns; at 100% it blocks new uploads and says what to do. **Export keeps working
at 100%** — it is both a data-portability right (GDPR Art. 20) and the only way out of a full
account.

There is also an **account-wide ceiling**, because the per-user cap bounds one user and is not a
spend cap: 10 GB free ÷ 50 MB is exactly 200 users and nothing stops user 201.

## 8. Identity and isolation

- The Worker verifies Clerk session tokens against the instance's public JWKS. It holds **no Clerk
  secret**: verification needs only an issuer and a key set.
- RS256 only, 5 seconds of clock tolerance, impersonation (`act`) tokens refused.
- The user id is the token's `sub`, always. Its shape is validated before it becomes a storage key.
- A finding belonging to another account returns **404, not 403**. Confirming that a finding exists
  but is not yours is itself a disclosure when the subject is site coordinates.
- Responses carry `private, no-store` and `Vary: Authorization`, and the client uses a session with
  no cache at all, so coordinates cannot outlive the sign-out that should have ended them.
- Worker invocation logs are disabled: their URLs contain finding ids.
- The client logs one line per cycle — counts and a duration, no ids, titles or coordinates.

## 9. Erasing an account

**Purge the cloud data, verify it finished, and only then delete the Clerk user.** The other order
destroys the session token, and that token is the only credential that can name this user's objects:
their findings would sit in the bucket for ever with nothing able to reach them. A purge that did
not finish leaves the account intact so the user can try again.

Local findings are **not** deleted. The cloud copy has just been erased, so what is on the device is
the only copy left; this deletes an account, not somebody's fieldwork. The account's own sync
bookkeeping goes with it.

The first thing a purge does is set a write fence, and it is never cleared — Clerk does not reuse
user ids, so there is nothing an un-fence would be for. The fence lives **inside** the write
statements rather than as a check before them, because a check that runs first is a race the purge
wins. A fenced write is refused with `account_deleting`, which is terminal.

Keeping the fence row is also what makes the endpoint idempotent, and that matters: `user.delete()`
fires Clerk's `user.deleted` webhook, so an in-app deletion normally runs the purge twice at once.

The svix-verified webhook is the backstop for deletions that never touch the app — the Clerk
dashboard, or support acting on a request. A verified event it does not handle is acknowledged
rather than refused, because a non-2xx makes svix retry indefinitely and can get the endpoint
disabled, silently removing the backstop.

A purge that did not finish is not forgotten. Whether it finished is recorded on the fence row
itself (`user_state.purged`, AIA-0842), set pending before anything is touched and done only after
a listing has shown the account's storage empty; the daily sweep works through pending purges in
bounded, least-recently-attempted-first batches, with no credential and no webhook. That covers an
account too large for one call, a purge that died at any point, and the fences that predate the
record, which the migration re-opens so each is confirmed once.

Known limits, recorded rather than implied: D1 Time Travel retains purged rows for about 30 days;
the fence row keeps a Clerk user id, and now the time of the last purge attempt, after erasure; and
an upload admitted before the fence whose own clean-up dies mid-way can leave one object behind a
confirmed purge, since nothing enumerates storage by prefix outside a purge.

## 10. What is deliberately not built

- **No end-to-end encryption.** Compromise of the Cloudflare account yields plaintext, by design.
  The trade is stated plainly rather than implied: it is why there is no Art. 34 exemption.
- **No sharing, publishing or discovery surface.** Private by default, and nothing in the epic may
  add a way for one user to see another's findings.
- **No field-level merge, no conflict UI, no delete-always-wins.**
- **No rate limiting yet**, and no CORS — the client is native.
- ~~**No reaper for orphan bytes.**~~ **Built in AIA-0753** — see *Reclaiming what was never
  committed*. An image whose metadata never committed is now reclaimed after its 24-hour staging
  lifetime instead of being charged to the user for ever.
- **No enumeration of R2 by prefix outside account purge.** Both reclamation paths iterate
  `object_bytes`, so anything in the bucket that no row names is invisible to them. Nothing produces
  such an object any more — the far-side reservation check closes the window that did — but objects
  written before the revisioned layout are exactly this shape and were left in place by
  `0003_revisions.sql`. They are erased by account purge, which deletes by prefix, and otherwise
  cleared by hand; `cloudflare/findings-worker/PROVISIONING.md` has the procedure.

## 11. Environments

Two of everything, paired. `PROVISIONING.md` holds the commands; what follows is why the shape is
this way and what breaks when it is not.

| | staging | production |
|-|-|-|
| Worker | `aia-findings-staging` | `aia-findings-production` |
| Clerk instance | `advanced-tetra-5.clerk.accounts.dev` (development) | `clerk.aiarcheology.com` |
| D1 | `aia-findings-staging` | `aia-findings-production` |
| R2 | `aia-findings-staging` (EU) | `aia-findings-production` (EU) |

**The pairing is an isolation boundary, not a convenience.** Each Worker trusts exactly one issuer
and one key set, so a token minted by the other instance cannot be used against it — the two
instances share no signing key (different `kid`, different RSA modulus, verified 2026-08-26), so
verification fails at the signature before any claim is read.

That is worth testing after every issuer change, because **it is the one property no other test
observes**: unauthenticated requests are refused whether or not the issuer is right, so a Worker
pointed at the wrong key set passes every check except this one.

### What is a var and what is a secret

`CLERK_ISSUER` and `CLERK_JWKS_URL` are **public URLs** and live in `wrangler.jsonc` as vars,
committed. The Worker holds **no Clerk secret key** — verification needs only an issuer and a
public key set (§8).

`CLERK_WEBHOOK_SECRET` is a secret, and it is **per endpoint, not per project**: the development and
production signing secrets are different values, and each rotates independently. Using the wrong one
fails in the worst available way — Clerk deletes the user, the app reports success, the Worker
rejects the webhook signature, and the findings stay in R2 for ever. A GDPR erasure that silently
does not erase. After any rotation, push the new value to the environment that owns it.

Cloudflare holds the runtime copy, 1Password is the source of truth, `.dev.vars` is local only and
is never an app secret.

### Two traps that cost time

- **`wrangler` must run from `cloudflare/findings-worker/`.** From the repo root, `secret put`
  prompts, accepts the paste, *then* fails with "Required Worker name missing" — it looks like it
  worked and sets nothing. Note also that the argument is the secret's **name**; the value goes at
  the prompt.
- **A fresh D1 database has no tables.** `wrangler d1 migrations apply <db> --remote --env <env>`
  is a separate step from `deploy`, and skipping it leaves a Worker that answers requests and fails
  every write. Apply the migration **before** deploying the code that needs it, never after.
- **Never edit a migration that has already been applied anywhere.** Wrangler records applied
  migrations by **filename**, with no content hash, so a rewritten file is silently skipped on every
  database that already ran it — and the failure surfaces only as "no such column" on the first
  request that needs the new schema. A schema change is always a new numbered file. This is not
  hypothetical: the revisioned schema was first written as an in-place rewrite of `0001_init.sql`,
  which both live databases had already applied, and it was caught in review rather than in
  production.

### The client half

`FindingsCloudEndpoint.baseURL(for:)` takes a `BackendEnvironment` — the same value
`ClerkAuthProvider.publishableKey` reads, fixed at build time, so the Worker and the Clerk instance
cannot disagree (AIA-0791). The Worker's own `wrangler.jsonc` calls the client's `development`
environment `staging`; `FindingsCloudEndpoint` is the one place the two vocabularies meet. A `nil` there
turns sync off rather than pointing it somewhere wrong, and the back-up button hides itself when it
sees one — so an unconfigured environment is quiet rather than broken. The consequence is that
flipping `nil` to a URL changes the failure mode from *hidden* to *visible*, which is why the
deploy and the migrations are gates in `RELEASE_CHECK.md` rather than remembered.

The shipping app must also carry the publishable key for the matching instance (`pk_live_` for
production). A mismatch is invisible in testing: users sign in successfully and sync nothing,
because the Worker rejects tokens from the other issuer.

## 12. Observability

| | |
|-|-|
| Worker | one structured line per request: route template, status, error code, duration. No URLs, ids, subjects or bodies. |
| Client | one `.info` per completed cycle: uploaded, applied, pending, parked, duration. |
| Analytics | exactly two events, both account-scoped under the existing consent model: sync first used, and storage full. |

Nothing per finding. A per-finding event would be a record of how often somebody surveys and where,
which is not ours to collect.
