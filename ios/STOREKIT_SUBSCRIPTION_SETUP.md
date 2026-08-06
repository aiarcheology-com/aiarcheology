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
| Review information | Paywall screenshot + review notes uploaded 2026-08-05 — **the screenshot is stale, see below** |

The product reads as **"Missing Metadata"** in ASC until it is attached to an app version. That is
expected and is the last remaining gate — the screenshot and review notes it used to be waiting on
are uploaded.

> **The uploaded review screenshot predates AIA-0559 and shows a bare "$3.99" with no period.**
> It is the 3.1.2 evidence App Review reads for this subscription, so it must be re-captured from a
> build containing AIA-0559 and re-uploaded *before* the subscription is attached to a version.
> Submitting a fixed binary behind that screenshot re-presents the defect the fix removes.

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

The runbook spells this out because the copy does not. `settings.subscription.freeAccessFootnote`
promises the extra 2-week trial **unconditionally**, which is wrong for a returning user — tracked
with the rest of the free-period wording in #562.

## Pricing & trial decisions (rationale)

- **$3.99/mo.** Niche/prosumer tool → price for margin over a committed base, not volume.
- Revenue funds adding/improving detection models. Plan to **raise price as the catalog grows**,
  grandfathering early subscribers.
- (Research recommended $9.99 + 7-day on category medians; the owner chose $3.99. The intro offer
  started as 1 month and was shortened to **2 weeks on 2026-08-04**, once the app itself began
  giving away the first 14 days.)
- **Changing the trial length is no longer an ASC-only edit.** It now has three sources of truth
  that must move together, or the app lies to the user:
  1. App Store Connect (the actual offer),
  2. `ios/MLBrowser/Configuration.storekit` (`introductoryOffer.subscriptionPeriod`, local testing only),
  3. `settings.subscription.freeAccessFootnote` in `Localizable.xcstrings`, which **hardcodes**
     "2-week".
  The paywall's own trial line is derived from the product and needs no edit.

## Gating model — WHOLE-APP subscription (no free/premium split)

The subscription gates the **entire app**, not a premium subset. "The app" is what's sold: free to
download → 14 days of app-managed free access → 2-week StoreKit trial on subscribing → then
$3.99/mo to keep using it.

- **The subscription gate is the root** (`MLBrowser.swift:231`). The chain is
  `SubscriptionGateView` → `AnalyticsChoiceGate` → `ContentView`. The app proper shows while the
  user is entitled (a StoreKit free trial counts) **or** while the app-managed free-access window
  is open; otherwise `PaywallView` is what they meet.
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
- The paywall carries every element Apple 3.1.2 wants on a sign-up screen, and all of the
  product-specific ones are **derived from the product** so ASC stays the source of truth: the
  subscription name and its description, the **price with its recurring period** ("$3.99 / month",
  AIA-0559), the trial terms when *this* Apple Account is still eligible, the auto-renewable
  disclosure boilerplate, and Terms of Use + Privacy Policy links.
- **The in-app refund sheet still ships**, in two different shapes, which is easy to misremember:
  on the paywall it is **ungated** for any active subscriber with a current transaction; in
  Settings it sits behind the remote `isRefundRequestEnabled` flag (AIA-0461). Apple does not
  *require* an in-app refund entry point — removing it has been discussed and never done — so
  treat "it was removed" as a proposal, not a fact, until the code says otherwise.
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
