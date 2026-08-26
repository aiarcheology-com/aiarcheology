# Release Check

What is still owed before a version can be submitted, per release.

**Scope:** the things a build alone cannot settle — App Store Connect metadata, human-eye checks, and
decisions. Engineering work lives in issues; this file is the gate in front of the submit button.

**How to use it:** work top-down. An item is ticked only when someone has *done the thing*, not when
the code looks right — see the note at the end of the 1.0.7 section for why that distinction earned
its own paragraph.

---

## Cloud findings — gates for the first release that ships it

Added 2026-08-26 with AIA-741. These are not 1.0.7 items; they gate whichever release first carries
account-backed sync (#713).

`FindingsCloudEndpoint.baseURL(for: .production)` now returns a real URL. Until the Worker behind it
is deployed, that address answers nothing — and the app will *show* the back-up button and fail,
where before it hid the button and stayed quiet. **A release cut before the deploy ships a visibly
broken feature.** That is the trade this file exists to catch.

- [ ] `wrangler deploy --env production` has run, and `wrangler deployments list --name
      aia-findings-production` shows it. (It did not exist on the account as of 2026-08-26.)
- [ ] `wrangler d1 migrations apply aia-findings-production --remote --env production` has run —
      the production database had **0 tables**.
- [ ] `CLERK_WEBHOOK_SECRET` is set for `--env production`. It is a **different** secret from the
      development one; signing secrets are per endpoint.
- [ ] The production Clerk instance has a `user.deleted` webhook pointing at the production Worker,
      and a signed delivery has been seen to return 2xx.
- [ ] **A development-instance token presented to the production Worker returns 401.** Every other
      check passes whether or not the issuer is enforced; only this one fails when it is not.
- [ ] The App Store privacy labels match the policy — findings and screenshots are collected once a
      user signs in and accepts. They currently declare the opposite (#731).
- [ ] A signed-in user can turn back-up off (#744), or the policy is amended to say they cannot.
- [ ] **The hosted privacy policy at <https://aiarcheology.com/privacy-policy/> matches the in-app
      copy.** That URL is what App Review and users read, and nothing publishes it automatically:
      run `python3 scripts/privacy_policy_hosted.py --check` to confirm the generated copies are in
      step with the app's, then paste `docs/privacy/privacy-policy-wordpress.html` into WordPress
      and read the live page. They drifted once already (#624), and this release is the one where
      the policy first has to disclose uploading coordinates and a real name.

## 1.0.7

**Build under test: 981** — uploaded to TestFlight 2026-08-13 from `release/1.0.7-2026-08-13`, cut
from `develop` at `53e3e419`. Carries #612, #616 and #618.

Verified green on that commit: harmonize exit 0 · 1855 unit tests, 0 failures · 89 UI tests,
1 skipped, 0 failures. The delivery lane re-ran the whole sweep before archiving, so it is green
twice.

### 1. Required before submission

| # | Item | Where | Ref |
|---|------|-------|-----|
| 1 | **Demo account for App Review** | ASC → App Review Information | #544, #452 |
| 2 | **IAP review screenshot** — capture without the sandbox badge (`.underConstructionBadge(isActive: false)` locally, or any production-channel build) | ASC → Subscription → Review Information | #544 |
| 3 | **Review notes describe the free-access window** — both presentations: the day-0 Welcome screen and the wall after 14 days | ASC → App Review Information | #544 |
| 4 | **Review notes give the right path to the paywall** — it is now **Settings → ML Browser → Subscription**. It moved out of the Account section in #618; notes written before that send a reviewer to the wrong place | ASC | #618 |
| 5 | **Subscription reaches _Ready to Submit_** | ASC | #544 |
| 6 | **Attach the subscription to the app version and submit together** — it cannot ship standalone | ASC | #544 |

Guideline 2.1 makes item 1 non-negotiable: the app *contains* a login, so a demo account is required
even though sign-in gates nothing.

### 2. Verify by eye on build 981

No automated run can settle these. That is the point of the list, not an apology for it.

| # | Item | Why it needs a human |
|---|------|----------------------|
| 7 | Paywall disclosures legible at an accessibility Dynamic Type size, **on iPhone and iPad**, nothing truncated | Layout under type scaling is invisible to XCUITest |
| 8 | **Privacy Policy** opens and renders — light *and* dark | It rendered blank until #618. See the note below |
| 9 | **Terms of Use** opens Apple's standard EULA | Schedule 2 §3.8(b) asks whether the link is *functional*, not whether it exists |
| 10 | Both legal links read as links, not grey captions | Contrast fix in #618: blue + underlined. System blue is ≈4.0:1, still marginally under WCAG AA at `.caption2` |
| 11 | **Dismiss** appears on the paywall opened from Settings, and is **absent** on the hard wall | The wall must stay a wall; mutation-tested, but worth seeing once |
| 12 | Three-button delete-account dialog does not scroll Cancel out of reach at large type / RTL | #618 added a third action |

### 3. Unconfirmed — check before trusting

| # | Item | How to settle |
|---|------|---------------|
| 13 | **ASC Privacy Policy URL** = `https://aiarcheology.com/privacy-policy/` | One read-only `GET /v1/appInfos/{id}/appInfoLocalizations`. #544 has it unticked, but #584 proves unticked ≠ undone |
| 14 | **License Agreement** = Apple's standard EULA — the custom-EULA field must be **empty**, matching what the app links | `GET /v1/apps/{id}/endUserLicenseAgreement` |

These are **App Store Connect metadata fields**, not the in-app links. The in-app links are items 8
and 9 and are a different requirement.

### 4. Decisions

| # | Item | State | Ref |
|---|------|-------|-----|
| 15 | **Family Sharing** — irreversible once enabled; shipped config says `false` | Deferred by the owner | #534 |

### 5. Not gates — recorded so they are not re-raised

| # | Item | Why it is not a gate |
|---|------|----------------------|
| 16 | **Gewerbeanmeldung** | Neither Apple nor App Review has any mechanism to ask. It is a tax/trade-law matter about *receiving the income*, downstream of shipping, and the owner has chosen to handle it later. Route it to a Steuerberater, not to this file |
| 17 | ConfigCat `isRefundRequestEnabled` | Deleted 2026-08-13. Note: testers on **older** builds will see the refund row reappear — those binaries still carry the flag and fall back to its compiled default `true`. Not a regression |
| 18 | **#584** Manage Subscription does nothing on Mac | Already fixed by `178b520a` (host guard + URL fallback) and shipping in 981. **The issue is still open and should be closed** |

### Closed during this pass

#455 (in-app refund removed) · #458 (3.1.2 disclosures) · #530 (cross-Apple-Account double charge,
closed **by-design** — the defect is real until a backend exists) · #533 (account deletion does not
stop billing) · #617 (paywall had no way out).

Deferred to after the release: #614 (name the production gate for behaviour, not provenance),
#615 (give the account a purpose — findings sync; design it together with server-side entitlement).

### Why item 8 has a paragraph of its own

Every box in #458 was ticked — including *"The Privacy Policy link is functional."* It was not. The
link opened a **blank sheet**, and had done since long before that issue was written.

It was ticked from reading the code: the link is present, wired to a sheet, pointing at a bundled
document. All true, and all irrelevant. The conversion worked (measured: 14 308 characters); the view
then replaced every attribute in the string with a SwiftUI `Color` stored under a UIKit key, so the
document was laid out and drawn in nothing.

**A UI test cannot see that.** XCUITest walks the accessibility tree, not pixels, so the text was
fully present to a test and absent to a human — confirmed by reverting the renderer and watching a
naive assertion pass.

That is the whole reason section 2 exists. An item there is ticked when a person has looked at it on
a device, and at no other time.
