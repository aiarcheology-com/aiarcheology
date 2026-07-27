# App Store rating prompt (AIA-0117)

How the native rating request is triggered, and how to test it by hand.

Apple's own sheet is the only UI — the app never draws a custom rating control (App Review
requires the system sheet). Implementation lives in
[`ios/MLBrowser/iOS/State/ReviewPrompt.swift`](ios/MLBrowser/iOS/State/ReviewPrompt.swift).

## When it fires

Two "winning moments" count. Each is **recorded** where it happens and the request is
**made** when the sheet hosting it closes — asking mid-dismissal would stack the system
sheet on one that is already animating away.

| Moment | Recorded in | Request made in |
|-|-|-|
| A finding is saved | `SaveFindingSheet.save()` | `WebScreen`'s sheet `onDismiss` |
| A model is imported **or** a non-CoreML model is converted | `DrawerContent` (`onImported`) | the import sheet's `onDismiss`, or the post-import type-review sheet's when one follows |

Both converge on `ReviewPromptCoordinator.consumePendingRequest(_:isTourActive:)`, which
returns whether the caller should invoke `@Environment(\.requestReview)`.

## The policy

A request needs **≥ 3 recorded moments** and **≥ 122 days since the last request**.

122 is `ceil(365 / 3)`. Apple caps the sheet at **three displays per user per 365 days** and
reports nothing back, so the app budgets its *requests* to the same ceiling — no request is
spent after Apple has silently stopped showing anything. (A 90-day interval would admit five.)

A per-app-version gate was deliberately **rejected**: a silently dropped request would burn
that version's only slot permanently, and TestFlight drops every one of them.

## Where it never appears

| Environment | Why |
|-|-|
| **TestFlight** | Apple does not display `requestReview` in TestFlight builds. The app also treats TestFlight-like distribution as suppressed, so a request is not *spent* against the cooldown for a prompt nobody can see. |
| Unit tests, UI tests, SwiftUI previews | A StoreKit sheet mid-suite is a flake generator. |
| During the onboarding tour | The user is following instructions, not admiring their own result. |
| Flag off | `isRatingPromptEnabled` — see [FEATUREFLAGS.md](FEATUREFLAGS.md). |

Suppression **mutates no state**: the count keeps accumulating and the cooldown does not
start, so a TestFlight tester promoted to the App Store build keeps their history.

## Persisted state

Two `UserDefaults` keys, owned by `Settings`:

| Key | Meaning |
|-|-|
| `ratingPromptEventCount` | Moments since the last request. Zeroed when a request is spent, and by `reset()`. |
| `ratingPromptLastRequestDate` | When the app last **asked**. Never when a prompt was *displayed* — StoreKit does not report that. |

**`reset()` ("Restore Defaults") deliberately keeps `ratingPromptLastRequestDate`.** That reset
is user-repeatable, so clearing the date would turn it into a lever to be asked again
immediately. Losing the count can only ever delay a prompt; losing the date could cause nagging.

---

# Manual test

## Before you start

- **Use a Debug build** (Simulator or a device). The prompt never appears in TestFlight.
- Debug builds read the ConfigCat **Test** environment. An explicit *Off* there kills the
  prompt; absent is fine (the compiled default is `true`).
- **Finish or skip the onboarding tour.** It auto-starts on first launch and suppresses the
  prompt — saves would count but never fire.

## ⚠️ Three traps when reading the state

All three produce the same symptom — values that look wrong or missing — for entirely
different reasons. Each one has cost someone a debugging detour.

### 1. `defaults` cannot see the app's preferences

`xcrun simctl spawn … defaults read/write` does **not** see a simulator app's sandboxed
preferences. It reports "does not exist" for keys that are plainly set, and writes land
somewhere the app never reads. Always go through the app container (below).

### 2. `booted` is ambiguous when more than one simulator is running

`booted` resolves to *a* booted device, not the one you are testing. With an iPhone and an
iPad both up you will silently read the wrong container. Pin the device instead:

