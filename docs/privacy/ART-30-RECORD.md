# Record of processing activities — Art. 30 GDPR

**Controller:** Vladimír Cortes Slavík, trading as AI Archeology, Veilchenweg 21, 61381 Friedrichsdorf, Germany — info@aiarcheology.com
**Service:** ML Browser (iOS)
**Last reviewed:** 2026-08-26
**Scope of this document:** the whole app. The cloud back-up of findings (AIA-713) is activity **A5** and is the reason this record was written; the other activities are recorded so the register is complete.

No DPO is appointed — the controller is a sole trader, and none of Art. 37(1)(a)–(c) applies: there is no public-authority processing, no large-scale regular and systematic monitoring, and no large-scale processing of Art. 9 data.

---

## A1 — Account and authentication

| | |
|-|-|
| **Purpose** | Create and secure a user account; sign in |
| **Legal basis** | Art. 6(1)(b) — performance of a contract. For SSO, additionally the consent the user gives the identity provider |
| **Data subjects** | App users who choose to create an account |
| **Categories of data** | Email address, name, user identifier; for SSO, the identifier returned by Apple, Google or Meta |
| **Recipients** | Clerk, Inc. (processor); Apple / Google / Meta where the user chooses that sign-in |
| **Transfers** | See §Transfers — Clerk residency is an **open item** |
| **Retention** | For the life of the account. Deletion is user-initiated in the app and propagates to A5 |
| **Security** | TLS in transit; session tokens verified against Clerk's public JWKS with an RS256 allowlist and a 5-second clock tolerance; impersonation (`act`) tokens rejected |

## A2 — Subscriptions

| | |
|-|-|
| **Purpose** | Sell and manage the paid tier |
| **Legal basis** | Art. 6(1)(b) |
| **Categories of data** | Subscription status (active / trial / expired), pseudonymous transaction token. **No card data is received.** |
| **Recipients** | Apple (merchant of record) |
| **Retention** | For the life of the account |

## A3 — Diagnostics and crash reports

| | |
|-|-|
| **Purpose** | Keep the app stable and secure |
| **Legal basis** | Art. 6(1)(f) — legitimate interest in a reliable, secure app. Balancing: personal-identifier collection is disabled by default, no automatic screenshots, no view-hierarchy capture, events filtered before send |
| **Categories of data** | Device model, OS version, app version, technical error context |
| **Recipients** | Sentry (processor) |
| **Retention** | Limited period for analysis and security |

## A4 — Optional product analytics

| | |
|-|-|
| **Purpose** | Aggregate usage understanding |
| **Legal basis** | Art. 6(1)(a) — consent. **Off by default**, opt-in in-app, withdrawable at any time in Settings → Privacy |
| **Recipients** | TelemetryDeck (processor) |
| **Note** | Two account-scoped events only for A5 (sync enabled, quota blocked). Nothing per-finding — per-finding events would amount to measuring an individual's fieldwork rate |

## A5 — Cloud back-up of findings ← *the activity this record exists for*

| | |
|-|-|
| **Purpose** | Back up a user's findings to their account so the work survives a lost, broken or replaced device, and restore them on a new device |
| **Legal basis** | Art. 6(1)(b) — performance of a contract. See "Why 6(1)(b) and not consent" below |
| **Data subjects** | Signed-in users who accept the back-up prompt |
| **Categories of data** | **Content:** finding title, note, label, finder credit (`author`, a free-typed **real name**), source page URL, detection bounding box, **coordinates the user typed in** (`gps`), capture date, and the **screenshot image**. **Index:** Clerk user id, finding id, modified/received timestamps, byte sizes, deletion flag |
| **Special categories (Art. 9)** | None processed |
| **Recipients** | Cloudflare, Inc. (processor) — R2 object storage and D1 database |
| **Transfers** | **Split.** R2 is pinned to the EU jurisdiction, so content stays in the EU. **D1 has no jurisdiction setting** — verified 2026-08-26, `wrangler d1 list` shows an empty jurisdiction column for both databases — so the index may be processed outside the EU under the Cloudflare DPA's SCCs |
| **Retention** | See below |
| **Security** | TLS in transit; encryption at rest by Cloudflare; per-request authorization of the signed-in account against the owning account; per-user and global byte ceilings enforced in a single guarded transaction. **Not end-to-end encrypted** — see the DPIA |

