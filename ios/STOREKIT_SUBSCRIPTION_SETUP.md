# StoreKit Subscription Setup (AIA-0343)

Runbook for the iOS auto-renewable subscription. **No secrets in this file** — IDs and
config only. Apple credentials/2FA stay with the account owner.

The live submission checklist is **#544**, not this file. This file records what the product *is*
and how the app treats it; #544 records what still has to happen before the first submission.

## Product (App Store Connect — created 2026-06-23)

App: **ML Browser** (App Store Apple ID `6466878953`, team `8860a21d-…`).

| Field | Value |
|-|-|
| Subscription group | **ML Browser** (group ID `22180515`) |
| Reference name | ML Browser Monthly |
| **Product ID** | **`com.aiarcheology.premium.monthly`** ← must match `SubscriptionProduct.monthly` in code |
| Subscription Apple ID | `6783491808` |
| Duration | 1 month (the recurring period — not the trial; see below) |
| Price | **$3.99 USD** (Apple auto-calculates all 175 storefronts; Apple is merchant of record) |
| Availability | All 175 countries/regions + auto-include future regions |
| Localization | English (U.S.) — display name "ML Browser" / "Full access to ML Browser." |
| Group localization | English (U.S.) — "ML Browser" (added 2026-08-05; the 2026-06-23 rename was the *internal* reference name only) |
| **Introductory offer** | **2 weeks free** (`FREE_TRIAL` / `TWO_WEEKS`) — all 175 territories, started 2026-08-04, no end date |
| Review information | Paywall screenshot + review notes uploaded; screenshot re-captured after AIA-0559 and **shows "$3.99 / month"** (verified 2026-08-12) |

The product reads as **"Missing Metadata"** in ASC until it is attached to an app version. That is
expected and is the last remaining gate — the screenshot and review notes it used to be waiting on
are uploaded.

> **Two things to check about the review screenshot before each submission** (AIA-0458 — both found
> by reading the uploaded asset as *evidence* rather than as a picture):
>
> 1. **No overlay artifacts.** The 2026-08-12 capture carried a browser file-picker widget
>    ("No file chosen") sitting across the *"Cancel anytime in your Apple Account settings."* line —
>    an artifact of the page it was captured from. An artifact covering a disclosure line is the one
>    kind of blemish that costs a review cycle.
> 2. **The description line must match ASC.** A screenshot captured against
>    `ios/MLBrowser/Configuration.storekit` shows *that file's* product text, not App Store
>    Connect's. The reviewer notes assert the local config "mirrors this product", so that claim has
>    to be true — see the localization row above.
>
> The **yellow wrench** on Subscribe no longer needs explaining away in a production capture: since
> AIA-0458 the badge is gated on `AppEnvironment.showsUnderConstructionBadge`, which names the
> non-production channels positively rather than inferring them, so an unidentifiable channel is
> treated as production. It still appears in Simulator, Debug and TestFlight captures.

> **Republish the privacy policy if it changed.** If
> `ios/MLBrowser/iOS/Documents/privacypolicy.html` has changed since the last submission, paste it
> into the hosted page at <https://aiarcheology.com/privacy-policy/> before submitting —
> ```sh
> RE='Last updated: [A-Za-z]+ [0-9]{1,2}, [0-9]{4}'
> diff <(grep -ohE "$RE" ios/MLBrowser/iOS/Documents/privacypolicy.html | head -1) \
>      <(curl -sL https://aiarcheology.com/privacy-policy/ | grep -ohE "$RE" | head -1) \
>   && echo "in sync"
> ```
>
> Runnable as written, and verified both ways: it prints `in sync` when the dates agree and a
> diff when they do not. It compares the documents themselves rather than asking git what
> changed, which is the actual question — and it does not depend on release tags, of which
> this repository has none.
>
> The date is a proxy for the body, so it only holds if every edit bumps it. If you ever change
> the policy text without moving the date, this check will pass while the documents differ.
>
> The two copies are **both binding and read by different audiences**: App Review reads the hosted
> URL from App Store Connect, users read the bundled one in-app. Nothing in the repo or CI compares
> them, so drift is silent.
>
> It has already happened once. `[AIA-0454] Harden support log consent` and `AIA-0437` correctly
> updated the bundled copy in the same commits that changed what the app collects; the hosted page
> was never updated, and by 2026-08-13 it was eleven days behind and still promised *"We do not log
> the websites you visit"* — a claim the support log can contradict when a user enables
> *Send unredacted data*. The stronger, wrong claim was on the page App Review reads.
>
> That is the pattern to expect: this file changes precisely when data handling changes, which is
> exactly when the public page must move too.

