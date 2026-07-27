# Feature Flags (ConfigCat)

How ML Browser's remote feature flags work, and how to add one. Introduced in AIA-0350;
rules live in [`ios/AGENTS.md`](./ios/AGENTS.md) §3.

Flags are **remote**: they can be flipped from the ConfigCat dashboard without an App
Store release. Every flag also has a **compiled default** used whenever remote config
cannot be consulted.

## The current flags

| Key | Default | Applies | Gates |
|-|-|-|-|
| `isModelCatalogEnabled` | `true` | **live** | The public model-catalog acquisition surface (AIA-0413) |
| `isPaymentsEnabled` | `true` | **launch only** | The subscription/paywall surface (AIA-0343) |
| `isAnalyticsEnabled` | `true` | **live** | Optional analytics availability: when off, no prompt or Settings control is shown and no provider can activate. When on, users retain their own opt-in/out choice. |
| `isRefundRequestEnabled` | `true` | **live** | The Settings → Subscription "Request a Refund" row (AIA-0461). When off, the row is hidden; refunds remain available through the App Store. |
| `isAppMessagingEnabled` | `true` | **live** | The app→user messaging surface (AIA-0115): whether remotely-published messages render at all. Fails open — safe because the `appMessages` content setting defaults to empty, so an outage shows no messages rather than stale ones. |
| `isRatingPromptEnabled` | `true` | **live** | The native App Store rating request offered after a positive moment — a finding saved, or a model imported/converted (AIA-0117). When off, the app never asks; the user can still review from the App Store. |

## How it fits together

```
FeatureFlagKey (enum, String raw)      rawValue IS the ConfigCat key
  └── defaultValue                     compiled fallback
        │
ConfigCatFeatureFlagProvider           the only file importing ConfigCat; not @MainActor
  └── FeatureFlagProviding             narrow test seam (+ StaticFeatureFlagProvider)
        │
FeatureFlagsState (@MainActor)         publishes an immutable FeatureFlagSnapshot
        │
DependencyContainer  →  AppState.featureFlags  →  views
```

| File | Role |
|-|-|
| `ios/MLBrowser/iOS/State/FeatureFlags.swift` | `FeatureFlagKey` (keys + defaults), `FeatureFlagSnapshot` |
| `ios/MLBrowser/iOS/Tools/FeatureFlags/FeatureFlagProviding.swift` | Provider seam + `StaticFeatureFlagProvider` |
| `ios/MLBrowser/iOS/Tools/FeatureFlags/ConfigCatFeatureFlagProvider.swift` | ConfigCat adapter |
| `ios/MLBrowser/iOS/State/FeatureFlagsState.swift` | Observable snapshot owner |

## Rules that are easy to get wrong

- **The key is `rawValue`, a declared literal.** Never derive a flag key from a symbol
  name — release builds strip and rename symbols, and the lookup would silently miss and
  fall back to the default forever.
- **Nothing blocks launch.** The snapshot seeds synchronously from the SDK's own cache;
  `refresh()` runs detached *after* `isReady`. Never `await` ConfigCat on the launch path.
- **A live flag needs a subscription, not just a refresh.** `FeatureFlagsState` observes
  `onConfigChanged` (via `FeatureFlagProviding.changes()`) and republishes. The SDK's
  auto-poll updates its *own* cache and calls nothing of ours, so a one-shot `refresh()`
  at launch would leave `client.snapshot()` stale until relaunch.
- **No app-owned cache.** The ConfigCat SDK already persists config JSON to `UserDefaults`
  under `com.configcat-` and exposes a synchronous `client.snapshot()`. A second cache
  would be a competing source of truth that diverges across environments.
- **Live vs launch-only is a real decision.** `SubscriptionGateView` is the *app root*:
  applying a mid-session `isPaymentsEnabled` flip would drop a paywall on someone
  mid-detection, or release an unpaid user from it. That flag is captured once in
  `AccountSession`. A flag that merely shows/hides an entry point can apply live.
- **Nested observables don't republish through their parent.** A view gating on a live flag
  must observe `FeatureFlagsState` directly (`@EnvironmentObject`), not reach through
  `AppState`. Re-inject it on any `.sheet` — environment values don't reliably cross sheet
  boundaries on Mac (AGENTS.md §3).

## Defaults decide whether a switch fails open or closed

`isModelCatalogEnabled` and `isPaymentsEnabled` default to `true`, so on a fresh offline
install, a bad SDK key, a missing flag, or a ConfigCat outage, those features **stay on**.
This preserves shipped behaviour, but means their switches only reach clients that
successfully fetch.

`isAnalyticsEnabled` defaults to `true`, like the existing flags. This only makes the
analytics choice available; it does not collect anything by itself. The effective analytics
state is the remote flag **and** the user’s local opt-in, which defaults to off. Turning the
flag off does not erase the user’s choice, it just makes analytics unavailable until turned
on again.

