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

## The kill switch fails open — know its limits

Both defaults are `true`, so on a fresh offline install, a bad SDK key, a missing flag, or
a ConfigCat outage, a "killed" feature **stays on**. This is deliberate — it preserves
shipped behaviour and avoids a crippled first launch — but it means:

- The switch only reaches clients that successfully fetch.
- Auto-poll (10 min) only ticks **while the process is alive**. A suspended app does not
  poll, so latency is a foreground-only bound.

If you ever need a flag that fails *closed*, give it `defaultValue = false` and ship it
dark first.

## Environments

| Build | ConfigCat environment | Key |
|-|-|-|
| Debug / simulator | Test | `CONFIGCAT_SDK_KEY` |
| Release / TestFlight / App Store | Production | `CONFIGCAT_SDK_KEY_LIVE` |
| Unit tests, UI tests, previews | none — `StaticFeatureFlagProvider`, no network | — |

Keys come from 1Password (`ConfigCat Keys`) via `ios/Secrets.template.xcconfig` →
`ios/Secrets.xcconfig` (gitignored) → `ios/MLBrowser-Info.plist`, mirroring the Sentry DSN
and Clerk key pattern. Regenerate with:

```bash
swift run --package-path Tools ProjectTool secrets refresh
```

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
   (keyed by `rawValue`; an unknown key traps).
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
