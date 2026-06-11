# Browser URL bar live updates + navigation controls — AIA-0044 (with AIA-0277 architecture review)

*Status: IMPLEMENTED (commit a52e9fb) — consensus plan after 1 Codex review (9 findings) + 5 grill rounds (23 objections, 22 accepted, 1 rebutted as user-owned sequencing), plus the 2026-06-11 location-sheet user decisions. Implementation notes: the read-only address display dissolved the focused-TextField writer table (editing is sheet-local now); WebKit emits no reliable KVO for canGoBack/canGoForward on same-document navigations, so BrowserState re-reads them on every URL change; pushState entries do not register in the back-forward list for loadHTMLString documents (test-environment limitation, documented in BrowserStateTests).*

## Context

- **#44 / AIA-0044** — the address bar must reflect the page's real URL. Users pan/zoom map
  applications (LIDAR/orthophoto sites); those are SPAs that rewrite the URL via the History API
  (`pushState`/`replaceState`). The address bar must follow "as in a normal browser", transparently.
- **#277 / AIA-0277** — review of the nested browser architecture: is `UIViewRepresentable` still
  the right approach; the custom `addressBarTextField` + `DropdownMenuModifier` pain; missing
  back/forward/reload; crowded top bar on iPhone; different layouts for compact vs regular.
- User-stated scope emphasis: the current address bar *works* for typing; the gap is
  (a) URL updates from page-side navigation, (b) back/forward/reload controls, with placement
  solved for **compact mode** (iPhone) specifically.
- Related but **out of scope**: AIA-0215 (store detected findings).

## Architecture review — verdict for #277

### Is `UIViewRepresentable` still right? Yes, for now.

- Deployment target is **iOS 17.6**. The modern replacement — WebKit for SwiftUI (`WebView` view +
  `@Observable WebPage`, introduced at WWDC25) — requires iOS 26+, and the detection pipeline
  depends on direct `WKWebView` access (`WebViewRenderer.webView` → `takeSnapshot`); the new API
  does not expose the underlying `WKWebView` and a snapshot equivalent has not been verified.
  **Decision: keep `MLWebView: UIViewRepresentable`; re-evaluate when the min target reaches 26.**
  The plan below deliberately concentrates browser state in one observable object so a later
  `WebPage` migration is mostly a swap of the observation source.

### Root cause of AIA-0044

The app holds four URL-ish sources of truth, none observing the real one:

| Holder | Role | Updated by |
|-|-|-|
| `inputUrl` (`WebScreenView` `@State`) | address bar text | user typing, history pick, onAppear |
| `websiteUrl` (`WebScreenView` `@State`) | load request input to `MLWebView` | submit, history pick, onAppear |
| `settings.lastPage` | reopen-last-page persistence | `didFinish` only |
| `WebHistoryEntry` (Core Data) | history/autocomplete | user submit only |

`WKWebView.url` — the actual URL, KVO-compliant, updated **also for same-document History-API
navigations** (which never fire `WKNavigationDelegate.didFinish`) — is observed by nobody.
Link clicks inside the page already leave the address bar stale today; map pans are the
acute case.

### Other findings (feed phases 2–3)

- No `goBack`/`goForward`/`reload` surface at all; `allowsBackForwardNavigationGestures` is off,
  so not even edge-swipe works.
- `DropdownMenuModifier` is a hand-rolled overlay (magic 42 pt spacer, 0.6/0.4 size fractions)
  wired through `Guide.addressBarMenu`/`addressSelected` published state across two distant views
  (`WebScreenView` ↔ `ContentView`). It works but is the most fragile piece; SwiftUI still has no
  native text-field dropdown, so the *modern* pattern is Safari's: a tap on the (read-only) URL
  display opens a focused search/history surface instead of an inline dropdown.
