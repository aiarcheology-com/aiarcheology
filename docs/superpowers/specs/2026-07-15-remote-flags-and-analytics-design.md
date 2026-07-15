# AIA-0350 — Remote feature flags (ConfigCat) + product analytics (TelemetryDeck)

**Status:** design, awaiting approval
**Date:** 2026-07-15
**Issue:** [#350](https://github.com/aiarcheology-com/aiarcheology/issues/350)
**Branch (phase 1):** `fix/AIA-0350/add-free-tier-backend-for-remote-feature-flags-product-analytics-dashboard`

## Problem

`FeatureFlags` is compile-time: flipping `isPaymentsEnabled` requires an App Store release, so there
is no kill-switch and no staged rollout. Separately, the app emits no product analytics, so DAU/MAU,
retention, and feature usage are unknown. Sentry covers crashes, not usage.

## Shipping in two phases

This work **splits into two PRs**. The flags half is self-contained and touches no privacy surface;
the analytics half needs a consent-adjacent flow and a privacy-policy rewrite, and must not delay
the kill-switch.

| Phase | Contents | Branch |
|-|-|-|
| **1 — Remote flags** | ConfigCat SDK, `FeatureFlags` migration, dashboard flag setup | this branch |
| **2 — Analytics** | TelemetryDeck SDK, notice flow, event set, privacy-policy HTML rewrite | new branch, new PR |

## Decisions

Settled with the maintainer before design:

| Decision | Choice |
|-|-|
| Vendors | TelemetryDeck (analytics) + ConfigCat (flags). No PostHog, no Firebase. |
| PR scope | All in-repo work. WordPress page 165 and the App Store privacy label are a separate by-hand ticket at release time. |
| Notice model | First-launch notice **before** the auth/subscription gates. "Share anonymous usage data", default **ON**, non-blocking. `TelemetryDeck.initialize` is called **only after** the notice is dismissed. Mirrored by a Settings toggle. |
| Legal posture | This is **notice + opt-out under legitimate interest**, *not* GDPR consent. It must never be labelled "consent" in code, copy, or policy. See Risks. |
| Events | Lifecycle/session, detection usage (aggregated per session), paywall funnel, model acquisition. |
| Performance/battery | **Out of scope.** TelemetryDeck is an event counter, not a profiler. Follow-up ticket: Sentry profiling + MetricKit + Xcode Organizer. |
| Flag bridge | Synchronous snapshot reads via the SDK's own snapshot API + compiled-in defaults. |
| Key handling | xcconfig + 1Password, following the Sentry DSN precedent. |

## Verified facts

Checked against live services and pinned source, not assumed. Items marked **(corrected)** fix an
error in an earlier draft of this document.

- **ConfigCat free plan**: 5 million config-JSON downloads and 20 GB traffic per month. The issue's
  "10 flags free" understated the real constraint. Current usage: zero.
- **ConfigCat state**: org `Aiarcheology` → `Aiarcheology's Product` → `Main Config`. Both
  `Test Environment` (`08dee1f8-a07f-4ed1-855d-aa0111147d1e`) and `Production Environment`
  (`08dee1f8-a087-4227-8358-d56ffddecbde`) exist. Only the sample flag `isMyFirstFeatureEnabled`
  is present. Each environment owns an auto-minted SDK key; nothing needs "generating".
- **TelemetryDeck state**: org `AI Archeology`, app `ML Browser`
  (`3861FC6A-D20E-454C-9912-A152F2E0685B`) already created. Free tier ingests in batches, so
  signals are not real-time.
- **SDKs** (both ship an Apple privacy manifest):
  - `configcat/swift-sdk` 11.3.1, product `ConfigCat`, iOS 12+.
  - `TelemetryDeck/SwiftSDK` 2.14.1, product `TelemetryDeck` (not the legacy `TelemetryClient`
    product), iOS 12+.
- **TelemetryDeck test mode**: `testMode` defaults to `true` under `#if DEBUG`, `false` otherwise.
  Testing signals appear only with the dashboard's Test Mode toggle on. Previews send nothing
  (`XCODE_RUNNING_FOR_PREVIEWS`). We can therefore verify from a simulator without shipping.
- **TelemetryDeck initialization is not inert (critical)**: `TelemetryManager.init`
  (`TelemetryClient.swift:406-411`) calls `startSessionAndObserveAppForegrounding()`, which emits
  `TelemetryDeck.Session.started` (`:81`, gated by `sendNewSessionBeganSignal`, `:73`) **and**
  registers `willEnterForeground` observers that re-fire on every resume. A gate inside a wrapper's
  `send(_:)` cannot intercept any of this. **The only reliable gate is to not call `initialize`.**
- **Signals are pseudonymous, not anonymous (corrected)**: `SignalManager.swift:178` sends
  `clientUser: sha256(customUserID ?? defaultUserIdentifier, salt)`, where the default identifier is
  `identifierForVendor` (`:396`), plus `sessionID` and default device/OS/locale/build parameters on
  every signal. An earlier draft claimed payloads carry "only bucketed integers and categorical
  enums" — that was true of our custom payload and false of the transmitted signal. A stable
  pseudonymous ID is personal data under GDPR; pseudonymisation is not anonymisation.
- **Gate nesting** (`MLBrowser.swift:60-67`): `AuthGateView { SubscriptionGateView { ContentView } }`.
  Settings lives inside `ContentView`, so a signed-out or unsubscribed user **cannot reach a
  Settings toggle**. Any notice or opt-out placed after these gates is unreachable for exactly the
  users who have consented to nothing.
- **Shipped privacy policy contradicts this work** (`privacypolicy.html:73`): the app currently
  promises **"no advertising or analytics SDKs"**. Phase 2 cannot ship without rewriting this.
- **Call sites (corrected)**: `FeatureFlags` has **8** executable reads — 7 production, 1 test — not
  the 9 an earlier draft claimed (two grep hits were a filename and a doc comment):

  | Site | Note |
  |-|-|
  | `SubscriptionGateView.swift:26`, `:36` | sits **above** `ContentView`; cannot read an `AppState`-owned value implicitly — needs explicit injection |
  | `SettingsView.swift:282`, `:298` | currently observes only `SubscriptionState` |
  | `ModelImportView.swift:195` | presented via a sheet (`DrawerContent.swift:74`) — environment objects need **re-injection on the sheet** (AGENTS.md §3) |
  | `Appstate.swift:133` | evaluated once during init; a later flip to on starts no StoreKit work |
  | `SubscriptionState.swift:99` | needs injected flag state |
  | `SubscriptionStateTests.swift:95` | test seam must change |

### Build-configuration mapping

| Build | ConfigCat environment | TelemetryDeck |
|-|-|-|
| Debug / simulator | Test (`CONFIGCAT_SDK_KEY`) | test-mode signals (SDK default) |
| Release / TestFlight / App Store | Production (`CONFIGCAT_SDK_KEY_LIVE`) | live signals |
| SwiftUI previews | static provider, no network | nothing sent (SDK default) |
| UI tests | static provider, no network | never initialized |

---

# Phase 1 — Remote feature flags

## Architecture

```
FeatureFlagKey (enum, String raw)     ← rawValue IS the ConfigCat key
        ├── defaultValue              ← FeatureFlags.swift, the "safe local defaults"
        │
ConfigCatFeatureFlagAdapter (private, non-@MainActor, does I/O)
        │
FeatureFlagsState (@MainActor, ObservableObject, no SwiftUI import)
        └── snapshot: FeatureFlagSnapshot   (immutable value type)
        │
DependencyContainer  →  injected explicitly into AppState AND SubscriptionGateView
```

- `FeatureFlagKey.rawValue` is a declared literal, not a reflected symbol name — release-build
  symbol stripping cannot silently break lookup.
- **`FeatureFlagSnapshot` is a struct**, not an observable class: an observable type without an
  approved suffix trips `testObservableObjectsHaveDescriptiveSuffixes`
  (`ArchitectureTests.swift:266`).
- **`FeatureFlagsState` is `@MainActor`** (`testStateObjectsAreMainActor`, `:198`) and must not
  import SwiftUI/UIKit (`testStateTypesAvoidSwiftUIImports_Aspirational`, `:574` — do not add it to
  the ratchet baseline).
- The **adapter is not exposed to views**. An earlier draft published a `FeatureFlagProviding`
  protocol to consumers; at the app boundary that is a fake abstraction — views need one typed
  snapshot, not a provider. The protocol survives only as a narrow internal seam for testing.
- **No custom cache.** Verified: `ConfigCatClient.snapshot()` (`ConfigCatClient.swift:361`) returns a
  snapshot whose `getValue` is synchronous (`ConfigCatClientSnapshot.swift:37`), and the SDK's
  default `UserDefaultsCache` (`ConfigCache.swift`) already persists config JSON under a
  `com.configcat-` prefix. A second app-owned cache would create two sources of truth that diverge
  across environment/key changes. One owner of freshness: the SDK.
- **Ready-state nuance.** The client's cache sync completes asynchronously, so a `snapshot()` taken
  at launch may return `defaultValue`. Safe by construction, and why `FeatureFlagsState` republishes
  when config lands.

## Flag application policy (per flag)

Not all flags may apply live. `SubscriptionGateView` is the app **root**: publishing a mid-session
flip to `isPaymentsEnabled` would replace a working app with a paywall while the user is mid-detection,
or release an unpaid user from it. These flags were written assuming compile-time stability.

| Flag | Default | Applies |
|-|-|-|
| `isModelCatalogEnabled` | `true` | **live** — it only shows/hides an entry point; a mid-session change is harmless |
| `isPaymentsEnabled` | `true` | **at launch only** — snapshot is read once at session start; a remote change takes effect on next launch |

## Error handling

Best-effort throughout; nothing blocks launch and no error reaches the user.

- Fetch failure / offline / missing flag / bad key → the SDK snapshot returns our `defaultValue`.
  Log via OSLog. Never throw.
- **Concurrency:** `DependencyContainer` is `@MainActor` (`DependencyContainer.swift:18`), so its
  lazy construction runs on main. The adapter's refresh must not capture the ConfigCat client in
  `Task.detached` without first compiling the pinned SDK under strict concurrency — the SDK carries
  no blanket Swift-6 Sendability guarantee. Verify before relying on it.

## Honest limits of the kill switch

Both defaults are `true`, so the switch **fails open**: on a fresh offline install, a bad SDK key, a
missing flag, or a ConfigCat outage, the "killed" feature stays **on**. This preserves today's
behaviour and avoids a fresh offline install showing a crippled app, but it means the kill switch
only reaches users whose client successfully fetches. Additionally, auto-poll only runs while the
process is alive — a suspended app does not poll in the background, so "~10 minutes" is a
foreground-only bound. Both limits are accepted, and stated here so nobody mistakes this for a
guaranteed remote kill.

## Dashboard setup (phase 1)

- Delete the sample `isMyFirstFeatureEnabled`.
- Create `isModelCatalogEnabled` and `isPaymentsEnabled` in **both** environments.
- Initial values: **open question for the maintainer** — `true` everywhere (preserve current
  behaviour) versus `isPaymentsEnabled = false` in Production (ship the paywall dark, flip it on
  deliberately). Not decided; see Open Questions.

## Testing (phase 1)

- **Unit**: each `FeatureFlagKey` resolves to `defaultValue` when the snapshot has no data
  (launch/offline path); snapshot→`FeatureFlagSnapshot` mapping; the static/fake provider's
  overrides win; `isPaymentsEnabled` does **not** change mid-session once captured.
- **Architecture**: adapter is not `@MainActor`; `FeatureFlagsState` is; no new app singleton
  (third-party SDK globals live outside the scanned source root and do not trip
  `testOnlyApprovedSharedSingletonsExist`, `:397`).
- **UI tests**: `UITestLaunchConfiguration` bumps v5→v6 with flag overrides; no network.
- **Update**: `SubscriptionStateTests.swift:95`.

---

# Phase 2 — Product analytics

## Notice flow (the critical correction)

```
first launch → Analytics notice (default ON, "Continue")
                     │  dismissed
                     ▼
        TelemetryDeck.initialize(...)      ← FIRST time the SDK exists at all
                     │
              AuthGateView → SubscriptionGateView → ContentView → Settings toggle
```

- The notice renders **before** the auth/subscription gates, so every user reaches it — unlike a
  Settings-only opt-out, which unsubscribed users can never see.
- `TelemetryDeck.initialize` is **never** called until the notice has been dismissed and the toggle
  is on. This is the only gate that actually works, because init itself emits a session signal and
  installs foreground observers.
- Turning the toggle off later stops further sending. The SDK offers no de-initialize, so the
  toggle's off path must be verified to produce **zero egress**, including lifecycle signals.
- Under UI tests the SDK is never initialized.

## Events

| Event | Payload | Why |
|-|-|-|
| session/lifecycle | none (SDK automatic) | DAU/MAU, retention |
| detection session summary | bucketed run count (1–5, 6–20, 20+) | core usage without a per-run firehose |
| paywall shown | none | funnel top |
| subscribe tapped | none | funnel intent billing data cannot see |
| model imported / downloaded | source category (enum) | catalog vs import usage |

Detection is aggregated **per session**, never per run: a per-run signal on a continuously-detecting
browser would exhaust the ~100k/month free tier alone.

## Privacy

Our custom payloads carry only bucketed integers and categorical enums — never URLs, page titles or
content, filenames, model names, or image data. The AGENTS.md §10 on-device invariant holds:
analytics observes *that* detection ran, never *what* it saw.

But the transmitted signal is **not anonymous** — see Verified facts. Every signal carries a
persistent `sha256(IDFV, salt)` client ID, a session ID, and device/OS/build metadata. The privacy
policy must say so plainly.

`privacypolicy.html` must be rewritten in this phase: the current "**no advertising or analytics
SDKs**" claim (`:73`) becomes false the moment this ships. Required disclosures: the processor
(TelemetryDeck GmbH), what is collected, the pseudonymous identifier, the legal basis, and how to
opt out.

## Testing (phase 2)

- Notice appears before the gates on first launch; dismissal persists.
- **Network-level test**: with the toggle off, zero requests reach TelemetryDeck — including
  lifecycle/session signals. This is the test that would have caught the original design's bug.
- Event→payload mapping asserts no PII fields in our custom payload.

---

## Out of scope

- Battery/performance attribution (follow-up: Sentry profiling, MetricKit, Xcode Organizer).
- WordPress privacy page 165 and the App Store privacy label (by-hand ticket at release).
- Subscription/billing analytics — RevenueCat, #349.
- ConfigCat user targeting, segments, percentage rollouts. Flags land as plain booleans; targeting
  is available later with no code change.

## Open questions

1. **Initial Production value for `isPaymentsEnabled`** — `true` (preserve behaviour) or `false`
   (ship dark, flip deliberately)? Maintainer's call; not decided.

## Risks

- **"Default ON" is not GDPR consent.** Under GDPR, pre-ticked boxes and inactivity are not valid
  consent. This design is therefore framed as *notice + opt-out under legitimate interest*, which is
  a defensible basis for pseudonymous product analytics — but it is a legal judgement, not a
  technical one, and it is weakened by the app's existing tracker-free positioning (AIA-0347) and
  its current explicit "no analytics SDKs" promise. **A lawyer should confirm before phase 2 ships.**
  If that basis is rejected, the fallback is explicit opt-in with default OFF, at the cost of a
  biased usage sample.
- **Kill switch fails open** (see Honest limits).
- **Stale-flag window**: remote flips apply on next poll, and for payments on next launch.
- **Free-tier ingestion lag**: TelemetryDeck batches processing, so an empty dashboard immediately
  after integration is not evidence of failure.
- **Swift-6 Sendability of the ConfigCat client** is unverified; confirm under strict concurrency
  before moving refresh work off the main actor.