### Why 6(1)(b) and not consent

The back-up *is* the service the user signs in for; the account has no other purpose. Processing is necessary to perform it, so 6(1)(b) is the correct basis and consent would be the wrong one — a withdrawal of consent would have to mean deleting the backup, which is what account deletion already does.

The in-app prompt before a user's existing findings are first uploaded is **not** an Art. 6(1)(a) consent. It is a deliberate design choice for a device that may be shared: findings already on the device may not belong to whoever just signed in. Do not describe it as consent in user-facing text, because that would imply withdrawal semantics that do not apply.

### Retention — stated precisely, because "we delete it" would be untrue

| What | How long | Why |
|-|-|-|
| Finding content (R2 objects) | Until the user deletes the finding or the account | — |
| **Tombstones** (deleted finding's id + timestamp) | **Kept indefinitely** | Garbage-collecting them would resurrect deleted findings on a device that had been offline since before the delete. Content is gone; only the id and timestamp remain |
| **Account-deletion fence row** (Clerk user id) | **Kept after erasure** | It is what makes the purge idempotent against webhook retries. Clerk does not reuse ids |
| D1 Time Travel | ~30 days | Cloudflare platform behaviour; purged rows remain restorable for that window |
| Byte counters | Reset to zero on purge | — |

An erasure request under Art. 17 is satisfied by account deletion, with these three residual items disclosed. They are identifiers and timestamps, not content.

---

## Transfers

| Processor | Role | Location / mechanism | Status |
|-|-|-|-|
| Cloudflare, Inc. | R2 + D1 (A5) | R2 **EU-pinned**; D1 **not region-pinned** — SCCs via the Cloudflare DPA | R2 verified 2026-08-26; **DPA version/date to record** |
| Clerk, Inc. | Identity (A1) | **Open item** — see below | **To verify** |
| Apple | Distribution, payments, SSO | Apple's own terms | — |
| Sentry | Diagnostics (A3) | SCCs | **DPA version/date to record** |
| TelemetryDeck | Analytics (A4), consent-gated | EU-based | — |

## Open items — do not treat as answered

1. **Clerk data residency / DPF status.** The staging Worker points at `advanced-tetra-5.clerk.accounts.dev`, a **development** instance; the production issuer is still `REPLACE_BEFORE_PRODUCTION_DEPLOY`. Before production launch, record which Clerk instance production uses, whether EU residency is enabled on it, and whether Clerk is certified under the EU–US Data Privacy Framework. Write the answer here even if it is "US-hosted under SCCs".
2. **DPA versions and dates** for Cloudflare, Clerk and Sentry. Reference the executed version, not "they have one".
3. **D1 region.** If Cloudflare later offers a jurisdiction for D1, revisit — pinning the index would close the only remaining EU-boundary gap in A5.

## Art. 33 — personal data breach

Notification to the Hessischer Beauftragte für Datenschutz und Informationsfreiheit within **72 hours** of becoming aware, unless the breach is unlikely to result in a risk.

Because A5 is not end-to-end encrypted, the Art. 34(3)(a) exemption (data unintelligible to an unauthorised party) **is not available** for a compromise of the Cloudflare account. Communication to affected users must be assumed to be required. See the DPIA for why that trade was made.

First actions on suspicion: rotate the Cloudflare API tokens and the Clerk webhook signing secret; establish which user prefixes were reachable; preserve the D1 Time Travel window before it expires.

---

See [`DPIA-CLOUD-FINDINGS.md`](DPIA-CLOUD-FINDINGS.md) for the risk assessment, and [`../../USER_DATA_PERSISTENCE.md`](../../USER_DATA_PERSISTENCE.md) for what the system actually does.
