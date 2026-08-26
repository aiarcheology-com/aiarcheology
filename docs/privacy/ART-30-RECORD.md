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
| **Transfers** | US. Clerk offers no EU residency; covered by their EU–US Data Privacy Framework certification — see §Transfers |
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

| Processor | Role | Location / mechanism | DPA | Status |
|-|-|-|-|-|
| Cloudflare, Inc. | R2 + D1 (A5) | R2 **EU-pinned**; D1 **not region-pinned** — SCCs via the Cloudflare DPA | [cloudflare.com/cloudflare-customer-dpa](https://www.cloudflare.com/cloudflare-customer-dpa/) — self-serve, incorporated by accepting the terms; carries no version date in the page itself | R2 jurisdiction verified 2026-08-26 |
| Clerk, Inc. | Identity (A1) | **US-hosted.** Clerk offers no EU data residency; transfers rely on Clerk's **EU–US Data Privacy Framework certification**, not SCCs | [clerk.com/legal/dpa](https://clerk.com/legal/dpa) — **26 November 2024** | Verified 2026-08-26 |
| Apple | Distribution, payments, SSO | Apple's own terms | Apple Developer Program agreement | — |
| Sentry | Diagnostics (A3) | SCCs | [sentry.io/legal/dpa](https://sentry.io/legal/dpa/) — self-serve; carries no version date in the page itself | — |
| TelemetryDeck | Analytics (A4), consent-gated | EU-based | Included in their terms | — |

All three self-serve DPAs are incorporated by accepting the provider's terms — none requires a signature, which is why there is nothing "executed" to file. What this record needs is the URL and the version in force, checked 2026-08-26.

## Open items — do not treat as answered

1. ~~**Clerk data residency.**~~ **Answered 2026-08-26 — no residency setting exists to enable.**

   The production instance is **`clerk.aiarcheology.com`**, confirmed against its own
   `/.well-known/openid-configuration`; it is what the production Worker trusts and what the shipping
   `pk_live_` key resolves to (AIA-741).

   Clerk does **not** offer EU data residency. Their privacy policy states information "may be
   transferred, processed, and stored anywhere in the world, including … the United States", and
   nothing in their docs index, pricing or dashboard offers a data region. Their DPA states it "has
   been modified to reflect Clerk's certification under the EU-U.S. Data Privacy Framework", and that
   transfers to DPF-certified US entities need no additional mechanism "such as the Standard
   Contractual Clauses".

   **So the transfer mechanism for identity data is the DPF, not SCCs.** That is a stronger basis
   than SCCs, resting on the European Commission's adequacy decision — but it is also a dependency
   worth naming: if the DPF adequacy decision were annulled, as Safe Harbour and Privacy Shield both
   were, this processing would need a new mechanism. Sign-in would keep working; the lawful basis for
   the transfer would not.

   Identity data is email, name and a user id (A1). The findings themselves are unaffected — their
   content is EU-pinned in R2 (A5).

2. ~~**DPA versions and dates** for Cloudflare, Clerk and Sentry.~~ **Done 2026-08-26** — recorded in the Transfers table above. Cloudflare and Sentry publish no version date on the page; if a dated copy is ever needed for an audit, request it from the provider.
3. **D1 region.** If Cloudflare later offers a jurisdiction for D1, revisit — pinning the index would close the only remaining EU-boundary gap in A5.

## Art. 33 — personal data breach

Notification to the Hessischer Beauftragte für Datenschutz und Informationsfreiheit within **72 hours** of becoming aware, unless the breach is unlikely to result in a risk.

Because A5 is not end-to-end encrypted, the Art. 34(3)(a) exemption (data unintelligible to an unauthorised party) **is not available** for a compromise of the Cloudflare account. Communication to affected users must be assumed to be required. See the DPIA for why that trade was made.

First actions on suspicion: rotate the Cloudflare API tokens and the Clerk webhook signing secret; establish which user prefixes were reachable; preserve the D1 Time Travel window before it expires.

---

See [`DPIA-CLOUD-FINDINGS.md`](DPIA-CLOUD-FINDINGS.md) for the risk assessment, and [`../../USER_DATA_PERSISTENCE.md`](../../USER_DATA_PERSISTENCE.md) for what the system actually does.
