# Authentication × Subscription

How Clerk auth and StoreKit entitlement interact, and why they are deliberately **not** the same
thing. Written for AIA-0437, which attaches a Clerk-derived identity to analytics and so has to
state exactly what that identity does and does not govern.

Related: `ANALYTICS.md` (what the identity is used for), `ios/AGENTS.md` §3 (feature flags),
`ARCHITECTURE.md` (composition root).

## The one sentence that explains every edge case

**Auth is Clerk-account-scoped and validated online; entitlement is Apple-Account-scoped and checked
on-device.** Everything surprising below follows from those two scopes diverging.

## Gate order

`AuthGateView` → `SubscriptionGateView` → `AnalyticsChoiceGate` → `ContentView`
(`ios/MLBrowser/iOS/UI/MLBrowser.swift`). Sign-in is outermost, so nothing subscription-related is
reachable while signed out. Analytics consent is innermost — asked only after both gates pass
(AIA-0447).

Two modifiers sit *above* all three: the screenshot problem-reporter and the app-message banner, so
a user stuck on the sign-in screen or the paywall can still report a bug and still receive a message.

## State table

Axes: `isReady` × auth gate (4 states) × payments flag × entitlement. Rows are collapsed only where
the code provably cannot distinguish them.

|#|isReady|Auth gate|Flag|Entitlement|User sees|Correct?|
|-|-|-|-|-|-|-|
|1|false|any|any|any|`ProgressView`|yes, transient|
|2|true|checkingSession|any|any|`AuthLoadingView`|yes, transient|
|3|true|signedOut|any|any|Sign-in screen — even with a valid entitlement|yes: auth outranks entitlement by design|
|4|true|offline|any|any|"Needs connection" + Retry — even with a valid entitlement|deliberate v1 fail-closed; see below|
|5|true|ready|off|unobservable|App content; Settings shows "Free Beta"|yes: ship-dark contract|
|6|true|ready|on|subscribed (paid)|App content; Settings "Active"|yes|
|7|true|ready|on|subscribed (trial)|App content; Settings "Trial"|yes: a trial counts as active|
|8|true|ready|on|not subscribed|Paywall as root, with Sign Out / Delete Account|yes: Apple 5.1.1(v) escape|
|9|true|ready|on|not yet synced|Paywall until StoreKit syncs or the user taps Restore|acceptable: Restore is the sanctioned recovery|

Row 5 note: with the payments flag off, `subscriptionState.start()` never runs, so no
`Transaction.updates` listener is installed and `isSubscribed` stays frozen `false` for the whole
session. The app cannot observe real entitlement at all while shipped dark.

## Transitions

|Trigger|Effect|
|-|-|
|Sign-in completes|Gate re-evaluates → ready → subscription gate decides|
|Sign Out (available on the root paywall)|Auth → signedOut. `SubscriptionState` is deliberately **not** reset — the entitlement is device property, so clearing it would be a lie|
|Delete Account|Clerk user deleted → signedOut. **The Apple subscription keeps billing**|
|Refund / revocation|`Transaction.updates` → entitlement false → root swaps to the paywall live|
|Ask-to-Buy approval|Arrives via `Transaction.updates`, the launch drain, or the foreground re-check|
|Foreground|Auth re-validates online; entitlement re-checked so a lapse raises the paywall without a cold launch|
|Remote payments-flag flip|No effect until relaunch — captured once at construction (AIA-0350)|

## The four consequences worth knowing

**1. A second Clerk account on one device inherits the first one's subscription.** Entitlement is
read from `Transaction.currentEntitlements` for the device's Apple Account; no Clerk id is consulted.
A subscribes, signs out, B signs in — B gets premium. This is the standard iOS model (the Apple
Account paid, and Apple would grant that purchase to any install under it), and it is accepted for
now. `StoreKitSubscriptionProvider` already writes a Clerk-derived `appAccountToken` into purchases
so a future backend can reconcile; nothing reads it yet.

**2. The same Clerk account on a device with a different Apple Account pays twice.** `Restore` calls
`AppStore.sync()`, which syncs the *device's* Apple Account, not the Clerk account — so it returns
"nothing to restore" and the same person is asked to buy again. This is not fixable on-device; it
needs the App Store Server Notifications → backend → Clerk-entitlement path.

