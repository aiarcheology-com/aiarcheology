# ML Browser

ML Browser is an iOS app that combines a web browser with on-device machine learning: the user loads any CoreML object-detection model (image classification is planned), and Vision runs it against snapshots of the rendered page on a configurable timer, drawing the detections directly over the web content. No images leave the device.

The flagship use case — and where the name comes from — is archeology: browsing LIDAR / terrain-map sites with the bundled demo models to spot features such as burial mounds. But the app is model-agnostic; any imported detection model works the same way on any web content.

<p align="center">
  <img src="ExampleScreenshot.jpg" alt="AI Archeology example">
</p>

## Repository layout

| Path | Contents |
|-|-|
| `ios/` | The Xcode workspace (`MLBrowser.xcworkspace`), app sources, unit/UI/architecture tests, test plans, and Xcode Cloud `ci_scripts/` |
| `Tools/` | `ProjectTool` — a SwiftPM CLI for repo setup, pinned-tool installation, and secrets management |
| `scripts/` | Developer scripts: lint, codegen, architectural tests, unit tests |
| `cloudflare/` | Cloudflare Worker relaying Sentry issues into GitHub Issues ([details](cloudflare/README.md)) |
| `.github/workflows/` | CI: SwiftLint, Harmonize (architecture tests), issue-key automation |
| `.githooks/` | Git hooks (SwiftLint pre-commit), enabled by `ProjectTool setup` |
| `.tools.json` | Pinned versions of swiftlint / swiftgen / sentry-cli used by all developers and CI |

## Prerequisites

