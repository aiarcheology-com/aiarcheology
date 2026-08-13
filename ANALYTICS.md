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
    → SubscriptionGateView (Welcome on day 0; the paywall once the window is spent)
    → onboarding tour
    → notice (default OFF: "Enable analytics" / "Not now")
    → active choice to enable → TelemetryDeck.initialize(...)   ← first time the SDK exists
    → ContentView → Settings toggle
```

**The notice renders *after* the subscription gate** (AIA-0447), of every user who reaches the app
— anonymous included (AIA-0536), and since AIA-0556 unentitled too, because a free-access window
opens the gate without a purchase. Funnel events fired before the choice are buffered in memory by
`AnalyticsState` until it is made, then flushed on enable and discarded on decline, so nothing leaves
the device before consent. `MLBrowser.swift` nests
`SubscriptionGateView { AnalyticsChoiceGate { ContentView } }`.

That buffer now carries more than it used to. The question is **deferred** while a window granted on
this launch has not yet been explained by its Welcome screen, and while the onboarding tour is still
owed a turn — otherwise "Enable analytics?" is the first screen of a brand-new install, or it lands
on top of the tour that Welcome's Continue just started — so a first run buffers the grant,
`welcome.shown`, the Continue that hands the screen over, and however the tour ends, all before
anyone has answered.

The bound of 16 is unchanged; the reason it holds is not, and that is worth stating because the old
reason was written down here. It used to be "the consent gate takes the screen the moment the
deferral lifts, so nothing can accumulate behind it". A tour abandoned mid-step — backgrounded, never
finished or skipped — breaks that: the user is inside the app, using it, with the buffer still open,
and `model.imported` and `detection.session_summary` both fire from in there. So payload-free events
are now collapsed to one occurrence on append, which caps the funnel stages at one entry each, and
overflow evicts the newest *volume* event rather than either end of the buffer. Neither naive policy
works: dropping the oldest evicts `free_access.window_granted`, the denominator every later stage is
read against, and dropping the newest admits nothing once full — which bites hardest at a cold hard
wall, the one surface that mounts no consent gate at all, where it would throw away the
`subscribe.tapped` that converted.

### Consent is scoped, and there are exactly two scopes

`AnalyticsConsentScope` is `anonymous | account`. **Anonymous and the pre-AIA-0437 device-wide model
are the same bucket, not two** — device-wide mode never installs an identity, and anonymous mode
installs `nil`, which per `AnalyticsTracking` means the transport's own anonymous installation
identity. Identical bytes, identical question. Storing them apart would only create two ways to
answer one question, and a way for each to overwrite the other.

|bucket|keys|
|-|-|
|anonymous / device-wide|`analyticsChoiceMade`, `analyticsEnabled`|
|account|`analyticsConsentAccountHash`, `analyticsAccountEnabled`|

Each branch writes only its own keys. That separation is what makes a rollback of
`isCrossDeviceAnalyticsIdentityEnabled` harmless rather than a leak.

The pre-consent buffer and the detection counter are **scope-owned**: both are discarded when the
selected scope genuinely changes, so one scope's activity can never be delivered under another's.
Two rules there are easy to get backwards and are pinned by tests — the *first* scope selection of a
session is never a boundary (events recorded before any scope existed cannot belong to another
scope), and the detection count is *spent* under the outgoing scope rather than discarded, which
makes the summary one-per-scope-stint rather than one-per-session.

### Consequence: the acquisition funnel is still not a rate

Consent now sits behind the paywall only, not behind sign-in as well, so the population asked is
"everyone entitled" rather than "everyone entitled *and* signed in". That is wider than before but
still not the top of a funnel: a user who sees the price and leaves is never asked, so pre-purchase
drop-off remains structurally invisible.

**Do not build a conversion dashboard on these stages.** `subscription.activated` is useful as
conversion *timing* for an account, never as a conversion *rate*.

Two further limits under paywall-first:

- **Anonymous users emit neither *account* funnel event.** `account.signed_in` and
  `subscription.activated` are both once-per-account and require one, so an entitled user who never
  signs in contributes to neither. They do still emit everything else once they consent — the
  buffered paywall events, model imports, detection summaries — so this is a gap in the funnel
  stages specifically, not in analytics as a whole.
- **An anonymous purchase is never credited to a later sign-in.** An entitlement first observed with
  nobody signed in is marked anonymous *persistently*, and `subscription.activated` refuses to fire
  for it — otherwise buying-then-signing-in, which is now the normal shape, would be reported as that
  account's conversion. See `AUTH-SUBSCRIPTION.md`.

## Planned events

| Event | Payload | Why |
|-|-|-|
| session / lifecycle | none (SDK automatic) | DAU/MAU, retention |
| detection session summary | bucketed run count (1–5, 6–20, 20+) | core feature usage |
| paywall shown | none | funnel top, for the screen that asks for money — see the discontinuity note below |
| subscribe tapped | none | purchase intent billing data can't see |
| account signed in | none | funnel stage; fired once per account, not per launch |
| subscription activated | none | conversion **timing**, not rate — see the degeneracy note above. Fired on the first observation that an account holds an active entitlement, deduplicated per account. A paywall tap structurally cannot trigger it |
| model imported / downloaded | source category (enum) | catalog vs import usage |
| free access: window granted | none | top of the free-period funnel. Once per install by construction — a window can only be granted where no anchor exists — and reported only for a grant whose durable write landed |
| welcome shown | none | the day-0 screen went up. Emitted where the once-per-window marker is written, so it cannot out-number the screen. This is the stage `paywall.shown` used to carry — see the discontinuity note below |
| free access: continue tapped | none | declined to subscribe *for now*. Fired from the button alone, because the same dismissal path also runs when the user buys from that screen or the tour takes it back |
| onboarding: tour completed | none | first-run onboarding reached its last step. The tour now sits between the Welcome screen and the consent question, so its drop-off is the first-run metric |
| onboarding: tour skipped | none | the same stage, taken by the Skip button. Counted apart because "left early" and "saw all of it" are different answers |
| free access: window expired | none | the free period ran out without a purchase. Deduplicated **durably and per device** (`analyticsFreeAccessExpiryReported`): expiry is a fact re-observed on every later launch, not an act, so an unguarded report would be a launch counter |
| free access: forfeit confirm shown | none | a purchase was about to forfeit an open window and the confirmation was raised (AIA-0623). It counts the *raise*, because nothing can observe whether SwiftUI actually presented the alert — and this is the one confirmation in the app no automated test can drive, since the Subscribe button needs a real StoreKit `Product` the UI-test mock cannot supply. **Read the raise-without-answer gap as a prompt to look, not as a verdict** — see the caveat below |
| free access: keep days tapped | none | the user read that confirmation and kept their remaining free days: the difference between backing out of *our* alert and cancelling Apple's sheet, which is the cost measurement for inserting a confirmation in front of a purchase. Bounded above by `forfeit_confirm_shown`, which is bounded above by `subscribe.tapped` |

**The forfeit-confirmation pair has one known blind spot.** A user who chooses Subscribe Anyway and
then cancels Apple's own sheet leaves a raise with nothing after it, exactly as a confirmation that
failed to present would. So `forfeit_confirm_shown` ≫ `keep_days_tapped` is consistent both with an
alert that never appeared and with ordinary StoreKit cancellations; go and look before concluding
anything.

It used to have a second, larger one, and the reason it does not is worth recording. The
confirmation is an **`.alert`**, not a `.confirmationDialog`: an action sheet presents as a popover
on iPad and the system omits cancel-role actions from popovers, so "Keep My Free Days" would not
have been rendered for iPad users at all — they would have kept their days by tapping outside,
firing no action, and this count would have been structurally short by a whole device family. An
alert renders both actions everywhere, so the only remaining way to leave without answering is to
leave the app.

The free-access stages carry no dates and no day counts. The window's numbers are a per-install
timestamp; a funnel needs the stage, not the calendar.

**`com.aiarcheology.paywall.shown` changed meaning in AIA-0567 without changing its name.** It used
to fire for the day-0 screen as well as the wall; day 0 is now `WelcomeView`, which is deliberately
**not** a purchase screen and does not emit it — putting it there would count a screen that offers
nothing to buy as an impression of the offer. So the event loses roughly its entire day-0 population
while keeping its identifier, and any series spanning the release reads as a collapse that never
happened. `welcome.shown` carries that population instead. Break the series at the release, or
compare `paywall.shown + welcome.shown` against the old figure.

**`tour_completed + tour_skipped` does not reconcile against `free_access.continue_tapped` in
either direction**, and neither gap is event loss.

It can fall *short*: a tour ends by being finished or by being skipped, and a user who force-quits
mid-step does neither — the abandoned run emits nothing and the tour re-arms. Read that as
abandonment.

It can also *exceed*, which is the less obvious half. `welcome.shown` is written when the screen is
raised, but `continue_tapped` only when the button is pressed, so a force-quit while the Welcome
screen is on display leaves a durable marker and no tap. The next launch suppresses the Welcome
screen, starts the armed tour anyway, and reports a terminal event — a tour stage with no Continue
before it. The hard-wall-then-restore path produces the same orphan. Both are correct behaviour, so
do not treat `tour_completed > continue_tapped` as instrumentation drift.

Both tour events describe **first runs only**. Settings → Replay terminates through the same methods
and is deliberately excluded — counting replays would let the stage out-number
`free_access.window_granted`, which is once per window by construction, and a funnel stage that can
exceed its own denominator is not a stage.

And the whole first-run funnel — grant, welcome, Continue, tour ending — happens **before the
consent question is asked**. All of it is buffered, and a buffer is flushed only if the user then
enables analytics and discarded if they decline. These numbers therefore describe consenting users,
not installs, and cannot be read as a first-run rate for the population as a whole.

`window_expired` says nothing about what happens next. A subscription bought at that wall gets
whatever provenance the entitlement observer assigns it, and with nobody signed in that is
**anonymous** and stays anonymous — a free period ending is not evidence of who owns the purchase
that followed it.

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
