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

`SubscriptionGateView` → `AnalyticsChoiceGate` → `ContentView`
(`ios/MLBrowser/iOS/UI/MLBrowser.swift`).

**Entitlement is the gate; signing in is not** (AIA-0536, implementing the #543 decision). The auth
gate used to be outermost, so nothing — not even the paywall — was reachable while signed out. That
inverted: a sign-in wall in front of an app nobody has tried yet is both the larger 5.1.1(v) risk and
the worse ask. Sign-in is now a **sheet** (`SignInSheet`) offered from four places: the paywall, the
drawer, Settings, and once after a finding is saved.

`AuthState` is still driven, by `.authLifecycle()` applied above the gate — consent scoping, purchase
tagging and the account UI all need to know who is signed in. It just no longer decides whether the
app renders. Those four lifecycle pieces (`start()`, foreground re-validation, the real-auth-only
`ClerkSessionWatcher`, **and its Clerk environment injection**) must stay together: the watcher reads
the environment, so separating them leaves it mounted and inert with nothing failing to show it.

Analytics consent is innermost — asked after the paywall, of every entitled user, anonymous included.

Two modifiers sit *above* the gate: the screenshot problem-reporter and the app-message banner, so a
user on the paywall can still report a bug and still receive a message.

## State table

Axes: `isReady` × payments flag × entitlement × auth context. Auth no longer gates, so it appears
only where it changes what is *shown*, not whether anything is.

|#|isReady|Flag|Entitlement|Auth context|User sees|Correct?|
|-|-|-|-|-|-|-|
|1|false|any|any|any|`ProgressView`|yes, transient|
|2|true|off|unobservable|any|App content; Settings shows "Free Beta"|yes: ship-dark contract|
|3|true|on|subscribed (paid)|any|App content; Settings "Active"|yes — including signed out|
|4|true|on|subscribed (trial)|any|App content; Settings "Trial"|yes: a trial counts as active|
|5|true|on|not subscribed|validated|Paywall, with Sign Out / Delete Account|yes: Apple 5.1.1(v) escape|
|6|true|on|not subscribed|anonymous|Paywall, with **Sign In**|yes: a signed-out lapsed subscriber must reach account recovery without buying first|
|7|true|on|not subscribed|indeterminate / suspended|Paywall, no account controls|yes: the first is transient, the second cannot reach Clerk anyway|
|8|true|on|not yet synced|any|Paywall until StoreKit syncs or the user taps Restore|acceptable: Restore is the sanctioned recovery|
|9|true|on|subscribed|indeterminate (launch)|A brief hold until auth resolves a consent scope, then the app|acceptable: the same wait the old `AuthLoadingView` covered — but see the note below|
|10|true|on|subscribed|suspended (offline)|App content, analytics off|yes: no scope can ever be selected, so waiting would never end (#532)|

Row 9 note: with **both** analytics flags on, the first render of an entitled launch waits for a
consent scope, which means waiting for Clerk. Auth no longer decides *whether* the app renders, but
in this one configuration it still influences *when*. The wait is bounded by the same round-trip the
old auth gate made, and it is skipped entirely once a scope resolves (row 10 shows the case where it
never can).

Row 2 note: with the payments flag off, `subscriptionState.start()` never runs, so no
`Transaction.updates` listener is installed and `isSubscribed` stays frozen `false` for the whole
session. The app cannot observe real entitlement at all while shipped dark — and with no auth gate
either, a flag-off build is fully open.

## Transitions

|Trigger|Effect|
|-|-|
|Sign-in completes|Context → `.validated`. Access does not change — the user stays where they are. Analytics switches to that account's consent bucket, and if that account has never answered, the consent question is asked **as a sheet over the app**, never by replacing it. Later purchases carry its `appAccountToken`|
|Sign Out|Context → `.anonymous`. **The user stays in the app** (AIA-0536): entitlement is the gate, so signing out does not eject an entitled user. `SubscriptionState` is deliberately **not** reset either — the entitlement is device property, so clearing it would be a lie. Analytics switches to the anonymous consent bucket|
|Delete Account|Clerk user deleted → signedOut. **The Apple subscription keeps billing**|
|Refund / revocation|`Transaction.updates` → entitlement false → root swaps to the paywall live|
|Ask-to-Buy approval|Arrives via `Transaction.updates`, the launch drain, or the foreground re-check|
|Foreground|Auth re-validates online; entitlement re-checked so a lapse raises the paywall without a cold launch|
|Remote payments-flag flip|No effect until relaunch — captured once at construction (AIA-0350)|

## The consequences worth knowing

**1. A second Clerk account on one device inherits the first one's subscription.** Entitlement is
read from `Transaction.currentEntitlements` for the device's Apple Account; no Clerk id is consulted.
A subscribes, signs out, B signs in — B gets premium. This is the standard iOS model (the Apple
Account paid, and Apple would grant that purchase to any install under it), and it is accepted for
now. `StoreKitSubscriptionProvider` writes a Clerk-derived `appAccountToken` into purchases so a future
backend can reconcile; nothing reads it yet — and since AIA-0536 that token is written **only** from
a freshly validated context, never from a stale or unverifiable session.

Under paywall-first this consequence acquires a reporting counterpart: buying now happens before
signing in, often instead of it, so an account holding an entitlement no longer implies that account
bought it. An entitlement first observed with nobody signed in is marked **anonymous, persistently**,
and `subscription.activated` refuses to fire for it — otherwise every anonymous purchase followed by
a sign-in would be reported as that account's conversion. The honest report is nothing until a
backend can prove ownership.

**2. The same Clerk account on a device with a different Apple Account pays twice.** `Restore` calls
`AppStore.sync()`, which syncs the *device's* Apple Account, not the Clerk account — so it returns
"nothing to restore" and the same person is asked to buy again. This is not fixable on-device; it
needs the App Store Server Notifications → backend → Clerk-entitlement path.

**3. ~~Offline locks out paying subscribers.~~ Dissolved by AIA-0536.** Auth used to fail closed at
launch *and every foreground*, blocking a paying user who foregrounded in airplane mode out of an app
whose ML features are entirely on-device. Auth no longer gates, so an entitled offline user goes
straight in; the unverifiable session surfaces as `.suspended`, which pauses nothing and simply
declines to tag purchases or select a consent scope. Analytics fails closed; the app does not.
See #532, which this closes.

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
