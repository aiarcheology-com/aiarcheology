# AIA-0556 — manual test agenda

The 14-day free-access window in front of the paywall. Written for someone driving a real device or
simulator, not for CI.

## Before you start

**Time travel is how you reach day 14.** iOS Settings → General → Date & Time → turn off
*Set Automatically*, then move the date forward. Moving it **forward** works normally. Moving it
**backwards will not give free time back** — that is the monotonic clamp working as designed, not a
bug. Turn *Set Automatically* back on when you finish.

**Move time forward only, and reset before testing any purchase.** StoreKit validates against the
device clock, so winding the date *backwards* leaves the store in a state no real user reaches:
products stop loading, and because the Subscribe button only renders when a product exists, the
paywall appears to have no way to buy anything. That is the clock, not the app — it clears as soon
as *Set Automatically* is back on and the app is relaunched. Observed during testing and mistaken
for a broken Settings subscribe route, which is why it is written down here.

**The flag must be on.** `isFreeAccessPeriodEnabled` in ConfigCat, on for the environment you build
against. It defaults on, and it is captured once at launch, so a dashboard change lands **one cold
launch later** (AIA-0513). A first run that shows the old hard paywall is that lag, not a defect.

**Deleting the app is not a fresh install.** It clears UserDefaults but **not** the Keychain, and
the Keychain is the whole anti-farming mechanism. A genuinely clean slate needs the device contents
erased.

On a simulator:

```bash
xcrun simctl shutdown all
xcrun simctl erase all          # or: xcrun simctl erase "<device name>"
```

`erase` wipes contents *and* settings, keychain included. On a physical device the equivalent is
Settings → General → Transfer or Reset → *Erase All Content and Settings* — which is why the
factory-reset hole in section J is accepted rather than fixed: it costs the user everything else on
the device. Note this does **not** clear DerivedData, which is a separate cache and a separate
class of problem.

**Subscribe carries an "under construction" badge** in non-production builds (AIA-0354). Expected.
Purchases run against Apple's Sandbox and never charge real money.

---

## A. The happy path (first run)

Day 0 is the **Welcome screen**, not the paywall (AIA-0567). The order is Welcome → tour → analytics
question → app, and each of those steps waits for the one before it.

| # | Do | Expect |
|-|-|-|
| A1 | Fresh install. Launch. | The **Welcome screen** first, before the tour: "Welcome to ML Browser", "Explore everything free for 14 days", one **Continue** button, and a line naming what a subscription costs *after* the free access ends. |
| A2 | Look at what is *not* on it. | **No Subscribe, no Restore, no Terms/Privacy links, no renewal or billing disclosure.** That is the design — this screen takes no money. Report anything of the sort appearing here. |
| A3 | Tap **Continue**. | The onboarding tour starts, over the app. The Welcome screen does not come back. |
| A4 | Complete the tour, or Skip it. | Only then does the analytics question appear. It must never show over the tour, and never before the Welcome screen. |
| A5 | Answer it. | You land in the app. Everything works — detection, Find, Save, Share. |
| A6 | Force-quit and relaunch. Repeat a few times. | **No Welcome screen and no tour.** Reappearing on every launch is the single most likely regression. |

## B. Mid-window — nothing should interrupt

There is no day-7 reminder any more; it was removed with the split. A window that is open and already
explained owes the user nothing at all.

| # | Do | Expect |
|-|-|-|
| B1 | Move the date forward 7 days. Launch. | Straight into the app. **No screen of any kind** — no Welcome, no paywall, no reminder. One appearing is a regression, not a leftover feature. |
| B2 | Move to day 9, 11, 13. Launch each time. | Same: straight in, every time. |
| B3 | On day 0, force-quit *during* the tour, then relaunch. | The Welcome screen does not return — it was already shown, and that marker is durable. The tour runs again from its first step, and the analytics question still waits for it. |

## C. The wall (day 14)

| # | Do | Expect |
|-|-|-|
| C1 | Move the date past day 14. Launch. | Paywall, and **no Continue button**. No way into the app. |
| C2 | Read the trial copy. | If eligible: "free for 2 weeks", plus when billing begins. If your Apple ID already used the trial: it says so plainly instead of promising one you would not get. |
| C3 | Check the account controls are present. | Sign Out / Delete Account (or Sign In when signed out), Restore, Manage, Privacy Policy. |
| C4 | Read the subscription terms block. | Renewal disclosure plus Terms and Privacy links, always. They no longer depend on the free-access flag — see section I. |

## D. Data must not be trapped behind the wall

This is the Apple 5.1.1(v) / data-rights path. **Save at least one finding during the free period
before testing this.**

| # | Do | Expect |
|-|-|-|
| D1 | At the day-14 wall, look for **Export or Delete Findings**. | Present, because findings exist. |
| D2 | Tap it, choose **Export**. | Share sheet appears with a ZIP. Save it and confirm it opens. |
| D3 | Tap it again, choose **Delete**, confirm. | Findings gone; the button disappears. |
| D4 | With no findings saved, reach the wall. | The button is absent entirely. |

## E. Reinstall — the most important section

This is the property that makes the window non-farmable, and its only automated coverage is at the
unit level. **If anything here fails, report it before anything else in this agenda.**