- **macOS with Xcode** (the team currently builds with Xcode 26.x; an iPhone simulator runtime is required for tests)
- **Swift toolchain** (ships with Xcode) — needed to run `ProjectTool`
- **1Password CLI** (`op`), signed in — local secrets are generated from 1Password
- *Optional:* **Homebrew** — only if you opt into [direnv command aliases](ios/MLBrowser/README.md#directory-aliases-via-direnv) during setup

## Getting started

```bash
git clone git@github.com:aiarcheology-com/aiarcheology.git
cd aiarcheology

# 1. Install pinned tools, configure git hooks (one-time)
swift run --package-path Tools ProjectTool setup

# 2. Generate local secrets from 1Password (one-time)
swift run --package-path Tools ProjectTool secrets generate

# 3. Open the workspace and run the MLBrowser scheme
open ios/MLBrowser.xcworkspace
```

The full setup reference — every `ProjectTool` command, pinned tooling, secrets lifecycle, and the optional shell aliases — lives in **[ios/MLBrowser/README.md](ios/MLBrowser/README.md)**.

## Day-to-day commands

| Command | Purpose |
|-|-|
| `./scripts/swiftlint.sh` (`fix` to autocorrect) | SwiftLint over the iOS sources |
| `./scripts/harmonize.sh` | Architectural rules, enforced as tests |
| `./scripts/unittest.sh` | Unit test plan on a simulator |
| `./scripts/swiftgen.sh generate` | Regenerate `L10n.swift` after editing `Localizable.xcstrings` |

Run lint + harmonize + unit tests before pushing; the same checks gate pull requests in CI (GitHub Actions for lint/architecture, Xcode Cloud for analyze/archive/unit tests).

## 🚀 Emergency delivery lane (Xcode Cloud fallback)

When Xcode Cloud is unavailable (allocation exhausted, outage), `scripts/deliver.sh` archives the app
locally and uploads it to TestFlight. Prefer Xcode Cloud for routine releases — this is a break-glass lane.

**Prerequisites**

- An **App Store Connect API key** with a role that can manage builds (**App Manager**, or a Developer
  role scoped to this app) — a weaker role returns `403` on upload/notes. Create it under
  App Store Connect → Users and Access → Integrations → App Store Connect API, download the
  `AuthKey_XXXX.p8` **once**, and keep it out of the repo (`*.p8` is gitignored).
- A valid **Apple Distribution** signing identity + provisioning in your login keychain (automatic
  signing; the archive uses `-allowProvisioningUpdates`, which may register devices/profiles in the
  Developer Portal).
- 1Password CLI (`op`) if you store the key there; otherwise a local `.p8` path.

**Credentials** — an App Store Connect API key, provided as either literal env vars or `op://`
references that `deliver.sh` resolves via 1Password at run time. A key resolved from 1Password
(`ASC_KEY_OP_REF`) is written to a short-lived `0600` temp file that's wiped on exit — never committed,
never persisted beyond the run. A key you point at directly (`ASC_KEY_PATH`) is a `.p8` that already
lives on disk; keep it outside the repo with restrictive permissions (`chmod 600`). Either way this is
a *delivery* credential, resolved at run time; it is deliberately **not** part of `Secrets.xcconfig`
(which compiles build secrets into the app).

The simplest setup is a gitignored `ios/asc.env` that `deliver.sh` sources automatically — copy the
template, then edit the vault/item/key-id to match your 1Password:

```sh
cp ios/asc.env.template ios/asc.env
```

```sh
# ios/asc.env — 1Password references (not secrets); resolved with `op` unlocked.
export ASC_KEY_ID='op://Personal/App Store Connect API Key/key id'
export ASC_ISSUER_ID='op://Personal/App Store Connect API Key/issuer id'
export ASC_KEY_OP_REF='op://Personal/App Store Connect API Key/AuthKey_XXXXXXXXXX.p8'
```

Or export them yourself (explicit env vars always win over `ios/asc.env`); `ASC_KEY_PATH` points at a
local `.p8` instead of 1Password if you prefer. Store the key with the **App Manager** role.

**Usage**

This is **Plan B** for the Xcode Cloud **"Release"** workflow, which archives + distributes from
`release/*` branches. The local lane keys off the same branches, so releasing is identical either way:

```sh
# 0. Cut the release branch from develop (the same trigger the Xcode Cloud Release workflow uses).
git checkout develop && git pull
git checkout -b release/<tag_description>

# 1. Always rehearse first — fully offline: no network, no 1Password read, no JWT.
./scripts/deliver.sh deliver --dry-run --build-number <n>

# 2. (Optional) Validate the archive against App Store Connect WITHOUT uploading — like Xcode's
#    "Validate App". `deliver` also does this automatically right before uploading.
./scripts/deliver.sh validate

# 3. Archive → validate → upload to TestFlight (build number auto-resolves to App Store Connect max + 1).
./scripts/deliver.sh deliver

# 4. After the build finishes processing, push the tester notes from ios/TestFlight/WhatToTest.en-US.txt.
./scripts/deliver.sh notes --build-number <n>        # <n> is echoed by step 3

# Offline crypto + redaction self-tests (no credentials needed):
./scripts/deliver.sh selftest
```

**Notes**

- **Release branch required:** `deliver` / `validate` refuse to run unless you're on a `release/*`
  branch (mirroring the Xcode Cloud Release workflow) or you pass an explicit `--ref <tag|sha>` that
  matches `HEAD`. This keeps the local lane shipping the same commits Xcode Cloud would.
- **Pre-upload validation:** `deliver` validates the archive against App Store Connect (icons,
  entitlements, Info.plist keys, provisioning, architectures) *before* uploading — the CLI equivalent
  of Xcode Organizer's "Validate App" — and aborts on failure. `--skip-validate` bypasses it; the
  standalone `validate` subcommand runs the check without uploading. Validation uses `xcrun altool`
  (deprecated but the only CLI that validates pre-upload); the upload itself uses `xcodebuild` and is
  independent of it, so `--skip-validate` keeps you shipping if `altool` is ever removed.
- `--build-number` selection (`max + 1`) is **not atomic**. `deliver` re-checks the number against
  App Store Connect right before uploading (and aborts if it was taken meanwhile), which shrinks but
  does not eliminate the race — two operators archiving simultaneously can still collide. For a
  guaranteed-unique number, coordinate out of band and pass an explicit `--build-number`. (A shared
  atomic reservation is intentionally out of scope for this single-operator break-glass lane.)
- `--export-only` writes a signed `.ipa` under `build/delivery/export/` instead of uploading; upload it
  manually with `xcrun altool --upload-app -f <ipa> --apiKey <id> --apiIssuer <issuer>` (key in
  `~/.appstoreconnect/private_keys/`).
- Outputs land under `build/delivery/` (gitignored). dSYMs are uploaded to **Sentry** by the archive's
  own "Upload Debug Symbols to Sentry" build phase (during archiving) and to **App Store Connect** by
  the export step (`uploadSymbols=true` in `ExportOptions.plist`); the script adds no separate dSYM
  upload of its own.
- The live archive/upload/notes paths are **exercised by the operator** — validate the script logic
  first with `deliver --dry-run` and `selftest`.

## Feature flags & observability

Three different tools answer three different questions. Mixing them up is the most common
mistake here:

| Tool | Answers | Status |
|-|-|-|
| **ConfigCat** | *Should this feature be on?* — remote feature flags, flippable without an App Store release | **live** — see [FEATUREFLAGS.md](FEATUREFLAGS.md) |
| **Sentry** | *Did something break?* — crashes, errors, diagnostics | live — see [LOGGING_GUIDE.md](LOGGING_GUIDE.md) |
| **TelemetryDeck** | *Is the feature used?* — product analytics (DAU/MAU, retention, funnels) | **designed, not implemented** — see [ANALYTICS.md](ANALYTICS.md) |

Sentry is **not** product analytics and does not overlap TelemetryDeck. Neither measures
battery or performance attribution — that's Xcode Organizer / MetricKit / Sentry profiling.

**Feature flags in one minute.** `FeatureFlagKey` (in
`ios/MLBrowser/iOS/State/FeatureFlags.swift`) holds each flag's ConfigCat key and its
compiled default. Values resolve through a ConfigCat adapter and are published by
`FeatureFlagsState`. Two things to internalise before touching them:

- **They fail open.** Defaults are `true`, so offline / bad key / outage leaves a "killed"
  feature **on**. This is not a guaranteed remote kill switch.
- **Not every flag may apply live.** `isPaymentsEnabled` is captured once at launch, because
  `SubscriptionGateView` is the app root — a mid-session flip would drop a paywall on a user
  who is mid-detection. `isModelCatalogEnabled` applies live.

Keys live in 1Password (`ConfigCat Keys`); Debug builds use the ConfigCat **Test**
environment, Release uses **Production**. Tests and previews never touch the network.

## Conventions

- **Branches**: `feature/…`, `fix/…`, `doc/…`, `test/…` with a short kebab-case description; pull requests target `develop`. Never commit directly to `develop` or `main`.
- **Commits**: imperative summary prefixed with the issue key — `[AIA-XXXX] Fix crash when…`.
- **Issues**: GitHub Issues carry `AIA-####` keys (normalized automatically by the `auto-issue-key` workflow); production crashes arrive as issues via Sentry → Cloudflare relay.
- **Core Data model version**: production ships **0.0.0** (`ios/…/MLBrowser.xcdatamodeld/MLBrowser.xcdatamodel`). `develop` has advanced to **0.0.1** (adds `Finding`/`WebVisit`, etc.) but that schema is **unreleased** — every store in the wild is 0.0.0, so migrations are authored and tested from 0.0.0 (see `FindingMigrationTests`). Don't treat 0.0.1 as a released schema.

## Further reading

| Document | What it covers |
|-|-|
| [ios/AGENTS.md](ios/AGENTS.md) | Engineering guidelines: architecture & state patterns, concurrency, testing strategy, quality gates, code-review bar. **Read this before contributing code** (it applies to humans, not just AI agents) |
| [ios/ARCHITECTURE.md](ios/ARCHITECTURE.md) | Codebase map: layering, composition root, app entry & gating, the detection pipeline, persistence |
| [ios/MLBrowser/README.md](ios/MLBrowser/README.md) | Project setup, `ProjectTool` reference, pinned tools, secrets via 1Password, Xcode Cloud notes |
| [FEATUREFLAGS.md](FEATUREFLAGS.md) | Remote feature flags (ConfigCat): the current flags, live vs launch-only application, fail-open limits, environments, and how to add a flag |
| [ANALYTICS.md](ANALYTICS.md) | Product analytics (TelemetryDeck) — **designed, not yet implemented**: event set, the notice-before-gates requirement, and what is/isn't collected |
| [LOGGING_GUIDE.md](LOGGING_GUIDE.md) | OSLog categories, log levels, privacy annotations, Sentry breadcrumb/quota policy |
| [cloudflare/README.md](cloudflare/README.md) | Sentry → GitHub Issues relay worker: architecture, setup, configuration |