```bash
# List what is actually booted, then pin the one running the app.
xcrun simctl list devices booted
SIM=8A7DB3D1-…            # ← the UDID from that list
PREFS="$(xcrun simctl get_app_container "$SIM" com.aiarcheology.ios data)/Library/Preferences/com.aiarcheology.ios.plist"

/usr/libexec/PlistBuddy -c "Print :ratingPromptEventCount" "$PREFS"
/usr/libexec/PlistBuddy -c "Print :ratingPromptLastRequestDate" "$PREFS"
```

Re-derive `$PREFS` every time — the container UUID changes whenever the app is reinstalled.

### 3. The values lag while the app is running

`UserDefaults` writes are batched by `cfprefsd`; they reach the plist when the app is
backgrounded or exits cleanly. **Press Home in the simulator before reading.** Xcode's Stop
button sends `SIGKILL`, which can discard writes that had not flushed yet.

An *absent* `ratingPromptEventCount` is normal on a fresh install: `register(defaults:)`
writes to the registration domain, not to disk, and `didSet` does not fire during `init`. The
key appears only once a moment is actually recorded.

## Run it

1. Build & Run the Debug scheme; sign in, pass the paywall, dismiss the tour.
2. Save a finding. Repeat until the count reaches 3 — check it with the `PlistBuddy` command above.
3. On the third save, **watch after the sheet closes**. The prompt fires on dismissal, not on
   the Save tap.

To shortcut, seed the counter with the app **stopped** (otherwise it overwrites your edit on exit):

```bash
xcrun simctl terminate "$SIM" com.aiarcheology.ios
/usr/libexec/PlistBuddy -c "Set :ratingPromptEventCount 2" "$PREFS"
```

Then relaunch and save one finding.

## What success looks like

```
ratingPromptEventCount      → 0
ratingPromptLastRequestDate → today
```

**This is the check that matters.** Count zeroed plus date stamped means
`consumePendingRequest` returned `true` and `requestReview()` was called — the app's entire
contract. Whether the sheet renders is Apple's decision and is not observable to the app.

**The dialog is non-functional outside the App Store.** In Simulator and development builds the
stars are not tappable and nothing submits, because there is no App Store transaction behind
the build. That is expected, not a bug. On iPad it renders as a centered alert rather than a
bottom sheet.

## Negative checks (worth doing — this is where the reviewed bugs were)

| Check | Expected |
|-|-|
| Cancel a finding capture (swipe the sheet away) | Nothing fires; the count does not change |
| Open and close an ordinary model's settings, no import pending | Nothing fires |
| **iPad multi-window:** with a save pending in window A, close a settings sheet in window B | Nothing fires in B — `AppState` is shared across windows, and a typed `ReviewPromptSource` stops one flow spending another's moment |
| Import a model that needs type confirmation | The prompt comes after the **settings** sheet closes, not the import sheet |

## To test again

You are in the 122-day cooldown after a successful prompt. Clear it with the app stopped:

```bash
xcrun simctl terminate "$SIM" com.aiarcheology.ios
/usr/libexec/PlistBuddy -c "Delete :ratingPromptLastRequestDate" "$PREFS"
/usr/libexec/PlistBuddy -c "Set :ratingPromptEventCount 2" "$PREFS"
```

Note that "Restore Defaults" in the app will **not** clear the date — that is by design.

## If the dialog does not appear

Read the two values first — but before concluding anything from them, rule out the two traps
that make a *working* feature look broken:

1. **Are you reading the simulator the app actually ran on?** With two simulators booted, a
   `booted`-derived path silently points at the other one.
2. **Was the app backgrounded before you read?** Values written since the last flush are not on
   disk yet.

Then:

- **They changed as expected** → the app did its job and StoreKit declined to render. A Debug
  build on a real device is the reliable visual check.
- **They did not change** → the cause is one of: the tour still active, an explicit *Off* in
  ConfigCat **Test**, the app was running when you seeded the counter, or a leftover
  `ratingPromptLastRequestDate` from an earlier run.
