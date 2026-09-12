# Architecture (iOS / MLBrowser)

A map of how the app is actually wired — the "big picture" that otherwise requires
reading many files to reconstruct. For the *rules* this structure must follow
(concurrency, state patterns, testing, Core Data versioning), see **`AGENTS.md`**;
this document describes *what connects to what*.

## What the app does

ML Browser pairs a web browser with on-device CoreML object detection: the user loads
a CoreML model, and Vision runs it against timed snapshots of the rendered web page,
drawing detections over the content. Page snapshots and detection imagery never leave
the device (the privacy invariant — AGENTS.md §10); network traffic is limited to
browsing itself, auth, subscriptions, model downloads, and crash diagnostics.

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
the `@main` entry and the background-session `UIApplicationDelegate`, which run outside the SwiftUI
graph.

Test isolation lives here: in DEBUG under tests, `usesMockAuth` / `usesMockSubscription`
swap in in-memory mock providers so unit/UI tests never touch Clerk or StoreKit. The mocks
are `#if DEBUG`, so they can never ship in Release/TestFlight.

## App entry & gating

`MLBrowser/iOS/UI/MLBrowser.swift` — `@main struct MLBrowser: App`. The root `AppState`
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
(`UI/Subscription/SubscriptionGateView.swift`). The free window (AIA-0556) is a 14-day period owned
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
| `UI/` | SwiftUI views by feature (`Screens`, `Drawer`, `Auth`, `Subscription`, `Findings`, `Annotation`, `Tour`, `SettingsView`, …); app entry `MLBrowser.swift` |
| `State/` | State objects, `DependencyContainer`, `DataController`, auth/subscription providers |
| `Drivers/` | Detection engine: `Driver`, `DeepDriver`, `Detector`, `Classificator`, `DetectionTiling`, demo models |
| `Rendering/` | WebView snapshotting: `WebViewRenderer`, `DefaultRenderer`, `Snapshot` |
| `Persistence/` | Core Data classes, `.xcdatamodeld`, migrations |
| `Services/` | Stateless workers (e.g. `ModelLoadingService`) |
| `Tools/` | Cross-cutting helpers: reporting/observability, testability, extensions, localization |
| `Resources/`, `Assets/`, `Generated/` | `Localizable.xcstrings`, assets, generated `L10n.swift` |

Test targets live alongside at `ios/`: `MLBrowserUnitTests/`, `MLBrowserUITests/`,
`MLBrowserArchitectureTests/` (Harmonize rules in `ArchitectureTests.swift`).