**3. Offline locks out paying subscribers.** Auth fails closed at launch *and every foreground*,
while entitlement is checked purely locally. So a paying user who foregrounds the app in airplane
mode is blocked from an app whose ML features are entirely on-device. Deliberate for v1. If this is
ever relaxed, the subscription gate needs no change.

**4. Deleting an account does not cancel the subscription.** Clerk deletion is offered where Apple
requires it, but the auto-renewing subscription continues billing and the confirmation copy does not
say so.

**Family Sharing:** `refreshEntitlement` does not filter `Transaction.ownershipType`, so if Family
Sharing is enabled for the product in App Store Connect, a family member's entirely different Clerk
account is entitled. Consistent with the device model — but it is an unstated policy, not a decision.

## What the money path can and cannot be tested with

`SKTestSession` — Apple's StoreKit Testing framework, and the mechanism AIA-0376 and AIA-0518 both
assumed would cover purchase, refund and Ask-to-Buy — **does not work on iOS 26.5**. Measured, not
inferred:

|call|result|
|-|-|
|`SKTestSession(configurationFileNamed:)`|succeeds|
|`Product.products(for:)`|succeeds — returns the configured product|
|`session.disableDialogs = true`|reads back `false`; the setter is a no-op|
|`session.buyProduct(identifier:)`|throws `notEntitled`|
|`session.clearTransactions()`, `allTransactions()`|`SKInternalErrorDomain Code=3`|

Identical from `xcodebuild test`, from the Xcode IDE, and from a UI test that creates the session
*before* launching the app — so it is neither a CLI limitation nor the launch-ordering issue the
Apple forums describe. The split is clean: **configuration loading works, state control does not.**

Consequence: a real purchase cannot be driven from a test on this runtime. With dialogs impossible
to disable, `Product.purchase()` blocks forever on a sheet no unit test can tap.

What that harness would have covered is instead covered by seams, each one placed where a StoreKit
type stopped being constructible:

- `EntitlementResolver` — every condition that grants or withholds access, including revocation.
- `EntitlementTransaction` — the projection off a real transaction: what counts as a subscription,
  what counts as a trial, whether a refund is carried through.
- `entitlementSource` / `accountIdentifierSource` — the provider's published state and its
  `appAccountToken` tagging.

What remains uncovered, and why:

- **One line**: `Transaction.offerType`, the alias `offer?.type` that lets `Transaction` satisfy
  `EntitlementTransaction`. Everything it feeds is covered; reaching the alias itself needs a real
  transaction. Keep it a pure alias — logic added there is invisible to the suite (AIA-0530).
- **The drop of unverified results** in `currentEntitlementCandidates()`.
- **The StoreKit round-trip itself** — purchase, `AppStore.sync()`, `Transaction.updates` delivery.
- **Ask-to-Buy** and **`ownershipType` under Family Sharing**.

The projection *was* on this list. AIA-0530 removed it: `StoreKit.Transaction` cannot be
constructed (internal storage, no public initializer, not `Decodable`), but `Product.ProductType`
and `Transaction.OfferType` can be, so a protocol over the six fields the projection reads makes
every judgement in it testable — including whether a refund is carried through.

If this is ever revisited: the untried option is an older simulator runtime. Nothing here shows
whether the breakage is specific to iOS 26.5 or spans the whole 26 line.

### The coupling that made it untestable at all

Until AIA-0518, `StoreKitSubscriptionProvider.purchase()` read `Clerk.shared.user?.id` directly to
build the `appAccountToken`. `Clerk.shared` **traps** when Clerk was never configured — the state of
every test process — so any test reaching `purchase(_:)` died with a signal trap before StoreKit was
consulted. The account reader is now injected (`accountIdentifierSource`, defaulting to the same
Clerk read), and the derivation lives in `AppAccountToken`.

This is the auth×subscription entanglement this document exists to name: the two gates are
independent in the UI, but the *purchase* was not independent of the auth SDK.

## What the analytics identity does *not* change

AIA-0437 makes one Clerk account resolve to one analytics user across devices. It has no effect on
any of the four points above: entitlement still follows the Apple Account. A cross-device *analytics*
identity is not a cross-device *entitlement*, and the two must not be conflated when reading a
dashboard.