For fail-open flags:

- The switch only reaches clients that successfully fetch.
- Auto-poll (10 min) only ticks **while the process is alive**. A suspended app does not
  poll, so latency is a foreground-only bound.

For a feature that must fail *closed*, give it `defaultValue = false` and ship it dark first.

## Environments

| Build | ConfigCat environment | Key |
|-|-|-|
| Debug / simulator | Test | `CONFIGCAT_SDK_KEY` |
| Release / TestFlight / App Store | Production | `CONFIGCAT_SDK_KEY_LIVE` |
| Unit tests, UI tests, previews | none — `StaticFeatureFlagProvider`, no network | — |

**TestFlight reads Production, and that is deliberate.** The split is on build
configuration, not distribution channel: a TestFlight binary is promoted to the App Store
unchanged, so it must read the flags it will read once released. Sending it to Test would
validate the release candidate against config it never sees in production.

This intentionally differs from `ClerkAuthProvider.publishableKey`, which keys off
`isAppStoreDistribution` and so gives TestFlight the *dev* Clerk instance. Dev auth and
sandbox purchases are imposed on TestFlight by the receipt; the flag environment is a free
choice, spent here on fidelity.

> **There is no tester-only flag.** Flipping a flag reaches TestFlight testers and live App
> Store users alike. To rehearse a flip, use a Debug build against the Test environment.

The last row is enforced by three separate markers in
`DependencyContainer.featureFlagProvider` — `isRunningUITests || isRunningUnderAnyTests ||
isRunningInPreviews` — and all three are load-bearing. `XCTestConfigurationFilePath` (which
backs `isRunningUnderAnyTests`) is absent in a UI-tested app, because the app runs as a
separate process from the test runner; previews are not a test at all, yet still get a valid
Debug key.

**Locally**, keys come from 1Password (`ConfigCat Keys`) via `ios/Secrets.template.xcconfig`
→ `ios/Secrets.xcconfig` (gitignored) → `ios/MLBrowser-Info.plist`, mirroring the Sentry DSN
and Clerk key pattern. Regenerate with:

```bash
swift run --package-path Tools ProjectTool secrets refresh
```

**On Xcode Cloud**, `ios/Secrets.xcconfig` is generated from workflow environment variables
by `ios/ci_scripts/ci_pre_xcodebuild.sh` — 1Password is not reachable there. The **archive**
workflow must define `CONFIGCAT_SDK_KEY_LIVE` (mark as Secret), and the script hard-fails
without it. That hard failure is deliberate: a missing key is not otherwise a build error,
so the app would ship falling back to compiled defaults — both ON, indistinguishable from
healthy, and unreachable by any dashboard change. Test and build actions need no key: they
are Debug and pin `StaticFeatureFlagProvider`.

Xcode Cloud env var names match build-setting names (as with `SENTRY_DSN` and
`CLERK_PUBLISHABLE_KEY_LIVE`); the 1Password field names are a separate namespace, mapped in
`ios/Secrets.template.xcconfig`.

Dashboard: org `Aiarcheology` → `Aiarcheology's Product` → `Main Config`.

## Adding a flag

1. **ConfigCat first**, before shipping code that reads it. Create the flag in the
   dashboard; it is created in *all* environments at once, with one value per environment.
   ⚠️ The dashboard **auto-generates the key from the name** — overwrite it so the key
   matches your `rawValue` exactly. A mismatched key fails silently: the SDK falls back to
   the compiled default and the flag looks healthy but can never be flipped.
2. Add a `case` to `FeatureFlagKey` and its `defaultValue`.
3. Decide **live or launch-only** and wire it accordingly.
4. Read it from `featureFlags.snapshot` (live) or capture it at launch (session-boundary).
5. UI tests can force it via `UITestLaunchConfiguration.featureFlagOverrides`
   (keyed by `rawValue`; an unknown key traps). Assert on the *overridden* value, never a
   value that equals the compiled default — a test that agrees with the default passes even
   when the override is ignored entirely. `FeatureFlagUITests` is the worked example.
6. Remove the flag once its feature is permanently on — don't let dead flags accumulate.

## Verifying it really works

The unit suite uses `StaticFeatureFlagProvider`, so it **cannot** prove the ConfigCat
integration works. To check for real: run a Debug build (→ Test environment), flip a flag
in the dashboard, and confirm the app reacts within ~10 minutes or on relaunch. The
dashboard's **Usage & Quota** page showing a non-zero config-JSON download count is proof
the app actually connected.

## Related

- [`ANALYTICS.md`](./ANALYTICS.md) — product analytics (TelemetryDeck)
- [`ios/AGENTS.md`](./ios/AGENTS.md) §3 — feature-flag rules
- Free tier: 5M config-JSON downloads + 20 GB/month (far above our needs)
