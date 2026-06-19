# Implementation Plan — AIA-0340: Authentication & Billing (first version)

> Status: **IMPLEMENTED** in PR #341 (`feature/AIA-0340/clerk-auth` → `develop`). Originally validated via a Codex consult (Clerk iOS SDK + Apple guidelines) and an adversarial `/grill-yourself` review (SHIP after 3 rounds). v1 = dev Clerk instance; production instance/`pk_live_` wiring is deferred (see Open question / Production readiness).
> Issue: https://github.com/aiarcheology-com/aiarcheology/issues/340

## Goal

Add **Clerk-based authentication + access gating** at app launch, on Clerk's **free tier**, with **no custom backend in v1**. Early users are allowed in via a per-user flag; banned/disabled users are locked out. **Subscription billing is deferred to Phase 2** (months out) and will use **StoreKit 2**, not Clerk/Stripe external billing.

## Scope

- **v1 (now):** Clerk auth, launch gate, allow/lock by Clerk user metadata, ban via Clerk Dashboard, distributed via **TestFlight**.
- **Phase 2 (later):** StoreKit 2 subscriptions → entitlement → paywall/locked state. Public App Store submission.

## Key decisions (and why)

| Decision | Rationale |
|-|-|
| Clerk free tier, **no custom backend in v1** | Gate on Clerk user `publicMetadata`; backend only needed in Phase 2 for StoreKit verification. |
| Gate via **`User.publicMetadata.access`** (read from the Clerk `User` object, not a JWT claim) | Avoids editing the session-token JWT template (custom claims may be a paid feature); the SDK exposes `User` directly. |
| **Ban** via Clerk Dashboard `banUser()` | Free; revokes all sessions. No push event — detected via session-refresh failure. |
| **Multi-provider sign-in** (email, phone/SMS, Google, Facebook, Apple SSO) — user-enabled in Clerk | Apple Guideline **4.8 is satisfied because Sign in with Apple is included** alongside Google/Facebook. **Keep Apple SSO enabled as long as any social provider is offered**, or App Review rejects. Adds native setup (redirect scheme, Apple capability, Facebook app) — see "Sign-in providers" below. |
| **TestFlight** for Phase 1 distribution | A closed app behind mandatory login + early-user allowlist resembles beta/early-access; Apple says that belongs on TestFlight, not the public App Store (avoids a 5.1.1 reject). |
| **StoreKit 2** for Phase 2 subscriptions (not Clerk Billing/Stripe) | Apple Guideline 3.1.1 mandates IAP for consumer digital unlocks; Clerk Billing is also beta/USD-only/no-tax. |
| Users overview = **Clerk Dashboard** for v1 | Free hosted user list/search/ban/metadata. (In-app admin surface deferred — see Open Questions.) |

## Architecture

- **`AuthState`** — `@MainActor` observable state object (Harmonize rule: `*State` types are `@MainActor`). Holds the launch-gate state machine: `checkingSession → signedOut → offline → locked → ready`.
- **`ClerkService`** — `actor` (Harmonize rule: services are actors). Wraps Clerk SDK: hydrate session, force-refresh, sign-in/out (all enabled providers), read `User.publicMetadata`.
- **Root gate** — in `MLBrowser.swift`'s `WindowGroup`, *after* `appState.isReady`, branch on `AuthState`:
  - `signedOut` → Sign-in screen
  - `locked` → Locked screen (banned / no `access`)
  - `offline` → "Needs connection" screen (v1 fails closed offline)
  - `ready` → existing `ContentView()`
- Inject via the existing `DependencyContainer`.

## Implementation steps (each with a verify check)