| # | Do | Expect |
|-|-|-|
| E1 | Mid-window (say day 5), delete the app. Reinstall. Launch. | The window **resumes at day 5**. It must not restart at 14. |
| E2 | After that reinstall, watch the first launch. | **No Welcome screen.** The day-0 marker travels with the window, so a reinstall must not re-offer "14 days free" to someone with five days left. |
| E3 | At day 14+, delete and reinstall. Launch. | Straight to the wall. **No fresh 14 days.** |
| E4 | Settings → Reset → Restore Defaults, then relaunch. | Window unchanged. Restore Defaults must not hand out more free time. |

## F. Paying customers must never be walled

The money path. A failure here bills someone for a paywall.

| # | Do | Expect |
|-|-|-|
| F1 | On day 13, tap Subscribe and complete a Sandbox purchase. | You are in the app. |
| F2 | Move the date to day 14 and beyond. Launch. | **Still in the app.** The expired app window must not touch an active subscription. |
| F3 | Subscribe, then use the app across a midnight where the window would have expired. | No interruption. |
| F4 | Subscribe while inside the window. | All free-period messaging disappears. |

## G. Losing access mid-session must not destroy your page

| # | Do | Expect |
|-|-|-|
| G1 | On day 13, load a page and scroll well down it. Leave the app open past midnight into day 14. | The paywall appears **over** your page. |
| G2 | Look behind / dismiss-attempt. | The page is still loaded, at the same scroll position. It must not have reloaded or gone blank. |
| G3 | Background the app on day 13, return on day 15. | Walled — the window closes even though no timer fired while backgrounded. |

## H. Settings

| # | Do | Expect |
|-|-|-|
| H1 | During the window, Settings → Subscription. | Opens the paywall. (Before this change the row did nothing.) |
| H2 | Look at that sheet. | **No Continue button** — it is not a gate. No root-gate account controls. Dismiss with the sheet's own gesture. |
| H3 | While subscribed, Settings → Subscription. | The existing status submenu, unchanged. |

## I. Flag off — the kill switch for *granting*

Turn `isFreeAccessPeriodEnabled` **off** in ConfigCat and cold-launch **twice** (the flag is
launch-captured; the first launch still sees the old value).

**AIA-0556's acceptance criterion 8 is retired, and this section no longer tests it.** It asked that
turning the flag off restore develop's paywall exactly. Since the screen was split (AIA-0567) the
paywall's copy and its App Review disclosures read the same whatever the flag says, so the flag is
not a revert path for that screen — undoing its copy takes a build. What it still does, and all it
does, is stop new windows being granted.

**Read this before running section I, or you will report a bug that is not one.**

A brand-new install **always gets one window, even with the flag off in ConfigCat.** The flag is
captured once at launch from the previous session's mirror, and a fresh install has no mirror — so
it falls back to the compiled default, which is `true`. The first launch therefore predates any
possible sync. This is the accepted limit of the switch, decided deliberately: the flag governs the
existing install base, not new downloads. Erase the device, turn the flag off, launch, and you
**will** see the Welcome screen with Continue. That is correct.

So what is testable is the **grant**, at the level of the gate rather than of a fresh device:

| # | Do | Expect |
|-|-|-|
| I1 | An install that has **never been granted a window**, with the flag captured off — i.e. flag off in ConfigCat, then a **second** cold launch on a device where no window was ever opened. | Straight to the paywall. No Welcome screen, no Continue, no "14 days free", no billing-date line — and it must **not** say your free access has ended, because you never had any. |
| I2 | A user already mid-window when the flag goes off. | Their window is **honoured to its natural expiry**. The flag stops new grants; it does not revoke days already promised. |
| I3 | Settings → Subscription, flag off, not subscribed. | The same subscription screen, minus any free-access sentence. |
| I4 | Erase the device, flag off, first launch. | **Welcome screen with Continue — expected, not a bug.** See the note above. |

## J. Clock manipulation

| # | Do | Expect |
|-|-|-|
| J1 | Mid-window, move the date **backwards** a week. Launch. | You do **not** gain a week. The window continues as if you had not. |
| J2 | Before a truly fresh first launch, set the date years forward, launch (taking the grant), then restore the correct date. | You get a normal 14 days from the moment the clock was restored — **not** years of access. This was a real bug found in review; it is worth re-checking. |

## K. Promotional messages

| # | Do | Expect |
|-|-|-|
| K1 | Publish a paywall-targeted app message while a tester is mid-window. | It does **not** appear as a banner over the working app. |
| K2 | Publish an in-app message to the same tester. | It **does** appear. Mid-window users count as in-app, not as paywall viewers. |

---

## Report first, if you see any of these

1. A reinstall handing out a fresh 14 days (E1, E3).
2. A subscriber blocked from the app for any reason (F2).
3. The Welcome screen or the tour appearing on every launch (A6), or any screen interrupting an open
   window (B1).
4. Losing your loaded page when the window expires (G2).
5. No route to your own findings at the wall (D1).
6. A window granted while the flag is captured off, or "your free access has ended" shown to an
   install that never had one (I1).

## Known and expected — do not report

- Moving the clock backwards does not return free time (J1). By design.
- A ConfigCat flag change taking one extra cold launch to apply. AIA-0513, by design.
- The "under construction" badge on Subscribe in TestFlight builds. AIA-0354.
- *Erase All Content and Settings* yielding a fresh window. Accepted device-local limit, tracked in
  #557; a factory reset costs the user everything else on the device.
- A second physical device getting its own window. Cross-device sync is out of scope.
