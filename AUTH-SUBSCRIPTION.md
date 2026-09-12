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

**Signing in is not the gate** (AIA-0536, implementing the #543 decision). The auth gate used to be
outermost, so nothing — not even the paywall — was reachable while signed out. That inverted: a
sign-in wall in front of an app nobody has tried yet is both the larger 5.1.1(v) risk and the worse
ask. Sign-in is now a **sheet** (`SignInSheet`) offered from four places: the paywall, the drawer,
Settings, and once after a finding is saved.

**Entitlement is not the only thing that opens it either** (AIA-0556). Access is

```
payments surface off  ||  StoreKit entitled  ||  app-managed free window open
```

evaluated in exactly that order by `RootGateDisplay.resolve(...)`, which is where the contract lives
rather than in the view. The order is the part that costs money if it regresses: entitlement is
answered **before** the window is consulted and does not consult it at all, so a user who subscribes
on day 13 of their free window is not walled on day 14 when it runs out underneath them.

The window is a **14-day app-managed free-access period** anchored at the first launch on which
payments are live, mirrored into the Keychain so delete-and-reinstall resumes it rather than
restarting it. `FeatureFlagKey.isFreeAccessPeriodEnabled` gates **granting** only — a window already
open is honoured to its natural expiry whatever the flag later reads — so turning the flag off stops
new windows without revoking days anybody was already promised. See `FreeAccessWindow`,
`FreeAccessAnchorService`, `FreeAccessState`.

**What that flag no longer does**, because AIA-0556 shipped promising the opposite and its
acceptance criterion 8 is now retired. Turning `isFreeAccessPeriodEnabled` off used to restore
develop's paywall exactly; since the screen was split (AIA-0567) the paywall's copy and its App
Review 3.1.2 disclosures are unconditional rather than gated on the flag, so switching it off stops
new grants and does nothing else. There is no dashboard revert for the subscription screen itself
— undoing that copy takes a build. The flag remains a live kill switch for *granting*, which is what
it is now for.

**What the anchor does and does not survive**, since the Keychain invites overconfidence. It outlives
app deletion, which is the whole point, and it travels in an encrypted backup or a device-to-device
transfer — so replacing a phone mid-window resumes it, and replacing one after the window is spent
does not hand out a second. It is *not* `…ThisDeviceOnly`, deliberately: that variant would make a
hardware upgrade a reliable way to farm another fortnight. It does not sync sideways to a second
device the user is holding, so a genuine second device gets its own window (out of scope, per the
ticket). And it does not survive a device wiped and set up as new, nor a restore from a backup taken
*before* the grant. Those are the accepted device-local limits; closing them needs an authority the
device does not have — see #557.

A grant stamped in the **future** is repaired rather than honoured. Dating the device forward before
the first launch would otherwise be permanent: the monotonic floor that stops a rollback rewinding a
window is exactly what would hold a forged one open until real time caught up. Reconciliation
re-anchors such a record to now, carrying its frozen duration across.

Two things follow that are easy to get wrong:

- **Expiry covers, it never replaces.** A window running out mid-session lays the paywall *over* the
  app rather than swapping the root, because swapping it destroys the `WKWebView` and with it the
  loaded page, the scroll position and the history.
- **An unreconciled anchor is not a refusal.** Until both anchor stores have answered, the gate
  renders neither side. Reading "no anchor yet" as "wall this user" would flash the paywall at every
  valid mid-window user on every launch, for as long as the Keychain took to reply.

`AuthState` is still driven, by `.authLifecycle()` applied above the gate — consent scoping, purchase
tagging and the account UI all need to know who is signed in. It just no longer decides whether the
app renders. Those four lifecycle pieces (`start()`, foreground re-validation, the real-auth-only
`ClerkSessionWatcher`, **and its Clerk environment injection**) must stay together: the watcher reads
the environment, so separating them leaves it mounted and inert with nothing failing to show it.

Analytics consent is innermost — asked after the subscription gate, of every user who reaches the
app, anonymous included. It is *deferred*, never skipped, while a window granted on this launch has
not yet been explained by its Welcome screen, and while the onboarding tour is still owed a turn: the
gate is nested inside `SubscriptionGateView` and replaces its content full-screen while consent is
`.ask`, so without the deferral "Enable analytics?" would be the first screen of a brand-new install,
or would land on top of the tour that Welcome's Continue just started. The intended first run is
**Welcome → tour → consent**.

Deciding to run the tour and actually running it are two steps, which is what makes that order hold.
`Appstate.initialize()` *arms* the tour before `isReady`; `SubscriptionGateView.startTourIfClear()`
starts what was armed, once nothing is owed the screen ahead of it. Arming from a view would arm
something nobody would act on — the gate's `onChange(initial: true)` handlers are what start the
tour, and nothing re-fires them later — and `AnalyticsChoiceGate` reads "armed **or** running", not
"running", so a launch that resumes over an unacknowledged Welcome screen holds the consent question
rather than flashing it full-width before the gate above has started anything.

Two modifiers sit *above* the gate: the screenshot problem-reporter and the app-message banner, so a
user on the paywall can still report a bug and still receive a message. The banner's surface resolver
takes the window state for this reason — a free-window user is unsubscribed but is sitting in the
app, not on the paywall, so `.paywall`-targeted messages must not fire at them as banners.

## State table

Axes: `isReady` × payments flag × entitlement × free-access window × auth context. Auth no longer
gates, so it appears only where it changes what is *shown*, not whether anything is; the window
column reads "any" wherever entitlement has already settled the answer.

|#|isReady|Flag|Entitlement|Free window|Auth context|User sees|Correct?|
|-|-|-|-|-|-|-|-|
|1|false|any|any|any|any|`ProgressView`|yes, transient|
|2|true|off|unobservable|never granted|any|App content; Settings shows "Free Beta"|yes: ship-dark contract, and no window is spent behind a gate that is not showing|
|3|true|on|subscribed (paid)|any, **expired included**|any|App content; Settings "Active"|yes: entitlement is answered before the window is consulted|
|4|true|on|subscribed (trial)|any|any|App content; Settings "Trial"|yes: a trial counts as active|
|5|true|on|not subscribed|unreconciled|any|`ProgressView`|defensive, and not reached as wired: `AppState.initialize` settles the anchor before `isReady`, so this branch exists only so a reordering cannot silently turn "not read yet" into a wall|
|6|true|on|not subscribed|open, day 0 unshown|any|App content, with the **Welcome screen** over it; Continue dismisses it and hands the screen to the onboarding tour|yes: the window is explained exactly once, and the marker is written when it is *shown*|
|7|true|on|not subscribed|open, nothing owed|any|App content|yes: this is the free period|
|8|true|on|not subscribed|expires mid-session|any|The paywall fades in **over** the app, which stays mounted|yes: a root swap would take the `WKWebView`, the page and the history with it|
|9|true|on|not subscribed|closed|validated|Paywall, with Sign Out / Delete Account|yes: Apple 5.1.1(v) escape|
|10|true|on|not subscribed|closed|anonymous|Paywall, with **Sign In**|yes: a signed-out lapsed subscriber must reach account recovery without buying first|
|11|true|on|not subscribed|closed|indeterminate / suspended|Paywall, no account controls|yes: the first is transient, the second cannot reach Clerk anyway|
|12|true|on|not yet synced|closed|any|Paywall until StoreKit syncs or the user taps Restore|acceptable: Restore is the sanctioned recovery|
|13|true|on|subscribed|any|indeterminate (launch)|A brief hold until auth resolves a consent scope, then the app|acceptable: the same wait the old `AuthLoadingView` covered — but see the note below|
|14|true|on|subscribed|any|suspended (offline)|App content, analytics off|yes: no scope can ever be selected, so waiting would never end (#532)|

Row 6 note: this screen is not the paywall (AIA-0567). `WelcomeView` states what the free window is
and offers one way in; it carries no Subscribe, no Restore and none of the 3.1.2 disclosures, because
it takes no money. The marker is written at *presentation* and is durable, so force-quitting over it
does not bring it back — the tour that was waiting behind it simply starts on the next launch.

Row 13 note: with **both** analytics flags on, the first render of an entitled launch waits for a
consent scope, which means waiting for Clerk. Auth no longer decides *whether* the app renders, but
in this one configuration it still influences *when*. The wait is bounded by the same round-trip the
old auth gate made, and it is skipped entirely once a scope resolves (row 14 shows the case where it
never can).

Rows 9–12 note: this is the **hard wall**, one of the paywall's two remaining presentations and the
only one that is a dead end — Settings, and with it the findings inventory, sits behind the gate
(the other is the Settings sheet, which is not). It therefore carries
export and delete affordances for whatever the user saved during the free period, and states when
billing begins for the subscription it is offering, including for a user who already spent Apple's
introductory offer and would be charged at once.

Row 2 note: with the payments flag off, `subscriptionState.start()` never runs, so no
`Transaction.updates` listener is installed and `isSubscribed` stays frozen `false` for the whole
session. The app cannot observe real entitlement at all while shipped dark — and with no auth gate
either, a flag-off build is fully open. No free window is granted in this state either: everyone
would look unentitled, so every install would run its 14 days down unseen and meet the wall the
instant payments were switched on. The clock starts at the first launch on which payments are live.

## Transitions

|Trigger|Effect|
|-|-|
|Sign-in completes|Context → `.validated`. Access does not change — the user stays where they are. Analytics switches to that account's consent bucket, and if that account has never answered, the consent question is asked **as a sheet over the app**, never by replacing it. Later purchases carry its `appAccountToken`|
|Sign Out|Context → `.anonymous`. **The user stays in the app** (AIA-0536): entitlement is the gate, so signing out does not eject an entitled user. `SubscriptionState` is deliberately **not** reset either — the entitlement is device property, so clearing it would be a lie. Analytics switches to the anonymous consent bucket|
|Delete Account|Clerk user deleted → signedOut. **The Apple subscription keeps billing**|
|Refund / revocation|`Transaction.updates` → entitlement false → the paywall is laid **over** the app if content has ever been shown this session, and is the root only on a launch that never got there (AIA-0556). It used to swap the root unconditionally|
|Ask-to-Buy approval|Arrives via `Transaction.updates`, the launch drain, or the foreground re-check|
|Foreground|Auth re-validates online; entitlement re-checked so a lapse raises the paywall without a cold launch. The free window is re-evaluated too, which is how one that ran out overnight is noticed|
|Free window granted|First launch with payments live and no entitlement. The Welcome screen is presented straight away, **ahead of** the onboarding tour: the tour is armed during `initialize()` and started by the gate only once nothing is owed the screen in front of it. The analytics consent question waits behind both|
|Subscribe tapped while the window is still open|An alert is raised first (AIA-0623): the window and Apple's introductory trial **do not stack** and the trial cannot be deferred, so subscribing on day 5 of 14 buys 19 free days where waiting buys 28. Hooked to the purchase, not to any presentation, so every route is covered by construction; keyed on the window alone, never on trial eligibility, because a user with no intro offer is charged *immediately* and so loses more, not less — eligibility picks only which sentence the alert shows. An `.alert` rather than a `.confirmationDialog`, which iPad renders as a popover with cancel-role actions omitted, and which `SettingsView` already found does not present from a sheet-hosted `Form` (AIA-0303). The remaining days come from the window's **phase**, not from a fresh count against `windowEndsOn` — `phase(at:)` counts from the monotonic floor, so an independent count would offer days the gate does not honour|
|Free window expires|A wake-up armed at the exact expiry instant fires, or the next foreground notices it: a `Date`-derived phase never recomputes itself, so without both halves a session left open across the last midnight is never walled. Access closes; entitlement is untouched|
|Subscribe from a paywall laid over the app|`isSubscribed` flips and the presentation is taken down **by the gate**, not by the screen: `@Environment(\.dismiss)` is inert inside an overlay. The Welcome screen comes down the same way — it has no Subscribe of its own, but an entitlement arriving from anywhere takes it|
|Restore Defaults|Clears preferences and the analytics consent buckets. Deliberately does **not** clear the free-access anchor, which would make it a repeatable way for a walled user to earn another 14 days|
|Remote payments-flag flip|No effect until relaunch — captured once at construction (AIA-0350)|
|Remote free-access-flag flip|No effect on an open window, ever, and none on this session at all — captured once at construction. It gates granting only|

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

**Decided 2026-08-12: accepted, by design, for as long as the app is iOS-only.** Entitlement stays
Apple-Account-scoped, which is the platform's own model and the one iOS users already hold ("my
purchases follow my Apple Account"). What was wrong was not the model but the app *implying a
different one*: an account-shaped UI over Apple-Account-shaped entitlement. So AIA-0525 fixed the
attribution rather than the architecture — `paywall.restoreEmpty.messageAppleAccount` now names
both scopes and warns, in the last screen before a second purchase, that buying there starts a
second subscription.

**Revisit trigger: the Android or web launch.** At that point every paying iOS user who installs the
second client is asked to pay again, systematically rather than as an edge case, and the backend has
to exist anyway. The cheapest moment to build it is while the subscriber base is still small —
`appAccountToken` is already written on every purchase, so purchases made now can be bound to
accounts retroactively. Nothing about accepting this today forecloses that.

**Support macro** (the canned reply; keep the tap paths *here*, not in shipped copy, so they can be
corrected without a release):

> Subscriptions on iPhone, iPad and Mac are bought from Apple, and they belong to the Apple Account
> that paid for them — not to your ML Browser account. If you subscribed on another device, that
> device is probably signed in to a different Apple Account.
>
> To check which one this device uses for purchases: **Settings → [your name] → Media & Purchases →
> View Account**. Sign in there with the Apple Account that paid, then open ML Browser and tap
> **Restore Purchases**.
>
> We cannot transfer a subscription between Apple Accounts — only Apple can see them. If you were
> charged twice, request a refund at reportaproblem.apple.com; Apple decides refunds and usually
> answers within about 48 hours.

Note the workaround is conditional, not permanent: `currentEntitlements` reads whichever Apple
Account is signed in *now*, so access follows that account and disappears again on switching back.
For someone deliberately keeping two Apple Accounts (work and personal) this is not a one-time
annoyance.

**3. ~~Offline locks out paying subscribers.~~ Dissolved by AIA-0536.** Auth used to fail closed at
launch *and every foreground*, blocking a paying user who foregrounded in airplane mode out of an app
whose ML features are entirely on-device. Auth no longer gates, so an entitled offline user goes
straight in; the unverifiable session surfaces as `.suspended`, which pauses nothing and simply
declines to tag purchases or select a consent scope. Analytics fails closed; the app does not.
See #532, which this closes.

**4. Deleting an account does not cancel the subscription.** Clerk deletion is offered where Apple
requires it, but the auto-renewing subscription continues billing. **The copy now says so**
(AIA-0528), on both surfaces and in the two different ways they allow:

- The paywall's own confirmation carries the warning in its message, plus a Manage Subscription
  link. Unconditional and hedged ("if you have a subscription") rather than gated on `isSubscribed`,
  which would have rendered it *never* — the root gate returns `.content` for anyone entitled and
  Settings only presents the paywall when they are not, so `isSubscribed` is false there in every
  reachable state.
- Settings gets a note under Manage Account, because Clerk's `UserProfileView` owns the delete
  confirmation there and its copy is not ours. That is also the only delete path a *subscribed* user
  can reach, which makes it the one that matters. Shown only while subscribed.

Consequence **1** above (a second Clerk account on one device inheriting the first's subscription)
is **accepted as-is, decided 2026-08-12**: it needs a genuinely shared device, and the on-device fix
— filtering `currentEntitlements` by the `appAccountToken` already written at purchase — sits in the
code path that decides whether anyone gets into the app at all. Denying access to someone who paid
is a worse failure than the leak. The same backend that closes #2 closes this properly.

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
