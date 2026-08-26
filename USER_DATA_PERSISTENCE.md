# User data synchronization

How a user's findings get from a phone in a field to the cloud and back, and the rules that decide
what happens when two devices disagree.

Scope: the findings a user records — a screenshot, a bounding box, notes, an author credit, and GPS
coordinates. **That payload is the reason most of the rules below exist.** Precise coordinates of an
archaeological site attached to a named person is personal data under GDPR, and it is also exactly
what looters want. Losing it is bad; leaking it is worse.

Implemented across AIA-713: the Worker in `cloudflare/findings-worker/` (#726), the client in
`ios/MLBrowser/iOS/State/FindingsSyncCoordinator.swift` and
`ios/MLBrowser/iOS/Services/FindingsSyncLedger.swift` (#727), account deletion (#728).

## 1. Shape

```
iOS app ──HTTPS, Clerk session token──▶ Cloudflare Worker ──▶ R2 (EU)   objects
                                                          └─▶ D1        index + quota
```

One object per finding, never an archive:

```
findings/<clerk-user-id>/<finding-id>/meta.json
findings/<clerk-user-id>/<finding-id>/image.jpg
```

A zip would force a full read-modify-write to change one finding, break per-item retry, and make
quota accounting impossible without unzipping it. The export ZIP remains the user-facing backup;
individual objects are the sync format.

Storage keys are namespaced by the **verified** Clerk `sub`, never by anything the client supplies.
Two accounts using the same finding id stay apart — a case the index lookup alone would not catch.

## 2. Opting in

**Signing in is the opt-in.** A user who never signs in gets exactly the behaviour the app had
before sync existed: nothing runs, nothing leaves the device. There is no separate switch, because
there is nothing a switch would express that signing in does not. Sign-in stays a sheet, never a
gate (AIA-0536).

Sign-out leaves local data untouched.

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
  on every sync.
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

A crash between the two R2 writes leaves orphan bytes that the next retry overwrites. The reverse
order leaves an index row pointing at an object that is not there, which reads as corruption on
every device that syncs it.

Byte accounting runs *before* each R2 write, so a failed write over-counts — the safe direction for
a cost guard — rather than under-counts exactly when a crash left bytes in the bucket.

### Retry and parking

| | |
|-|-|
| Retryable | network, 5xx, `unauthorized` (refresh the token), `global_capacity`, anything unrecognised |
| Terminal for that finding | `quota_exceeded`, `payload_too_large`, `bad_request` |
| Neither | `stale` — apply the winner instead |

Parking is deliberately narrow. An outbox that parks on an ambiguous failure quietly stops backing
somebody up. Editing a parked finding un-parks it: the user changed the thing that was refused.

Triggers are the app coming to the front, connectivity returning, and a local save. A trigger that
arrives mid-cycle schedules another cycle rather than being dropped. There is no timer — a sync with
nothing changed and nothing reconnected has nothing to do.

**The acceptance case:** save a finding in airplane mode, relaunch with a network, and the upload
completes without the user doing anything.

## 7. Quota

50 MB per user, enforced server-side and reported on every authenticated JSON response as
`{used, limit}`. The client pre-checks because a rejected *authenticated* upload still costs a
Class A operation plus ingress; the server decides because two devices each holding 40 MB will both
believe they are under the cap.

The check and the reservation are a single guarded transaction. Read-then-write let three
concurrent 2 KB uploads all succeed against a 4 KB cap in testing.

Storage is accounted separately from sync: `object_bytes` records what is actually stored, including
an image whose metadata never committed, so an abandoned upload is not free storage.

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

## 9. What is deliberately not built

- **No end-to-end encryption.** Compromise of the Cloudflare account yields plaintext, by design.
  The trade is stated plainly rather than implied: it is why there is no Art. 34 exemption.
- **No sharing, publishing or discovery surface.** Private by default, and nothing in the epic may
  add a way for one user to see another's findings.
- **No field-level merge, no conflict UI, no delete-always-wins.**
- **No rate limiting yet**, and no CORS — the client is native.
- **No reaper for orphan bytes.** An image whose metadata never committed is charged to the user but
  cannot be listed, so "prune findings" does not reach it. Known gap, written down rather than
  discovered later.

## 10. Observability

| | |
|-|-|
| Worker | one structured line per request: route template, status, error code, duration. No URLs, ids, subjects or bodies. |
| Client | one `.info` per completed cycle: uploaded, applied, pending, parked, duration. |
| Analytics | exactly two events, both account-scoped under the existing consent model: sync first used, and storage full. |

Nothing per finding. A per-finding event would be a record of how often somebody surveys and where,
which is not ours to collect.
