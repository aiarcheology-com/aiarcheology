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

**Credentials** (env, or `op://` references the script resolves via 1Password):

```sh
export ASC_KEY_ID=XXXXXXXXXX
export ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
export ASC_KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8   # or ASC_KEY_OP_REF=op://Vault/ASC Key/.p8
```

**Usage**

```sh
# 0. Always rehearse first — fully offline: no network, no 1Password read, no JWT.
./scripts/deliver.sh deliver --dry-run --build-number <n>

# 1. (Optional) Validate the archive against App Store Connect WITHOUT uploading — like Xcode's
#    "Validate App". `deliver` also does this automatically right before uploading.
./scripts/deliver.sh validate

# 2. Archive → validate → upload to TestFlight (build number auto-resolves to App Store Connect max + 1).
./scripts/deliver.sh deliver

# 3. After the build finishes processing, push the tester notes from ios/TestFlight/WhatToTest.en-US.txt.
./scripts/deliver.sh notes --build-number <n>        # <n> is echoed by step 2

# Offline crypto + redaction self-tests (no credentials needed):
./scripts/deliver.sh selftest
```

**Notes**

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

## Conventions

- **Branches**: `feature/…`, `fix/…`, `doc/…`, `test/…` with a short kebab-case description; pull requests target `develop`. Never commit directly to `develop` or `main`.
- **Commits**: imperative summary prefixed with the issue key — `[AIA-XXXX] Fix crash when…`.
- **Issues**: GitHub Issues carry `AIA-####` keys (normalized automatically by the `auto-issue-key` workflow); production crashes arrive as issues via Sentry → Cloudflare relay.

## Further reading

| Document | What it covers |
|-|-|
| [ios/AGENTS.md](ios/AGENTS.md) | Engineering guidelines: architecture & state patterns, concurrency, testing strategy, quality gates, code-review bar. **Read this before contributing code** (it applies to humans, not just AI agents) |
| [ios/ARCHITECTURE.md](ios/ARCHITECTURE.md) | Codebase map: layering, composition root, app entry & gating, the detection pipeline, persistence |
| [ios/MLBrowser/README.md](ios/MLBrowser/README.md) | Project setup, `ProjectTool` reference, pinned tools, secrets via 1Password, Xcode Cloud notes |
| [LOGGING_GUIDE.md](LOGGING_GUIDE.md) | OSLog categories, log levels, privacy annotations, Sentry breadcrumb/quota policy |
| [cloudflare/README.md](cloudflare/README.md) | Sentry → GitHub Issues relay worker: architecture, setup, configuration |