1. **[User-chosen, decoupled] Bump deployment target 17.6 → 18.0.** Not required by auth (Clerk supports iOS 17+); drops the iOS 17.x install base — an explicit product decision. → verify: project builds, CI green.
2. **Add `ClerkKit` / `ClerkKitUI` via SPM** (`https://github.com/clerk/clerk-ios`); store the Clerk **publishable key in `Secrets.xcconfig`** (gitignored; template updated). → verify: package resolves, key injected, no secret committed.
3. **`ClerkService` (actor) + `AuthState` (@MainActor).** Configure Clerk on launch; hydrate persisted session. → verify: cold launch resolves to a deterministic state.
4. **Root gate in `MLBrowser.swift`.** Route Sign-in / Locked / Offline / `ContentView`. → verify: each state renders the right screen.
5. **Entitlement read.** After session refresh, read `Clerk.shared.user?.publicMetadata["access"]`; allowed → `ready`, else → `locked`. Set the flag per user in the Clerk Dashboard. → verify: toggling the flag flips the gate on next launch/foreground.
6. **Validation / revocation mechanism.** Force-refresh the session at launch and on foreground (`getToken(forceRefresh:)` / `session.reload()`) — this round-trips to Clerk's token endpoint (server-side validation; refuses revoked sessions). Refresh failure → `locked`/`signedOut`. **Revocation takes effect at next launch or foreground refresh; a foregrounded session lags ≤ one refresh interval.** → verify: ban a test user in the Dashboard, confirm lockout on next foreground.
7. **Account lifecycle.** Sign-in via ClerkKitUI prebuilt flow exposing all enabled providers (email, phone, Google, Facebook, Apple); sign-out; **in-app account deletion** (Apple Guideline 5.1.1(v), required once account creation exists). → verify: delete-account flow removes the Clerk user.

### Sign-in providers & required native setup (user enabled email, phone, Google, Facebook, Apple)

- **Apple SSO** — add the **"Sign in with Apple" capability** in Xcode + provisioning; Clerk uses native `ASAuthorization`. **Must remain enabled while Google/Facebook are offered (Apple 4.8).**
- **Google / Facebook** — web OAuth via `ASWebAuthenticationSession`; requires the **redirect-URL allowlist** entry in Clerk (`com.aiarcheology…`, already added) + a **matching custom URL scheme in `Info.plist`**. Facebook additionally needs a Facebook Developer app configured in Clerk (and Facebook's own app review for production).
- **Phone/SMS** — sends real SMS; **check Clerk free-tier SMS limits/cost** (the one method with per-message charges).
- **App Review demo account** — must be **email/password** (reviewers cannot complete Google/Facebook OAuth).
- **UI tests** — never automate OAuth; rely on the `#if DEBUG` mock-auth path (step 9) + optionally one email-code E2E against a Clerk test instance.
8. **Offline behavior.** v1 **fails closed** offline ("Needs connection"). **⚠️ Acknowledged regression:** the app today runs on-device ML on cached content offline; gating removes that. Scoped to the gated TestFlight beta. **Refinement before any public/field use:** entitled-user offline grace (last-good validation in Keychain, bounded expiry). → verify: airplane-mode launch shows the offline screen; (refinement) entitled user within grace still enters.
9. **UI-test bypass.** Mock auth path **`#if DEBUG` only**, compiled out of release/TestFlight, selected by a launch argument, so existing UI tests keep running. → verify: `grep`/`nm` the archived (Release) build proves the mock path is absent; UI tests pass.
10. **App Store strategy.** Phase 1 ships via **TestFlight**. Public submission deferred until open signup + a maintained reviewer demo account (a live Clerk user with `access=true`, owner-rotated). → verify: TestFlight build installs and gates correctly.

## Phase 2 — Billing (months out)

`StoreKit 2 subscription → backend verifies App Store Server Notifications → writes Clerk entitlement metadata → app reads entitlement → unlock / paywall.` Use Clerk Billing/Stripe only for web/B2B/admin grants, never as the iOS consumer purchase path.

## Risks & accepted trade-offs

- **Foreground de-entitlement/ban lag** ≤ one session-refresh interval — accepted; caught at next launch/foreground refresh.
- **Offline = locked in v1** — accepted for the gated beta; offline-grace refinement required before public/field use.
- **iOS 18.0 floor drops iOS 17.x devices** — user-chosen, not auth-driven.
- **5.1.1 forced-login risk** — mitigated by TestFlight-first; revisit for public launch.

## Open question for the user

- **Users overview:** is the **Clerk Dashboard** (hosted user list/management) sufficient for v1, or do you want an **in-app admin/users surface**? The latter needs a backend/admin API and is currently scoped as a later phase.

## Provenance

- External facts validated via Codex (`/codex-cli:ask`): Clerk iOS SPM SDK & capabilities; Apple Guidelines 3.1.1 (IAP), 4.8 (Sign in with Apple), 5.1.1 (account requirement + reviewer demo); StoreKit-2-over-Clerk-Billing recommendation.
- Plan hardened via `/grill-yourself` (3 rounds → SHIP): closed the client-claim/server-validation gap, named the concrete refresh mechanism, removed the JWT-template dependency, flagged the offline regression, and `#if DEBUG`-gated the test bypass.
