# StoreKit Subscription Setup (AIA-0343)

Runbook for the iOS auto-renewable subscription. **No secrets in this file** — IDs and
config only. Apple credentials/2FA stay with the account owner.

## Product (App Store Connect — created 2026-06-23)

App: **ML Browser** (App Store Apple ID `6466878953`, team `8860a21d-…`).

| Field | Value |
|-|-|
| Subscription group | **AI Archeology Premium** (group ID `22180515`) |
| Reference name | Premium Monthly |
| **Product ID** | **`com.aiarcheology.premium.monthly`** ← must match `SubscriptionProduct.monthly` in code |
| Subscription Apple ID | `6783491808` |
| Duration | 1 month |
| Price | **$3.99 USD** (Apple auto-calculates all 175 storefronts; Apple is merchant of record) |
| Availability | All 175 countries/regions + auto-include future regions |
| Localization | English (U.S.) — "AI Archeology Premium" / "Premium detection models and features." |
| **Introductory offer** | **Free for the first month** — all regions, starts 2026-06-23, no end date |

The product reads as **"Missing Metadata"** in ASC until a review screenshot is added and it
is attached to an app version (below). That is expected.

## Pricing & trial decisions (rationale)

- **$3.99/mo, 1-month free trial.** Niche/prosumer tool → price for margin over a committed
  base, not volume. Start generous (1-month trial) while the model catalog is small to let
  value accrue and gather early-access feedback; revisit/shorten later.
- Revenue funds adding/improving detection models. Plan to **raise price as the catalog grows**,
  grandfathering early subscribers.
- (Research recommended $9.99 + 7-day on category medians; owner chose $3.99 + 1-month for the
  current value/audience. The app reads price/trial dynamically, so changing them is an ASC-only
  edit — no code change.)

## Gating model — WHOLE-APP subscription (no free/premium split)

The subscription gates the **entire app**, not a premium subset. "The app" is what's sold:
free to download → 1-month free trial → then $3.99/mo to keep using it.

- `SubscriptionGateView` sits **inside** the auth gate (`MLBrowser.swift`): once signed in, the
  app proper (`ContentView`) shows only while `subscriptionState.isSubscribed` (a free trial
  counts as active). Otherwise **`PaywallView` is the root**, mirroring the auth gate.
- The root paywall also offers **Sign Out + Delete Account** (Apple 5.1.1(v)) so a non-subscriber
  can leave/delete without reaching Settings.
- Bypassed entirely when `FeatureFlags.isPaymentsEnabled` is off (ships dark; existing flows
  unaffected until payments are turned on).
- **Naming:** dropped "Premium" — the product is just "AI Archeology" / full access (paywall
  title + `Configuration.storekit` updated). ⚠️ The App Store Connect **group + product display
  name still read "AI Archeology Premium"** — rename them in ASC (group `22180515`, product
  `6783491808`) to drop "Premium" for consistency.

## App side (branch `feature/AIA-0343/storekit-subscriptions`)

- StoreKit 2 DIY, **on-device entitlement** (`Transaction.currentEntitlements`, verified only) —
  **no backend, no Clerk writes** in Phase A.
- Paywall shows the trial terms (read from the product's intro offer), the auto-renewable
  disclosures + Terms of Use + Privacy Policy links (Apple 3.1.2), and an in-app **Apple refund
  sheet**.
- Behind the `FeatureFlags.isPaymentsEnabled` flag (in-source; ON in the submitted build).
- Local testing without ASC: Xcode → Scheme → Run → Options → StoreKit Configuration →
  `ios/MLBrowser/Configuration.storekit` (mirrors the product: $3.99, 1-month free trial).

## Remaining manual steps (owner)

1. **Verify** the intro offer saved (ASC → Subscriptions → Premium Monthly → Subscription Prices
   → Introductory Offers shows "Free for the first month"). The session timed out right after the
   final Confirm, so confirm it persisted.
2. **Review Information:** add a paywall **screenshot** + (optional) review notes; provide a Clerk
   demo account for App Review.
3. **Submit the subscription with the next app version** (it can't go live standalone — select it
   in the version's "In-App Purchases and Subscriptions" before submitting to review).
4. **Prerequisites to receive payouts:** Paid Apps agreement + banking + tax forms active; and a
   German **Gewerbeanmeldung** (sole-proprietor) sorted before launch (no company/GmbH required;
   Apple handles consumer VAT). Confirm specifics with a Steuerberater.

## Phase B (separate issue, only if needed)

If premium ever needs cross-device/web entitlement or server-side revocation: a backend (holds the
Clerk **secret** key) receives **App Store Server Notifications V2** → writes the entitlement to the
Clerk user (correlated via the `appAccountToken` the app already sets). Not needed for Phase A.
