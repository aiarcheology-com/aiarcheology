# AIA-0556 — manual test agenda

The 14-day free-access window in front of the paywall. Written for someone driving a real device or
simulator, not for CI.

## Before you start

**Time travel is how you reach day 7 and day 14.** iOS Settings → General → Date & Time → turn off
*Set Automatically*, then move the date forward. Moving it **forward** works normally. Moving it
**backwards will not give free time back** — that is the monotonic clamp working as designed, not a
bug. Turn *Set Automatically* back on when you finish.

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

## A. The happy path

| # | Do | Expect |
|-|-|-|
| A1 | Fresh install. Complete the onboarding tour. | Paywall appears **after** the tour, not before it. |
| A2 | Look at the paywall. | Green **Subscribe**, and below it a muted slate-blue **Continue** reading "14 days free". Also a line naming the date free access ends. |
| A3 | Tap **Continue**. | You land in the app. Everything works — detection, Find, Save, Share. |
| A4 | Answer the analytics question if it appears. | It must come **after** the paywall, never before the tour. |
| A5 | Force-quit and relaunch. Repeat a few times. | **No paywall at all.** Reappearing on every launch is the single most likely regression. |

## B. The reminder (day 7)

| # | Do | Expect |
|-|-|-|
| B1 | Move the date forward 7 days. Launch. | Paywall returns **once**, saying how many days are left. |
| B2 | Tap **Continue**. | Back in the app. Nothing extended — the end date has not moved. |
| B3 | Force-quit, relaunch, same day. | **No paywall.** It fires once, ever. |
| B4 | Move to day 9, 11, 13. Launch each time. | Still no paywall. |

## C. The wall (day 14)

| # | Do | Expect |
|-|-|-|
| C1 | Move the date past day 14. Launch. | Paywall, and **no Continue button**. No way into the app. |
| C2 | Read the trial copy. | If eligible: "free for 2 weeks", plus when billing begins. If your Apple ID already used the trial: it says so plainly instead of promising one you would not get. |
| C3 | Check the account controls are present. | Sign Out / Delete Account (or Sign In when signed out), Restore, Manage, Privacy Policy. |

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
| E2 | Check the days-remaining figure at the next reminder. | Counts from the original install, not the reinstall. |
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

## I. Flag off — must be develop exactly

Turn `isFreeAccessPeriodEnabled` **off** in ConfigCat and cold-launch **twice** (the flag is
launch-captured; the first launch still sees the old value).

| # | Do | Expect |
|-|-|-|
| I1 | Fresh install, flag off. | Hard paywall immediately. No Continue, no "14 days free", **no free-period copy of any kind**, including no billing-date line. |
| I2 | A user already mid-window when the flag goes off. | Their window is **honoured to its natural expiry**. The flag stops new grants; it does not revoke days already promised. |
| I3 | Settings → Subscription, flag off, not subscribed. | Unchanged from before this feature. |

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
3. The paywall appearing on every launch during the window (A5, B3).
4. Losing your loaded page when the window expires (G2).
5. No route to your own findings at the wall (D1).
6. Any free-period copy showing while the flag is off (I1).

## Known and expected — do not report

- Moving the clock backwards does not return free time (J1). By design.
- A ConfigCat flag change taking one extra cold launch to apply. AIA-0513, by design.
- The "under construction" badge on Subscribe in TestFlight builds. AIA-0354.
- *Erase All Content and Settings* yielding a fresh window. Accepted device-local limit, tracked in
  #557; a factory reset costs the user everything else on the device.
- A second physical device getting its own window. Cross-device sync is out of scope.
