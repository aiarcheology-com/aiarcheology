# Product Analytics (TelemetryDeck)

> **Status: IMPLEMENTED IN THE CLIENT — policy, dashboard configuration, and release review
> remain required before shipping.** The app has a provider-neutral analytics API with a
> TelemetryDeck adapter pinned to SwiftSDK 2.14.1. TelemetryDeck is never initialized until the
> ConfigCat feature is available and the user actively enables analytics.

Remote feature flags shipped separately — see [`FEATUREFLAGS.md`](./FEATUREFLAGS.md).

## Why TelemetryDeck

We have no product analytics: DAU/MAU, retention, and feature usage are unknown, and we
can't tell which surfaces are worth investing in. TelemetryDeck was chosen over PostHog and
Firebase for the smallest data footprint and an Apple-native SDK. **Not** PostHog (overlaps
Sentry's error tracking), **not** Firebase (heaviest privacy footprint).

**What analytics is not:**
- **Sentry** = crashes and diagnostics (*things broke*). Kept; no overlap.
- **RevenueCat** (#349) = subscription/billing metrics. This covers general app usage only.
- **Battery/performance attribution.** TelemetryDeck is an event counter, **not a profiler**
  — it can say *that* detection ran, never which function drained the battery. That job
  belongs to Sentry profiling, MetricKit, and Xcode Organizer, in a separate ticket.

## The one rule that matters

**`TelemetryDeck.initialize` is not inert.** It emits `TelemetryDeck.Session.started` and
installs `willEnterForeground` observers the moment it is called
(`TelemetryClient.swift:406-411`, `:81`). An analytics-choice check inside a `send()` wrapper
**cannot** intercept that — it would leak a session signal before the user saw anything.

Therefore: **do not call `initialize` until ConfigCat's `isAnalyticsEnabled` is on, the user
has seen the notice, and the user has enabled analytics.** That is the only gate that actually
works.

```text
first launch → ConfigCat availability ON
    → AuthGateView → SubscriptionGateView
    → notice (default OFF: "Enable analytics" / "Not now")
    → active choice to enable → TelemetryDeck.initialize(...)   ← first time the SDK exists
    → ContentView → Settings toggle
```

**The notice renders *after* the auth and subscription gates** (AIA-0447): the demanding question no
longer fronts the app. Funnel events fired on the paywall are buffered in memory by `AnalyticsState`
until the choice is made, then flushed on enable and discarded on decline — so nothing leaves the
device before consent. `MLBrowser.swift` nests
`AuthGateView { SubscriptionGateView { AnalyticsChoiceGate { ContentView } } }`.

### Consequence: the acquisition funnel is degenerate

Because consent is the innermost gate, **only users who already signed in and already got past the
paywall are ever asked**. A user who abandons at sign-in, or sees the price and leaves, never enters
the dataset. So "opened → signed in → signed in + paid" is the same population at every stage and
all three counts are equal, by construction.

This is a gate-order consequence, not a reporting bug. **Do not build a conversion dashboard on
these stages** — the drop-offs you would want to read are structurally invisible. `subscription
activated` is therefore useful as conversion *timing* (when did this account first become entitled),
not as a conversion *rate*. Making the funnel real would mean moving consent above the paywall,
which is a partial reversal of AIA-0447 and belongs in its own ticket.

## Planned events

| Event | Payload | Why |
|-|-|-|
| session / lifecycle | none (SDK automatic) | DAU/MAU, retention |
| detection session summary | bucketed run count (1–5, 6–20, 20+) | core feature usage |
| paywall shown | none | funnel top |
| subscribe tapped | none | purchase intent billing data can't see |
| account signed in | none | funnel stage; fired once per account, not per launch |
| subscription activated | none | conversion **timing**, not rate — see the degeneracy note above. Fired on the first observation that an account holds an active entitlement, deduplicated per account. A paywall tap structurally cannot trigger it |
| model imported / downloaded | source category (enum) | catalog vs import usage |

Detection is aggregated **per session**, never per run — a per-run signal on a
continuously-detecting browser would exhaust the ~100k signals/month free tier by itself.

## Privacy: what is actually sent

Our own payloads carry only bucketed integers and categorical enums. **Never** sent: URLs,
page titles or content, filenames, model names, or image data of any kind. The AGENTS.md
§10 on-device invariant holds — analytics observes *that* detection ran, never *what* it saw.

But **the signal is not anonymous**, and the privacy policy must say so plainly. Every
signal carries (verified in `SignalManager.swift:178`, `:396`):

- `clientUser` — a **persistent pseudonymous ID**. See below: what gets hashed depends on whether a
  Clerk account identity is installed.
- `sessionID`
- device model, OS version, app version/build, locale/region

### The `clientUser` identity (AIA-0437)

`clientUser` is `CryptoHashing.sha256(string:salt:)` over one of two values
(`SignalManager.swift:178`):

|Signed-in and consented|Hashed value|Effect|
|-|-|-|
|no|`identifierForVendor`|per-device. The same person on iPhone and iPad counts as two users|
|yes|the Clerk account id|per-account. One person is one user across all their devices|

The Clerk id is the raw value handed to the SDK, which hashes it **before transmission** — the raw
identifier never leaves the device, never appears in a signal parameter, and must never be logged
(`LoggingPolicy.info`/`warning`/`error` are Sentry breadcrumbs, so a log line would also breach the
ticket's "no linking analytics to Sentry" scope line). A Harmonize rule enforces the allowlist of
files permitted to touch it.

**Correction to a previous version of this document:** it stated the hash was
`sha256(identifierForVendor, salt)`. The app passes **no salt** — `TelemetryDeck.Config(appID:)`
leaves `salt` at `""`, so the hash is unsalted. Adding one is deliberately *not* done here: the
salt must be identical on every device or the same account would hash differently per build and
break the cross-device matching this feature exists to create. Tracked as its own ticket, together
with the one-time dashboard identity discontinuity that changing it would cause.

Identity is applied only while **both** the ConfigCat `isAnalyticsEnabled` switch and the user's own
choice are on, and consent is scoped **per Clerk account** — a different account signing in on the
same device is asked for itself and fails closed until it answers. On sign-out the identity is
cleared back to `identifierForVendor`, and the session is rotated on an account change so two
accounts are never joinable through a shared `sessionID`.

Pseudonymisation is **not** anonymisation. A stable pseudonymous ID is personal data under
GDPR.

**Product posture:** analytics is an explicit, default-off user choice. It must never be
labelled as an opt-in in code, copy, or policy. **A lawyer should confirm the final policy and
legal basis before shipping.**

## Build-time behaviour

| Build | `testMode` | Where signals land |
|-|-|-|
| Debug / simulator | `true` (SDK default under `#if DEBUG`) | visible only with the dashboard's **Test Mode** toggle on |
| Release / TestFlight / App Store | `false` | live dashboard |
| SwiftUI previews | — | **nothing sent** (SDK detects `XCODE_RUNNING_FOR_PREVIEWS`) |
| UI tests | — | SDK never initialized |

Analytics therefore works in debug — signals are just quarantined — which is what lets us
verify the integration from a simulator without shipping.

## Configuration

- Dashboard: org `AI Archeology`, app `ML Browser` (already created).
- ConfigCat: create `isAnalyticsEnabled`, set it ON to make the user choice available. It is a
  live master switch and its compiled fallback is ON. Turning it OFF hides the prompt and
  Settings control and deactivates the provider, while retaining a user's prior choice.
- App ID `TELEMETRYDECK_APP_ID` in 1Password (`TelemetryDeck Keys`) → xcconfig →
  `MLBrowser-Info.plist`. It is a public identifier, not a secret; stored alongside the
  ConfigCat keys for consistency.
- Free tier ingests in **batches**, not real-time — an empty dashboard right after
  integration is *not* evidence of failure.

## Definition of done for phase 2

- [x] `TelemetryDeck/SwiftSDK` 2.14.1 (product `TelemetryDeck`, not legacy `TelemetryClient`)
- [x] Provider-neutral app API; TelemetryDeck is a replaceable adapter
- [x] `isAnalyticsEnabled` ConfigCat master switch (live, default ON)
- [x] Notice before the gates; `initialize` only after active enablement
- [x] Settings toggle mirrors it (withdrawable while the feature is available)
- [ ] **Network-level test: toggle off ⇒ zero egress, including lifecycle signals.** Pair it
      with the on-case — a zero-egress assertion passes trivially if signals never send.
- [ ] `privacypolicy.html` rewritten — the current "no advertising or analytics SDKs" claim
      (`:73`) becomes false the moment this ships. Must land *with* the code.
- [ ] Verify TelemetryDeck's data-processing location for the §6 transfers section
      (a German GmbH does not by itself prove EU-only hosting)
- [ ] Separate by-hand ticket: WordPress privacy page 165 + App Store privacy label

## Related

- [`FEATUREFLAGS.md`](./FEATUREFLAGS.md) — remote feature flags (ConfigCat, shipped)
- [`ios/AGENTS.md`](./ios/AGENTS.md) §10 — security, privacy, secrets