## Two free periods, and they are not the same thing

This is the single easiest thing to get wrong about this product, because the app now offers a free
period that Apple knows nothing about:

1. **The app-managed free-access window — 14 days (AIA-0556).** Granted by the app on first launch,
   anchored in the Keychain, no Apple account and no payment method involved. It is not a StoreKit
   concept and does not exist in App Store Connect.
2. **The StoreKit introductory offer — 2 weeks free.** Apple's trial, consumed per Apple Account
   when the user actually subscribes.

They stack **only for an Apple Account that has not already used the group's introductory offer**.
A first-time user gets 14 days of the app and then, on subscribing, the 2-week trial before the
first charge — 28 days total. Someone who trialled this subscription before (on any install) is
charged the moment they subscribe, and the paywall says so: it checks `introOfferEligibility` and
swaps the trial line for `paywall.billing.immediate`.

They stack only for someone who **waits**. The intro offer starts the moment the subscription does
and cannot be deferred, so converting on day 5 of the window yields 19 free days, not 28 — the
remaining 9 are simply lost. AIA-0623 stopped that happening silently: tapping Subscribe while a
window is still open raises an alert first, keyed on the window rather than on trial
eligibility (a user with no intro offer is charged immediately, so they lose more). Eligibility
picks only the *wording* — `paywall.keepFreeAccess.messageWithTrial` says the trial starts when the
purchase completes, `…messageNoTrial` says billing does — never whether the alert appears. Both are
anchored to the purchase completing rather than to "now", for the reason `billingNote(for:)` gives:
Ask-to-Buy and pending approvals can land days later, and `.pending` is reachable from this button.

The copy now spells this out too (AIA-0562/0576, corrected by AIA-0623): the Settings account
footer states the trial **only after StoreKit confirms this Apple Account still gets it**, with the
length derived from the product (`SettingsForm.subscriptionFootnote`); every other reader —
returning user, offer withdrawn, StoreKit still resolving — gets the date-only sentence
(`settings.subscription.freeAccessFootnoteNoTrial`).

That with-trial sentence is `settings.subscription.freeAccessFootnoteWithTrial`. It replaced
`settings.subscription.freeAccessFootnote`, which said subscribing starts "an **extra** free trial"
— true relative to the moment of subscribing, but read directly under "Free until &lt;date&gt;" it
implied the two periods add up. A new key rather than an edited one, per AGENTS §8: editing the
English in place would have left the other 16 locales holding a fluent translation of the old
meaning, which no gate can detect.

## Pricing & trial decisions (rationale)

- **$3.99/mo.** Niche/prosumer tool → price for margin over a committed base, not volume.
- Revenue funds adding/improving detection models. Plan to **raise price as the catalog grows**,
  grandfathering early subscribers.
- (Research recommended $9.99 + 7-day on category medians; the owner chose $3.99. The intro offer
  started as 1 month and was shortened to **2 weeks on 2026-08-04**, once the app itself began
  giving away the first 14 days.)
- **Changing the trial length is an ASC edit plus one local mirror.** Two sources of truth
  remain:
  1. App Store Connect (the actual offer),
  2. `ios/MLBrowser/Configuration.storekit` (`introductoryOffer.subscriptionPeriod`, local testing only).
  All three user-facing statements of the length — the purchase button, the paywall's trial line
  and the Settings free-access footnote — are derived from the product and need no edit (AIA-0576).

## Gating model — WHOLE-APP subscription (no free/premium split)

The subscription gates the **entire app**, not a premium subset. "The app" is what's sold: free to
download → 14 days of app-managed free access → 2-week StoreKit trial on subscribing → then
$3.99/mo to keep using it.

- **The subscription gate is the root** (`MLBrowser.swift:231`). The chain is
  `SubscriptionGateView` → `AnalyticsChoiceGate` → `ContentView`. The app proper shows while the
  user is entitled (a StoreKit free trial counts) **or** while the app-managed free-access window
  is open; otherwise `PaywallView` is what they meet. Day 0 of an open window is `WelcomeView`, a
  separate informational screen with no purchase control — `PaywallView` is only ever the screen
  that asks for money (AIA-0567).