- The load-request channel is a bare string (`websiteUrl`): after an SPA moves the real URL from
  A to B, re-submitting A is a no-op (same `@State` value, and `lastLoadedInput` in
  `updateUIView` rejects it) — the user cannot navigate back to where they typed. Fixed in
  phase 1 by giving load requests identity (below).
- `webViewWebContentProcessDidTerminate` is unhandled (blank page until manual reload) — noted,
  not in scope.

## Design

### New `BrowserState` (State/BrowserState.swift)

`@MainActor final class BrowserState: ObservableObject` per the repo's "views send intents"
convention. **Owned by `AppState`** (`lazy var browserState`, next to `webViewRenderer` at
`Appstate.swift:27`); exactly one instance; views that need it receive it via explicit
`.environmentObject(appState.browserState)` injection (observing `AppState` does not propagate a
child's `objectWillChange`).

- `attach(_ webView: WKWebView)` — called from `MLWebView.makeUIView` (next to the existing
  `webViewRenderer.webView = webView`). Holds the web view **weakly**. Installs KVO Combine
  publishers (`webView.publisher(for: \.url)`, `\.canGoBack`, `\.canGoForward`, `\.isLoading`)
  mirrored into `@Published` properties: `currentURL: URL?`, `canGoBack`, `canGoForward`,
  `isLoading`.
- **Lifecycle**: `attach` is idempotent — it first cancels any prior subscriptions, so a
  `makeUIView` re-run is safe. With `AppMode.tabOrder == [.web]` (single tab) the `TabView`
  never discards the web screen, so `dismantleUIView` effectively never fires today — but
  `tabOrder` is a one-line property someone will eventually extend, so the teardown half exists
  as cheap insurance: `dismantleUIView` calls `browserState.cancelSubscriptions(if: uiView)`
  (identity-guarded, via a weak `BrowserState` reference the coordinator captured in
  `makeUIView`) and **deliberately does not nil `webViewRenderer.webView`** (one comment in
  code: the snapshot ref is detection's concern; clearing it on a transient rebuild would break
  `takeSnapshot` mid-detection). A live web view with cancelled mirrors is safe: the mirrors
  feed only browser chrome (address bar, nav buttons) — `takeSnapshot` reads the web view
  directly and never consumes `BrowserState`, and if the web screen is ever dismantled in a
  multi-tab future its chrome is gone with it, so a stale-mirror bar cannot be displayed.
  Sinks capture `[weak self]`; no `assign(to:on:)` (retain-cycle-prone).
- **Display stream**: `removeDuplicates()` + `throttle(for: .milliseconds(100), latest: true)`
  on the `currentURL` → address-bar path, **unconditional**. Throttle (not debounce) keeps the
  bar live — it emits immediately and then at most 10×/s — while capping TextField rebuilds if
  a map fires `replaceState` per inertial-move frame; there is no scenario where removing it
  helps. **Implementation task**: measure the **KVO `\.url` callback frequency per pan/zoom
  gesture** (the signal the throttle actually sees — not the JS History-API call rate, which can
  differ) on mapy.com and ags.cuzk.cz — to *tune the interval only*, not to gate the throttle's
  existence.
- Intents: `goBackTapped()`, `goForwardTapped()`, `reloadTapped()`, `stopTapped()` — forward to
  the web view.
- **`settings.lastPage` policy** (restorable ≠ displayed): displayed URL mirrors `webView.url`
  raw; `lastPage` is persisted from the same stream but **only when eligible** — `host != nil`
  and scheme is http/https (the same conditions `didFinish` effectively enforced). Written
  immediately (UserDefaults writes are cheap; no coalescing timer to lose on backgrounding).
  This replaces the `didFinish`-only write so "reopen last page" restores the exact map position.
  The `lastPage` callback plumbing in `MLWebView` is then removed.

### Load-request identity (`WebScreen.swift` + `WebView.swift`) — phase 1

Replace the bare `websiteUrl: String` with a small value:

```swift
struct LoadRequest: Equatable {
    let input: String          // raw user input; normalization stays in updateUIView
    let generation: UInt64     // bumped on every submit/history-pick
}
```

`updateUIView` keys its dedup guard on `generation`; the string-keyed `lastLoadedInput` guard
(`WebView.swift:127`) is **deleted, not coexisting** — if it stayed, a same-string re-submit
would never load and the navigation-settled gate clearing could never fire. Re-submitting the
URL the SPA has since drifted away from thus performs a real load. Input normalization
(`browserInputType` / `withHTTPS` / search fallback) stays where it is. In
`handleAddressBarSubmit`, the unconditional `websiteUrl = inputUrl` assignment is
conditionalized: a `LoadRequest` is built only for `.url`/`.searchTerm`; for `.unusable` input
the bar simply retains the typed text (today's effective behavior, now explicit).

### Address bar sync (WebScreen.swift) — phase 1, the AIA-0044 fix

- Editing state moves to an explicit `@FocusState private var addressBarFocused: Bool`
  (`showMenu` keeps meaning *menu visibility* only — no double duty as navigation arbitration).
- **All writers of `inputUrl`, with precedence** (every one enumerated; no others may be added
  without extending this table):

  | Writer | When | Precedence rule |
  |-|-|-|
  | user typing | focused | always wins (KVO gated off while focused) |
  | `onAppear` (lastPage/defaultPage) | once at startup | necessarily precedes any KVO emission (the first load request is issued by this same `onAppear` / the initial `@State`); the first KVO emission may overwrite with the normalized form — intended. **No-default branch**: the hardcoded initial `websiteUrl` (google.com, `WebScreen.swift:60`) stays and always loads; today the bar misleadingly sits empty while it loads — under the new model KVO fills the bar with google.com — intended improvement |
  | history pick — the `onReceive($addressSelected)` subscriber, the **single** pick writer | unfocused | sets `pendingUserLoad`, bumps `LoadRequest` generation, clears the menu |
  | submit (`.url` / `.searchTerm` input) | focus end | sets `pendingUserLoad`, bumps `LoadRequest` generation, clears focus — search terms load via the Google fallback in `updateUIView`, so they gate like URLs |
  | submit (`.unusable` input) | focus end | **full no-op**: no bump, no gate — `updateUIView` would never issue a load, so setting the gate would strand it |
  | KVO `currentURL` | unfocused, no pending load | writes `inputUrl` only when `!addressBarFocused && !pendingUserLoad` |

  Today a pick has **two** entry points racing on the same `@State`: the
  `onReceive($addressSelected)` subscriber (`WebScreen.swift:158`) *and* the consume-branch
  inside `handleInputUrlChange` (`WebScreen.swift:108-113`). Phase 1 **deletes the
  consume-branch**; its cleanup (nil-ing `addressSelected`, clearing the menu) moves into the
  one `onReceive` writer, so the table's single pick row matches the code.
- `pendingUserLoad` is **keyed to navigation identity, not a bare bool**, and **lives in
  `BrowserState`**. Plumbing (explicit, because none of it exists today):
  - The `DispatchQueue.main.async` wrapper around `uiView.load` (`WebView.swift:131-133`) is
    **removed** — `updateUIView` already runs on the main thread per the `UIViewRepresentable`
    contract; the wrapper only deferred the load and hid the return value. `updateUIView`
    captures the `WKNavigation` token synchronously at the load site and reports
    `browserState.navigationIssued(token)`.
  - The four delegate callbacks (`didCommit`, `didFinish`, post-commit `didFail`, and the
    **new** `didFailProvisionalNavigation` — the method where DNS/no-network failures *and* a
    superseded load's `NSURLErrorCancelled` actually arrive; today only post-commit `didFail`
    exists at `WebView.swift:243`) call `browserState.navigationSettled(navigation, error:)`
    **directly through the Coordinator's weak `BrowserState` reference** (the same one captured
    in `makeUIView` for dismantle) — `loadStatusChanged: (Bool, Error?) -> Void` is untouched
    and carries no token.
  - **Pre-token window semantics**: *gating* needs no token — the gate blocks KVO writes from
    the moment the submit/pick intent sets it; the token matters only for *clearing*. Since
    `load(_:)` returns its token synchronously and WebKit delivers that navigation's delegate
    callbacks strictly afterwards, the token is always recorded before any settle of that
    navigation can arrive; settles carrying an unrecorded token are ignored.
  The gate clears only when the **latest** issued navigation settles. A superseded load's
  cancel carries the old token and cannot open the gate early. Never cleared by URL comparison.
  Same-URL picks are covered: the generation bump forces a real reload (the string-keyed
  `lastLoadedInput` guard is **deleted**, see Load-request identity), so settle always fires
  and the gate cannot stick. This closes the dropdown-pick race — a KVO emission carrying the
  *old* URL can never clobber a just-picked entry.
- Programmatic `inputUrl` writes do re-trigger `handleInputUrlChange`, but they only happen
  unfocused, where `showMenu` is false → the handler takes the reset branch
  (`addressBarMenu = []`); the menu cannot repopulate from a programmatic write.
- On blur *without* submit (user cancels): resync `inputUrl` to `currentURL`.
- History recording behavior **unchanged**: entries are created on user submit only. Recording
  page-side navigations would flood the capped history with map-pan URLs; revisit with AIA-0215.

### Navigation controls — phase 2

- `MLWebView.makeUIView`: set `allowsBackForwardNavigationGestures = true` — native edge-swipe
  back/forward for free, independent of any buttons.
- **Ownership**: browser nav controls are composed in **`WebScreen.barItems`** (a new
  `WebToolbarLeading`/`WebToolbarTrailing` wrapping the existing `GlobalToolbar*` views plus the
  nav buttons). `GlobalToolbar*` itself is untouched — Gallery shares it and must not grow
  browser buttons.
- **Regular width** (iPad full-screen / wide split): per the issue's sketch —
  leading `[CPU] [BACK]`, principal address field, trailing `[RELOAD] [FORWARD] [PLAY] [EDIT]`.
  Gated on `@Environment(\.horizontalSizeClass) == .regular`. Buttons disable on
  `canGoBack`/`canGoForward`; 44 pt min hit targets (same treatment as the AIA-0183 fix).
  No Mac Catalyst variant — `SUPPORTS_MACCATALYST = NO`.
- **Compact width** (iPhone; iPad narrow split inherits automatically): top bar stays
  `[CPU] [address] [PLAY] [EDIT]`. Back/reload/forward live in a **floating capsule**
  (`chevron.left | arrow.clockwise / xmark | chevron.right`), reusing the `FloatingChromeButton`
  interaction pattern: `.ultraThinMaterial`, draggable with the same clamp/named-coordinate-space
  technique, only its own frame hit-testable. New view `UI/FloatingNavBar.swift`; position owned
  by `ContentView` `@State`.
- **Reload/stop decided**: while `isLoading`, the middle button shows `xmark` and calls
  `stopTapped()`; otherwise `arrow.clockwise` → `reloadTapped()`. (`isLoading` thus has a
  concrete consumer.)
- **Coexistence with the floating chrome toggle**: when detection runs with chrome revealed,
  both floating controls are on screen. Distinct default positions — nav capsule
  **bottom-center**, chrome toggle bottom-right (as today); both draggable. No collision
  avoidance logic — named trade-off; users can move either.
- **Fullscreen-detection interplay**: the capsule is chrome — visible only when
  `mode == .web && compact && chromeVisible`. In fullscreen detection it disappears with the
  rest of the chrome (the floating chrome toggle stays, as today).

### Location sheet (dropdown replacement) — NOW IN SCOPE (user decisions, 2026-06-11)

The user pulled phase 3 into this branch with a concrete spec (supersedes the deferral and
dissolves most of the focused-TextField writer races — the bar is no longer editable):

- The top-bar address becomes a **read-only display at maximum width**; tapping it presents a
  **sheet** (Safari-iOS "Search" table pattern) — on iPhone, iPad, *and* the
  iPad-on-Mac build (real desktop Safari uses an inline dropdown, but the sheet is acceptable
  there per user decision).
- Sheet contents: focused `TextField` (search-or-URL) with an explicit **[Open]** confirmation
  (return key + button, disabled for `.unusable` input); history list driven by the existing
  `@FetchRequest`; typing **filters with debounce (~250 ms)**; sort toggle **Recent ↔ A–Z**;
  rows show the URL **fully visible (multiline)** with a toggle to collapse to one line, plus
  the entry's **timestamp**.
- **Timestamp**: `creationDate_` is "when the URL was entered in the address bar"; re-entering
  an existing URL **updates its timestamp** (today duplicates are skipped entirely), shown in
  the sheet rows. No schema change.
- **History on submit stands** (recorded even if the page never finishes loading — confirmed).
- The bar shows the *requested* URL while a user load is pending, else throttled `currentURL`
  (the navigation-identity gate from the grilled design drives this display switch).
- This deletes `Guide.addressBarMenu`/`addressSelected`, the `ContentView` dropdown overlay,
  and `DropdownMenuModifier` (+ its Testability ids).
- **Regular width grouping (revised)**: `[BACK][ADDRESS][FORWARD]` sit **together** in the
  principal slot — not BACK next to CPU / FORWARD next to PLAY. Reload/stop joins the trailing
  group before PLAY/EDIT. Compact keeps the floating capsule.
- **JS dialogs un-suppressed**: the web view gets a `WKUIDelegate` implementing
  alert/confirm/prompt panels (presented via `UIAlertController` from the web view's window),
  working on iOS and iPad-on-Mac.
- **Redirects**: handled — KVO `\.url` tracks server redirects through provisional → commit,
  and `didFailProvisionalNavigation` covers redirect failures.
- Escape hatch (user-approved): if anything is too stretched on iOS 17, the deployment target
  may be raised (drops iOS 17 support).

## Files touched (phases 1–2)

| File | Change |
|-|-|
| `State/BrowserState.swift` | **new** — KVO mirrors + nav intents + lastPage policy |
| `State/Appstate.swift` | `lazy var browserState` |
| `UI/WebView.swift` | `attach`, subscriptions-only `dismantleUIView`, `LoadRequest` generation dedup (**delete** string `lastLoadedInput` guard at `:127`), **remove** the `DispatchQueue.main.async` load wrapper, `navigationIssued`/`navigationSettled` token plumbing via the Coordinator's weak `BrowserState` ref, **new** `didFailProvisionalNavigation` delegate method, back-forward gestures, drop `lastPage` callback |
| `UI/Screens/WebScreen.swift` | `@FocusState` guard, `LoadRequest`, URL sync, single pick writer (consume-branch deleted), size-class toolbar |
| `UI/FloatingNavBar.swift` | **new** — compact floating back/stop-reload/forward capsule |
| `UI/ContentView.swift` | mount FloatingNavBar (compact, chrome visible) + position state |
| `Tools/Testability/Testability.swift` | ids: back/forward/reload-stop buttons |
| `Resources/Localizable.xcstrings` + `Generated/L10n.swift` | accessibility labels |
| `MLBrowserUnitTests/BrowserStateTests.swift` | **new** — see Verification |
| `ios/MLBrowser.xcodeproj/project.pbxproj` | register 3 new files (manual, 4 entries each) |

## Risks / open decisions

- **Focus-state correctness**: `@FocusState` on a principal-toolbar `TextField` must behave on
  iOS 17/18/26; verify early in implementation — fallback is the TextField `onEditingChanged`
  closure already in use.
- **Top-bar fit on regular**: 6 bar items + principal field with large Dynamic Type — verify on
  iPad portrait; fallback: iPad portrait uses the compact (floating) layout.
- **`lastPage` semantic change**: now stores mid-session SPA URLs (eligible-filtered), not just
  committed loads. Intended (restores map position) but called out for review.
- **Two floating controls**: no collision logic (trade-off above).

## Release-time obligation — Core Data model v0.0.2 (added 2026-06-11)

This branch introduced model version `MLBrowser_0.0.2` (`WebHistoryEntry.visitCount` + the
`WebVisit` trail entity). **Only model 0.0.0 has ever shipped** (user decision: no
0.0.1→0.0.2 mapping needed — 0.0.1 stores exist only on dev machines, where the
destroy-and-recreate recovery is acceptable). What MUST happen **before the next App Store
release** (release builds run with mapping inference disabled):

- Generate `MLBrowser_0.0.0_0.0.2.xcmappingmodel` in Xcode (File → New → Mapping Model,
  source 0.0.0 → target 0.0.2) and wire `FillEntityIdIfNilPolicy` on the entity mappings
  the same way `Migration/0.0.0-0.0.1/` does — explicit mappings do **not** chain, so the
  existing 0.0.0→0.0.1 mapping does not cover users migrating straight to 0.0.2.

## Verification

1. **Unit tests** (`BrowserStateTests`, real `WKWebView` on simulator with local HTML):
   - KVO mirrors update on load; **`pushState`/`replaceState` executed via
     `evaluateJavaScript` update `currentURL`** (proves the central History-API assumption);
   - back/forward mirrors and intents walk pushState entries;
   - re-`attach` cancels prior subscriptions (old web view no longer publishes);
   - `lastPage` eligibility filter (about:blank / no-host URLs not persisted);
   - `LoadRequest` generation bump forces a reload of an identical string;
   - **dropdown-pick race**: a history pick followed by a KVO emission of the *previous* URL
     leaves the picked URL in the bar (`pendingUserLoad` gate);
   - `pendingUserLoad` clears on settle **of the latest navigation only** (navigation-identity
     keyed, covering `didCommit`, `didFailProvisionalNavigation` — DNS/no-network and
     supersede-cancel — and post-commit `didFail`): same-URL pick (generation bump → real
     reload → settle), superseded-load cancel does not open the gate early, `.unusable` submit
     never sets the gate, provisional failure does not strand the gate;
   - startup order: bar shows the loaded URL after the first KVO emission, including the
     no-default case (hardcoded google.com — bar no longer sits empty during the initial load).
   Gates: `scripts/swiftlint.sh`, `scripts/harmonize.sh`, `scripts/unittest.sh`.
   **pbxproj gate**: immediately after registering the 3 new files, run
   `xcodebuild test -scheme MLBrowser -testPlan MLBrowserUnitTests` (the plan at
   `ios/MLBrowserTestPlan/MLBrowserUnitTests.xctestplan`, explicit simulator destination as in
   `scripts/unittest.sh`) and assert the log shows **`Test Suite 'BrowserStateTests'` executed
   with > 0 tests** — exit code 0 alone can mean the file silently landed outside the target.
   If the gate fails, the pbxproj edit is reverted as a unit and redone.
2. **Manual on simulator**: mapy.com / ags.cuzk.cz pan → bar follows live; in-page link → bar
   updates; back/forward walk map states; edge-swipe works; stop shows during slow load;
   typing while page changes URL → input not clobbered; blur-without-submit resyncs;
   re-submitting the original URL after panning reloads it; compact capsule drag/clamp +
   coexistence with chrome toggle; iPad regular layout; fullscreen detection hides the capsule.
3. **UI tests**: extend `BrowserRevampUITests` locally (not in CI per current Xcode Cloud
   workflow); full UI-test coverage deferred until the UI redesign settles (user decision).
4. One PR per phase to `develop`; phase 1+2 PR: `[AIA-0044] Live URL bar + browser nav controls`,
   body carries the #277 architecture verdict; `Fixes #44`, `Refs #277`.
