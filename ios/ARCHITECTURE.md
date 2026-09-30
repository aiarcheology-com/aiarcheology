# Architecture (iOS / MLBrowser)

A map of how the app is actually wired — the "big picture" that otherwise requires
reading many files to reconstruct. For the *rules* this structure must follow
(concurrency, state patterns, testing, Core Data versioning), see **`AGENTS.md`**;
this document describes *what connects to what*.

## What the app does

ML Browser pairs a web browser with on-device CoreML object detection: the user loads
a CoreML model, and Vision runs it against timed snapshots of the rendered web page,
drawing detections over the content. Inference stays on-device and transient page snapshots
are not uploaded. Saved finding images can leave through authorized sharing or account-backed
sync, subject to ownership, per-finding consent, and backup preferences. Imagery does not belong
in telemetry or diagnostics. See the [repository privacy boundary](../AGENTS.md#data-and-privacy)
and [findings sync rules](../specification/USER_DATA_PERSISTENCE.md).

## Layering

Pragmatic MVVM-like, enforced by Harmonize architecture tests (see AGENTS.md §7):

| Layer | Type | Role |
|-|-|-|
| Views | SwiftUI `struct` | Render state, send intents. No business logic. |
| State objects (`*State`, `*Manager`) | `@MainActor` `ObservableObject` | Hold state + business logic. |
| Services / Drivers | `actor` | Heavy work off the main thread (Vision, networking, IO). |

## Composition root

`MLBrowser/iOS/State/DependencyContainer.swift` — a `@MainActor` singleton (`DependencyContainer.shared`)
that lazily builds and shares the core dependencies: `dataController`, `settings`,
`snapState`, `deepState`, `downloader`, `demoDataManager`, `authProvider`,
`subscriptionProvider`, plus an eagerly-created `crashReporter` (so observability starts
before anything can report).

It is the app's **single** composition root (AIA-0385): it constructor-injects a fully-wired
`AppState` via `makeAppState()`. `AppState` holds those injected instances and never reaches back
into `DependencyContainer.shared`; Views never touch `.shared` either (they read from `AppState` or
a dedicated environment value such as `\.usesRealAuth`). The only `.shared` sites are bootstrap —
the app entry points (`MLBrowser`, and `MLBrowserHeadless` in headless mode) and the
background-session `UIApplicationDelegate`, which run outside the SwiftUI graph.

Test isolation lives here: in DEBUG under tests, `usesMockAuth` / `usesMockSubscription`
swap in in-memory mock providers so unit/UI tests never touch Clerk or StoreKit. The mocks
are `#if DEBUG`, so they can never ship in Release/TestFlight. Headless mode selects its few
explicit launch options here too (`HeadlessLaunchOptions`, AIA-0970), never through the test markers,
and reads them only in headless mode (AIA-0991). Headless mode also forces the no-op crash reporter.

## App entry & gating

`MLBrowser/iOS/UI/AppEntry.swift` — `@main enum AppEntry` launches `MLBrowser` (the SwiftUI app,
`UI/MLBrowser.swift`) or, when launched with `-interface headless`, `MLBrowserHeadless`
(`Headless/Entry/`), the same app without its views (see `specification/HEADLESS.md`). Its screen/action
kit is the external HeadlessKit package (`aiarcheology-com/HeadlessKit`, pinned by exact version), which compiles to nothing outside Debug (AIA-1006). Headless is
a launch mode of the Debug app (AIA-0991; AIA-0970 made it a separate build):
`AppEnvironment.isHeadlessMode` is read at launch, and the branch, the entry and its command server
compile only under `DEBUG && AIA_BACKEND_ENV_development`, so Release and a Debug build against
production always launch `MLBrowser`.

Both entries bootstrap through `AppRuntime` (`State/AppRuntime.swift`): observability, Clerk, then
the composition root, in that order. `AppRuntime.start()` then runs the process-level work that
used to hang off the root scene — store-dependent services, the detailed-log brake,
background/foreground handling, and auth, which starts only once `AppState.isReady` — and the
foreground entitlement re-check, which used to hang off `SubscriptionGateView` (AIA-0993).
Presentation stays in the UI entry: overlays, URL intake, the production banner, and the Clerk
session watcher.

The root `AppState`
(`@StateObject`) is built by `DependencyContainer.makeAppState()`: it receives the shared services
by constructor injection (`snap`, `deep`, `dataController`, `settings`, `downloader`,
`demoDataManager`, auth/subscription providers) and additionally owns the view-derived state
(`browserState`, `guide`, renderers, `tour`, `authState`, `subscriptionState`, …).

The UI is gated in layers before the app proper appears:

```text
SubscriptionGateView      (AIA-0343 — the app root since AIA-0536)
  └─ AnalyticsChoiceGate  (AIA-0447 — the optional-analytics question)
       └─ ContentView     (the browser + detection UI)
```

Signing in is **not** a gate: `AuthGateView` was the outermost layer until AIA-0536, and the view
itself has since been deleted — sign-in is a contextual sheet (`SignInSheet`). Access is `payments surface off || StoreKit entitled
|| app-managed free window open`, resolved in that order by `RootGateDisplay`
(`UI/Subscription/SubscriptionGateView.swift`). Which Welcome screen goes up, and when the tour may
start, is `SubscriptionGateCoordinator` (same folder, AIA-0976): the view holds one per window and
calls it from its `onChange` handlers, and headless mode runs the same object. The free window (AIA-0556) is a 14-day period owned
by `FreeAccessWindow` / `FreeAccessAnchorService` / `FreeAccessState`, anchored in UserDefaults and
mirrored into the Keychain so a reinstall resumes it rather than restarting it. `AUTH-SUBSCRIPTION.md`
holds the full order, the state table and the edge cases.

A `BackgroundDownloadAppDelegate` bridges background `URLSession` completion back into
`Downloader` for downloads that finish while the app is suspended.

## The detection pipeline (core domain)

1. **`SnapState`** (`MLBrowser/iOS/State/SnapState.swift`) drives a configurable Combine timer that
   fires snapshot triggers; `SnapAdjustment` holds brightness/contrast/saturation.
2. **`WebViewRenderer`** (`MLBrowser/iOS/Rendering/`) snapshots the live `WKWebView` into a `UIImage`,
   applying the current `SnapAdjustment`. (`DefaultRenderer` is the base; `Snapshot` is the model.)
3. **`DeepState`** (`MLBrowser/iOS/State/DeepState.swift`) manages the active model **drivers**, created
   from persisted `DeepConfiguration`s and loaded/unloaded as configs are enabled/disabled.
4. **`Driver`** (`MLBrowser/iOS/Drivers/Driver.swift`, protocol `: Actor`) wraps a CoreML model.
   **`DeepDriver`** runs Vision requests as either a `detector` or `classificator`
   (`DeepDriverType`); `Detector` / `Classificator` / `DetectionTiling` implement the work.
5. Results become annotations drawn over the web content and are persisted as **`Finding`s**.

Bundled demo models live in `MLBrowser/iOS/Drivers/Demo Models/` (`AIArcheology.mlpackage`,
`HroudaDetector15.mlpackage`).

## Persistence

Core Data via **`DataController`** (`MLBrowser/iOS/State/DataController.swift`); entity
classes and the model live under `MLBrowser/iOS/Persistence/`. Entities include `Finding`,
`DeepConfiguration`, `DownloadItem`, `WebHistoryEntry`, `WebVisit`. The model
(`MLBrowser.xcdatamodeld`) is versioned, with mapping models under
`MLBrowser/iOS/Persistence/Migration/<from>-<to>/`. See **AGENTS.md §6** for the model-versioning rules
(new version only after the previous one shipped; mapping models generated in Xcode) and the
in-memory-store testing caveats.

## Feature flags

Significant/risky surfaces (payments, model catalog) are gated behind **remote** flags served by
ConfigCat (AIA-0350), flippable without an App Store release. `FeatureFlagKey`
(`MLBrowser/iOS/State/FeatureFlags.swift`) declares each key and its compiled default;
`ConfigCatFeatureFlagProvider` resolves them behind the `FeatureFlagProviding` seam; and
`FeatureFlagsState` publishes an immutable `FeatureFlagSnapshot` to the UI.

Defaults fail **open**, so an unreachable ConfigCat leaves shipped behaviour intact rather than
crippling the app. Debug builds read the Test environment; TestFlight and App Store read
Production. Views observe `FeatureFlagsState` directly rather than through `AppState`. See
**FEATUREFLAGS.md** (repo root) and **AGENTS.md §3** for the rules.

## Source layout (`ios/MLBrowser/iOS/`)

| Dir | Contents |
|-|-|
| `UI/` | SwiftUI views by feature (`Screens`, `Drawer`, `Auth`, `Subscription`, `Findings`, `Annotation`, `Tour`, `SettingsView`, …); app entry `AppEntry.swift` and `MLBrowser.swift` |
| `State/` | State objects, `DependencyContainer`, `DataController`, auth/subscription providers |
| `Drivers/` | Detection engine: `Driver`, `DeepDriver`, `Detector`, `Classificator`, `DetectionTiling`, demo models |
| `Rendering/` | WebView snapshotting: `WebViewRenderer`, `DefaultRenderer`, `Snapshot` |
| `Persistence/` | Core Data classes, `.xcdatamodeld`, migrations |
| `Services/` | Stateless workers (e.g. `ModelLoadingService`) |
| `Headless/` | Headless mode (AIA-0970, AIA-0991): screens and actions over `AppState`, launch options, and the `Entry/` app; see `specification/HEADLESS.md` |
| `Tools/` | Cross-cutting helpers: reporting/observability, testability, extensions, localization |
| `Resources/`, `Assets/`, `Generated/` | `Localizable.xcstrings`, assets, generated `L10n.swift` |

Test targets live alongside at `ios/`: `MLBrowserUnitTests/`, `MLBrowserUITests/`,
`MLBrowserArchitectureTests/` (Harmonize rules in `ArchitectureTests.swift`).