- **Signing in is not a gate** (AIA-0536, implementing the #543 decision). Auth used to be the
  outermost gate — it no longer decides whether the app renders. `AuthState` is still driven, for
  analytics consent scope, purchase tagging and the account UI. Sign-in is offered contextually
  (`SignInSheet`) from the paywall, the drawer, Settings, and after a finding is saved.
- The paywall offers **Sign Out / Delete Account** when signed in and **Sign In** when anonymous
  (Apple 5.1.1(v)), plus an export/delete route for findings saved during the free window — so a
  non-subscriber can leave, delete, or take their data without reaching Settings.
- Bypassed entirely when the `isPaymentsEnabled` flag is off — read in the view as
  `subscriptionState.isPaymentsSurfaceEnabled`. Since AIA-0350 this is a **remote** ConfigCat flag
  (compiled default ON), captured **once at launch**: the gate is the app root, so a mid-session
  flip must not drop a paywall on someone mid-detection.
- **Naming:** the user-facing product is **"ML Browser"** (the app name; "AI Archeology" is the
  project/org). In ASC the group and the subscription display name are both "ML Browser"; the
  internal reference name stays "ML Browser Monthly" (it is never shown to a user); the
  paywall title and `Configuration.storekit` match. Product ID stays
  `com.aiarcheology.premium.monthly` (permanent identifier — can't change).

## App side

- StoreKit 2 DIY, **on-device entitlement** (`Transaction.currentEntitlements`, verified only) —
  **no backend, no Clerk writes** in Phase A.
- The paywall carries every element Apple 3.1.2 wants on a sign-up screen — unconditionally since
  AIA-0567; no feature flag removes any of them — and all of the
  product-specific ones are **derived from the product** so ASC stays the source of truth: the
  subscription name and its description, the **price with its recurring period** ("$3.99 / month",
  AIA-0559), the trial terms when *this* Apple Account is still eligible, the auto-renewable
  disclosure boilerplate, and Terms of Use + Privacy Policy links.
- **There is no in-app refund entry point** (AIA-0455 — this *is* now a fact, not a proposal). Both
  shapes are gone: the Settings row behind `isRefundRequestEnabled`, and the paywall button, which
  had in any case been unreachable since it was gated on `isSubscribed` while `RootGateDisplay`
  returns `.content` for anyone entitled. Apple mandates none, and the sheet could not be made to
  work on iOS-on-Mac. A granted refund still drops the gate — it arrives as a revocation, which is
  a different code path entirely. See `ios/MLBrowser/README.md` → Refunds.
- Behind the `isPaymentsEnabled` flag (remote via ConfigCat since AIA-0350; compiled default ON,
  and ON in the submitted build). See FEATUREFLAGS.md.
- Local testing without ASC: Xcode → Scheme → Run → Options → StoreKit Configuration →
  `ios/MLBrowser/Configuration.storekit` (mirrors the product: $3.99 / P1M, 2-week free trial).
  That file configures **nothing** in production — it ships in the bundle but nothing reads it
  outside local testing, so its contents prove nothing about ASC.
- `SKTestSession` is non-functional on iOS 26.5 (AIA-0518), so none of the above is covered by an
  automated end-to-end purchase test. Purchase paths are verified by hand.

## Remaining manual steps (owner)

Tracked in **#544** — summarised here so this file does not go stale again:

1. **Submit the subscription with the next app version** (it can't go live standalone — select it
   in the version's "In-App Purchases and Subscriptions" before submitting to review).
2. **Demo account for App Review** (#452) — still required under Guideline 2.1 because the app
   *includes* a login, even though sign-in gates nothing.
3. **Prerequisites to receive payouts:** Paid Apps agreement + banking + tax forms active; and a
   German **Gewerbeanmeldung** (sole-proprietor) sorted before launch (no company/GmbH required;
   Apple handles consumer VAT). Confirm specifics with a Steuerberater.
4. **Family Sharing** decision (#534) — irreversible once enabled; the shipped config says `false`.

## Phase B (separate issue, only if needed)

If premium ever needs cross-device/web entitlement or server-side revocation: a backend (holds the
Clerk **secret** key) receives **App Store Server Notifications V2** → writes the entitlement to the
Clerk user (correlated via the `appAccountToken` the app already sets). Not needed for Phase A.
