# 📱 MLBrowser iOS App — setup & tooling reference

This document covers first-time project setup, the `ProjectTool` CLI, pinned
developer tools, helper scripts, and secrets management. For what the app is
and an overview of the repository, see the [root README](../../README.md). For suite selection,
commands, fixtures, and test-result interpretation, see [TESTING.md](../../TESTING.md).

## 🛠️ Initial project setup (required)

From the repository root:

```bash
swift run --package-path Tools ProjectTool setup
```

This installs required tools and configures git. Tools go to `/usr/local/bin` when it is
writable, otherwise to `~/.local/bin`, which `ProjectTool` creates and then reminds you to put on
your `PATH`. Never run it under `sudo` — that leaves root-owned artefacts in `Tools/.build`.

You also need `ios/Secrets.xcconfig` before anything will build — it is the
`baseConfigurationReference` for both configurations. **Without the project's
1Password vault**, write it by hand with empty values: see
[Building without the project vault](../../README.md#building-without-the-project-vault)
in the root README. The rest of this document assumes you have the vault.

Then open the project:

```bash
open ios/MLBrowser.xcworkspace
```

## 📦 Required Tools

Tool versions are **strictly pinned** in `.tools.json` at the repository root. This ensures identical tooling across all developers and CI by downloading exact versions from GitHub releases.

| Tool | Purpose |
|------|---------|
| `swiftlint` | Swift code linting (pre-commit hook) |
| `swiftgen` | Localization code generation |
| `sentry-cli` | Sentry dSYM upload and release management |

To check and install tools:

```bash
swift run --package-path Tools ProjectTool setup
```

Tools are installed to `~/.local/bin` or `/usr/local/bin` (if writable).

## 🧰 ProjectTool (all available commands)

`ProjectTool` is a SwiftPM CLI located in `Tools/`. It's used for repo setup and secret management.

### How to run

From the repository root:

```bash
swift run --package-path Tools ProjectTool <command>
```

To see the built-in help (recommended):

```bash
swift run --package-path Tools ProjectTool --help
swift run --package-path Tools ProjectTool <command> --help
```

### `setup` — project setup and git configuration

```bash
swift run --package-path Tools ProjectTool setup
```

What it does:
1. **Installs required tools** from `.tools.json`:
   - Checks if tools are installed and verifies versions
   - Downloads and installs exact pinned versions from GitHub releases
   - Tools are installed to `~/.local/bin` or `/usr/local/bin` (if writable)
   - Bundled tools (like SwiftGen) are installed to `~/.local/lib/<tool>/`

2. **Configures git** (skipped in CI environments):
   - Marks the CoreData model contents file as "assume unchanged" to prevent noisy diffs
   - Configures git to use `.githooks/` for hooks (enables SwiftLint pre-commit and String Catalog
     build-stability pre-push validation)

3. **Optional: Directory aliases** (skipped in CI environments):
   - Prompts to enable short command aliases via [direnv](https://direnv.net/)
   - If enabled, installs direnv (via Homebrew) if needed
   - Available aliases: `setup`, `lint`, `gen`, `harm`

If you ever need to undo the git configuration manually:

```bash
# Re-enable tracking for CoreData model
git update-index --no-assume-unchanged ios/MLBrowser/iOS/Persistence/MLBrowser.xcdatamodeld/MLBrowser.xcdatamodel/contents

# Reset hooks path to default
git config --unset core.hooksPath
```

### `cleanup` — remove SwiftPM build artifacts (local)

```bash
swift run --package-path Tools ProjectTool cleanup
```

What it does:
- Removes `./.build` (relative to your current working directory). Run it from the repository root.

## Build caches

Preserve compatible incremental products between tasks. `scripts/unittest.sh` defaults to the
repository's `.deriveddata` and accepts `DERIVED_DATA_PATH`; the catalog-stability script defaults
to `.deriveddata-localization` and also accepts `DERIVED_DATA_PATH`. The unit and Harmonize wrappers
accept `SPM_CACHE_PATH` for cloned packages. Serialize builds using the same artifact directories.

If a build reports a stale/missing module or XCFramework, first check the selected Xcode, SDK,
dependency resolution, destination, and whether another build shares its artifacts. Retry with a
separate DerivedData path to isolate the fault. A fresh path must complete a successful build before
its test products can be used; `test-without-building` cannot repair a failed build.

Invalidate the affected cache only for incompatible inputs or demonstrated corruption. Prune known
unused caches by age/size or under storage pressure, after checking that no active build uses them.
Do not automatically delete `.deriveddata*`, `ios/.deriveddata*`, or `.build` when finishing a ticket.
The explicit `ProjectTool cleanup` command above remains available when its scope is appropriate.

The root and iOS SwiftLint configurations exclude ordinary `.deriveddata` paths, but do not assume
every custom cache suffix is excluded. If generated/vendor files enter lint scope, diagnose the
configuration/path and propose a focused exclusion; cache deletion is not a durable lint fix.

## 📜 Scripts

Helper scripts are located in `scripts/` at the repository root.

| Script | Purpose | Alias |
|--------|---------|-------|
| `./scripts/swiftlint.sh` | Run SwiftLint (`fix` to autocorrect) | `aiaswiftlint` |
| `./scripts/swiftgen.sh generate` | Generate L10n.swift from xcstrings | `aiaswiftgen` |
| `./scripts/localization.sh` | Check every string exists in all 16 locales | `aialocalization` |
| `./scripts/check_localization_build.sh` | Build locally and verify Xcode leaves String Catalogs unchanged | — |
| `./scripts/harmonize.sh` | Run architectural tests | `aiaharmonize` |
| `./scripts/unittest.sh` | Run unit tests | `aiaunittests` |

If you enabled directory aliases during setup, you can use the short commands directly.

### Directory aliases via direnv

During `setup`, you'll be prompted to enable short command aliases. If enabled:

1. **direnv** is installed via Homebrew (if not already present)
2. A `.envrc` file is created from `.envrc.template`
3. `direnv allow` is run to trust the file

**Available aliases:**

| Alias | Expands to |
|-------|------------|
| `aiasetup` | `swift run --package-path Tools ProjectTool setup` |
| `aiaswiftlint` | `./scripts/swiftlint.sh` |
| `aiaswiftgen` | `./scripts/swiftgen.sh generate` |
| `aialocalization` | `./scripts/localization.sh` |
| `aiaharmonize` | `./scripts/harmonize.sh` |
| `aiaunittests` | `./scripts/unittest.sh` |
| `aiapipeline` | `aiaswiftgen && aiaswiftlint && aialocalization && aiaharmonize && aiaunittests` |

The `.envrc` file is gitignored (local preference). When you `cd` into the project directory, direnv automatically loads the aliases. When you leave, they're unloaded.

**One-time shell setup** (add to `~/.zshrc`):
```bash
eval "$(direnv hook zsh)"
```

**To re-enable aliases later** (if you skipped during setup):
```bash
cp .envrc.template .envrc
direnv allow
```

## 🔐 Secrets management (local) via 1Password

> **Maintainers only.** This section describes the vault-backed workflow. Contributors without the
> project vault should follow
> [Building without the project vault](../../README.md#building-without-the-project-vault)
> instead, and should not need `secrets generate` or `secrets refresh`. Neither will damage a
> hand-written `Secrets.xcconfig`: `generate` is a no-op when the file already exists, and `refresh`
> fails on the `op` lookup before it writes anything.

Secrets are stored in 1Password and injected into local config files. Template files are committed; generated files are gitignored.

### Prerequisites

- **1Password CLI** (`op`) installed
- You are signed in (e.g. `op signin`)

### Files

- **Templates (committed)**
  - `ios/Secrets.template.xcconfig`
  - `ios/.sentryclirc.template`
- **Generated (gitignored)**
  - `ios/Secrets.xcconfig`
  - `ios/.sentryclirc`

### `secrets` (default) / `secrets validate` — check required files exist

```bash
swift run --package-path Tools ProjectTool secrets
```

or:

```bash
swift run --package-path Tools ProjectTool secrets validate
```

### `secrets generate` — first-time generation (only if missing)

```bash
swift run --package-path Tools ProjectTool secrets generate
```

### `secrets refresh` — force re-generate all secrets

```bash
swift run --package-path Tools ProjectTool secrets refresh
```

### `secrets clean` — remove generated secrets

```bash
swift run --package-path Tools ProjectTool secrets clean
```

## 🤖 CI note (Xcode Cloud)

`ProjectTool secrets ...` intentionally **skips** work in CI environments.

In Xcode Cloud, secrets are injected via environment variables in:
- `ios/ci_scripts/ci_pre_xcodebuild.sh`

For release preparation, follow the [delivery reference](../../README.md#-emergency-delivery-lane-xcode-cloud-fallback).
Preserve the existing `ITSAppUsesNonExemptEncryption` metadata in `MLBrowser-Info.plist`; omitting
it can leave a TestFlight build waiting for export-compliance information. Upload tester notes
only after App Store Connect finishes processing the selected build.

## 💳 Testing purchases (AIA-0376)

The `MLBrowser` scheme runs against the local `ios/MLBrowser/Configuration.storekit`, so
purchases are simulated and never charge anything.

⚠️ **Purchases do not verify on "My Mac (Designed for iPad)".** Xcode's StoreKit Testing
certificate is not trusted by macOS by default, so the purchase sheet completes, StoreKit
returns a transaction that fails verification, `verified()` correctly rejects it, and the app
reports a failed purchase. This is the environment, not a bug.

Use the **iOS Simulator** or **TestFlight** instead, where verification works. If you must
test on My Mac, trust the StoreKit Testing certificate first:

```
Xcode ▸ Settings ▸ (with the app running) Debug ▸ StoreKit ▸ Enable StoreKit Testing certificate
```

then verify it appears as trusted in Keychain Access.

**What each store environment gives you:**

| Where | Store | Charges? |
|-|-|-|
| Simulator / device (Debug) | local `Configuration.storekit` | no |
| My Mac (Designed for iPad) | local `.storekit` — ⚠️ **verification fails** unless the cert is trusted | no |
| TestFlight | Apple **Sandbox** | no |
| App Store | production | **yes** |

To exercise the failure and Ask-to-Buy branches without StoreKit at all, set
`MockSubscriptionProvider.purchaseOutcome` / `.restoreOutcome` — see `SubscriptionNoticeTests`.

### Refunds (AIA-0448 → affordance removed by AIA-0455)

**The app has no in-app refund entry point, and adding one back is a decision, not a fix.** Apple
mandates none: Guideline 3.1.2's in-app disclosure list is a closed set that does not contain one,
and `beginRefundRequest` is documented in purely optional capability language. Refunds are
administered by Apple through reportaproblem.apple.com, the "Report a Problem" link in the receipt
email, and Apple Support — all reachable without the app.

It was removed because it could not be made to work on iOS-on-Mac: every push signal about the
refund sheet died in the remote→host bridge (`onDismiss` never fired, no scene notification
arrived) and the orphaned presentation blocked all input. A Mac-only polling watchdog papered over
it and never closed it. Keeping the control on iPhone and iPad alone would have broken
cross-platform parity, so it went everywhere.

**A granted refund still reaches the app**, and that path is fully covered: it arrives as a
revocation on the transaction via `Transaction.updates`, `EntitlementResolver` refuses a revoked
candidate, the entitlement drops and the paywall rises. To exercise it, issue the refund from
**Debug ▸ StoreKit ▸ Manage Transactions…**, or in Sandbox from the App Store account tools. The
app correctly follows *approval*, never submission — in production Apple decides within ~48h and
emails the customer.
