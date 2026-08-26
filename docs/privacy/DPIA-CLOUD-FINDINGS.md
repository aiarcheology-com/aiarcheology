# DPIA — cloud back-up of findings

**Processing assessed:** activity A5 in [`ART-30-RECORD.md`](ART-30-RECORD.md) — backing up users' findings and screenshots to their account.
**Date:** 2026-08-26 · **Author:** controller · **Status:** live, pending the open items below

## Is a DPIA required?

Strictly, probably not. Art. 35(3) does not obviously bite: there is no systematic and extensive automated evaluation, no large-scale Art. 9 processing, and no systematic monitoring of a publicly accessible area. The scale is small.

It is written anyway because of **what the payload is**, which is the one thing that makes this feature different from any other backup:

> A finding pairs `gps` — coordinates the user typed in — and `author`, a free-typed **real name**, with a screenshot of a lidar or aerial map and the URL of the tile it came from.

That is the precise location of a probable archaeological site attributed to a named person. The privacy risk and the heritage risk point the same way, and the second one is not a GDPR concern at all: **a leak of this dataset is a looting map**. A register entry alone would not have forced that sentence to be written down.

## What is processed

Content (R2, EU-pinned): title, note, label, `author`, source page URL, bounding box, `gps`, capture date, screenshot JPEG.
Index (D1, no region setting): Clerk user id, finding id, timestamps, byte size, deletion flag.

Volume at time of writing: single-digit users, tens of findings. The assessment is written for the scale it could reach, not the scale it is at.

## Necessity and proportionality

The purpose — surviving a lost or replaced phone — cannot be met without storing the data off the device. Alternatives considered:

- **Device-to-device transfer only.** Fails the actual scenario: the phone is already gone.
- **User-driven ZIP export** (which ships, AIA-713 Phase 1). Real mitigation, and it remains available — but it requires the user to remember. Fieldwork is lost by people who did not expect to lose it.
- **Store less.** The screenshot is the bulk of both the storage and the risk, but a finding without its image is not a restored finding. `gps` and `author` are user-entered and optional — the app does not populate them automatically, so a user who leaves them blank uploads no coordinate and no name.

Minimisation actually applied: no automatic geolocation capture anywhere in the app; nothing is uploaded while signed out; nothing is uploaded for findings the user declined; no per-finding analytics; the index carries no content.

## Risks

### R1 — Compromise of the Cloudflare account exposes site locations and names

**Likelihood:** low. **Impact:** high — irreversible for the heritage site, not merely for the data subject.

Mitigations: API tokens scoped and held outside the repository; R2 EU-pinned; per-request authorization against the owning account; no sharing, publishing or discovery surface of any kind, so there is no path by which one user reads another's findings through the product itself.

**Residual risk: accepted, and material.** The data is **not end-to-end encrypted** — see D1 below. A compromise yields plaintext.

### R2 — Operator access

Anyone with R2 access on the Cloudflare account can read any user's findings. This is inherent to a recoverable backup and is now **stated in the privacy policy** (§3.5, "Who can read it") rather than left implicit.

Mitigations: access limited to support requests, security investigation and deletion verification. **To do:** review who holds production R2 permissions and reduce to the minimum; the account is currently a sole trader's, so this is about token hygiene rather than staff.

### R3 — Shared device: one person's findings uploaded to another's account

A device may be used by more than one person, and findings already on it may not belong to whoever just signed in.

Mitigation, implemented: findings the account did not create locally and has never sent are **not uploaded until the user is asked**. Declining records the decision so the outbox stops re-deriving them. Findings created while signed in are the account's by construction and are not re-asked about.

**Residual risk: low.** Note the current one-way-door defect (#740) is a usability failure in the *safe* direction — it under-shares rather than over-shares.

### R4 — Index processed outside the EU

D1 has no jurisdiction setting (verified 2026-08-26). Clerk user ids, finding ids, timestamps and sizes may leave the EU.

Mitigations: SCCs under the Cloudflare DPA; the index holds **no content** — no title, note, coordinate or image. What leaks from the index alone is that an account exists and has *N* findings changed at certain times.

**Residual risk: low, accepted, disclosed** in the privacy policy §3.5 and §6. Revisit if Cloudflare offers a D1 region.

### R5 — Deletion does not fully delete

The deletion fence row retains a Clerk user id, and D1 Time Travel retains purged rows for ~30 days. (Tombstones are kept only until the account is deleted; the purge removes them with every other row.)

Each is deliberate and load-bearing — see the retention table in the Art. 30 record. Both are identifiers and timestamps, never content. The per-finding tombstone is disclosed in privacy policy §7; the fence row and the Time Travel window are recorded here and in the Art. 30 record, and are not separately named to users — they are operational identifiers carrying no finding content.

**Residual risk: low, accepted.**

### R6 — Quota exhaustion or cost blow-up

Per-user (50 MiB) and global byte ceilings are enforced inside a single guarded transaction, and the totals they check are recomputed from the recorded object sizes in that same transaction, so concurrent uploads can neither race past the limit nor leave a total that disagrees with what is stored (AIA-751). A blocked upload is reported to the user and nothing already stored is deleted. Running out of room is treated as curable: deleting a finding lifts the block.

Not a privacy risk; recorded because availability is an Art. 32 concern.

## The decision not to encrypt end-to-end

Stated explicitly because it is the first question any reviewer will ask, and silence would read as an oversight rather than a choice.

End-to-end encryption would eliminate R1's plaintext exposure and R2 entirely. It was rejected because key management would make the feature's own promise unreliable: a user who loses their key loses the fieldwork permanently, with no recovery path — and "you have lost a season of survey" is a worse outcome, and a far likelier one, than a breach of the storage account.

Consequences accepted alongside it:

- The Art. 34(3)(a) exemption is **not available**. A compromise means notifying users.
- Operator access exists and is disclosed rather than obscured.

This should be revisited if the user base changes character — for example if professional units store restricted-site data, where the calculus flips.

## Outcome

Proceed. Residual risk is acceptable at this scale with the mitigations above, provided the open items in the Art. 30 record are closed before production launch. Clerk residency was answered on 2026-08-26 (no EU option exists; transfers rely on the EU–US Data Privacy Framework) and the production Clerk issuer is configured and verified (`clerk.aiarcheology.com`, AIA-741).

**Review triggers:** a change in what a finding contains (especially automatic geolocation); enabling any sharing surface; a materially larger or more professional user base; Cloudflare offering a D1 region.
