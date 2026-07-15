# Product Analytics (TelemetryDeck)

> **Status: NOT IMPLEMENTED YET — this is the agreed design for AIA-0350 phase 2.**
> The app currently ships **no analytics SDK**, and
> [`privacypolicy.html`](./ios/MLBrowser/iOS/Documents/privacypolicy.html) correctly says
> so. Nothing described below is collected today. Treat this as the spec to build against,
> not a description of current behaviour.

Phase 1 (remote feature flags) shipped separately — see [`FEATUREFLAGS.md`](./FEATUREFLAGS.md).
Traps found while shipping phase 1, which mostly recur here: issue #350.

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
(`TelemetryClient.swift:406-411`, `:81`). A consent check inside a `send()` wrapper
**cannot** intercept that — it would leak a session signal before the user saw anything.

Therefore: **do not call `initialize` until the user has seen the notice and analytics is
on.** That is the only gate that actually works.

```
first launch → notice ("Share anonymous usage data", default ON, "Continue")
                     │ dismissed
                     ▼
        TelemetryDeck.initialize(...)     ← first time the SDK exists at all
                     │
        AuthGateView → SubscriptionGateView → ContentView → Settings toggle
```

The notice renders **before** the auth/subscription gates. That placement is not cosmetic:
`MLBrowser.swift:60-67` nests `AuthGateView { SubscriptionGateView { ContentView } }`, and
Settings lives inside `ContentView` — so a signed-out or unsubscribed user could **never
reach a Settings-only opt-out**, precisely the users who agreed to nothing.

## Planned events

| Event | Payload | Why |
|-|-|-|
| session / lifecycle | none (SDK automatic) | DAU/MAU, retention |
| detection session summary | bucketed run count (1–5, 6–20, 20+) | core feature usage |
| paywall shown | none | funnel top |
| subscribe tapped | none | purchase intent billing data can't see |
| model imported / downloaded | source category (enum) | catalog vs import usage |

Detection is aggregated **per session**, never per run — a per-run signal on a
continuously-detecting browser would exhaust the ~100k signals/month free tier by itself.

## Privacy: what is actually sent

Our own payloads carry only bucketed integers and categorical enums. **Never** sent: URLs,
page titles or content, filenames, model names, or image data of any kind. The AGENTS.md
§10 on-device invariant holds — analytics observes *that* detection ran, never *what* it saw.

But **the signal is not anonymous**, and the privacy policy must say so plainly. Every
signal carries (verified in `SignalManager.swift:178`, `:396`):

- `clientUser` — `sha256(identifierForVendor, salt)`: a **persistent pseudonymous ID**
- `sessionID`
- device model, OS version, app version/build, locale/region

Pseudonymisation is **not** anonymisation. A stable pseudonymous ID is personal data under
GDPR.

**Legal posture:** notice + opt-out under **legitimate interest** (Art. 6(1)(f)) — *not*
GDPR consent. Default-ON with a dismissable notice is **not valid consent** (pre-ticked
boxes and inactivity never are), so this must never be labelled "consent" in code, copy, or
policy. This is a legal judgement, weakened by the app's tracker-free positioning
(AIA-0347); **a lawyer should confirm before phase 2 ships.** If the basis is rejected, the
fallback is explicit opt-in, default OFF, at the cost of a biased usage sample.

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
- App ID `TELEMETRYDECK_APP_ID` in 1Password (`TelemetryDeck Keys`) → xcconfig →
  `MLBrowser-Info.plist`. It is a public identifier, not a secret; stored alongside the
  ConfigCat keys for consistency.
- Free tier ingests in **batches**, not real-time — an empty dashboard right after
  integration is *not* evidence of failure.

## Definition of done for phase 2

- [ ] `TelemetryDeck/SwiftSDK` 2.14.1 (product `TelemetryDeck`, not legacy `TelemetryClient`)
- [ ] Notice before the gates; `initialize` only after dismissal
- [ ] Settings toggle mirrors it (withdrawable)
- [ ] **Network-level test: toggle off ⇒ zero egress, including lifecycle signals.** This is
      the test that would have caught the original design's bug.
- [ ] `privacypolicy.html` rewritten — the current "no advertising or analytics SDKs" claim
      (`:73`) becomes false the moment this ships. Must land *with* the code.
- [ ] Verify TelemetryDeck's data-processing location for the §6 transfers section
      (a German GmbH does not by itself prove EU-only hosting)
- [ ] Separate by-hand ticket: WordPress privacy page 165 + App Store privacy label

## Related

- [`FEATUREFLAGS.md`](./FEATUREFLAGS.md) — remote feature flags (ConfigCat, shipped)
- [`ios/AGENTS.md`](./ios/AGENTS.md) §10 — security, privacy, secrets
