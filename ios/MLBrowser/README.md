# 📱 MLBrowser iOS App — setup & tooling reference

This document covers first-time project setup, the `ProjectTool` CLI, pinned
developer tools, helper scripts, and secrets management. For what the app is
and an overview of the repository, see the [root README](../../README.md).

## 🛠️ Initial project setup (required)

From the repository root:

```bash
swift run --package-path Tools ProjectTool setup
```

This installs required tools and configures git.

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
   - Configures git to use `.githooks/` for hooks (enables SwiftLint pre-commit validation)

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

## 📜 Scripts

Helper scripts are located in `scripts/` at the repository root.

| Script | Purpose | Alias |
|--------|---------|-------|
| `./scripts/swiftlint.sh` | Run SwiftLint (`fix` to autocorrect) | `aiaswiftlint` |
| `./scripts/swiftgen.sh generate` | Generate L10n.swift from xcstrings | `aiaswiftgen` |
| `./scripts/localization.sh` | Check every string exists in all 16 locales | `aialocalization` |
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

### Refunds (AIA-0448)

Per Apple's [Testing refund requests](https://developer.apple.com/documentation/storekit/testing-refund-requests):
in **any testing environment** (local `.storekit` and Sandbox) submitting the refund sheet with
any reason **auto-approves immediately** — the revocation lands in `Transaction.updates`
(breadcrumb: `Transaction update: … revoked=true`), the entitlement drops, and the paywall
rises. To test a **declined** refund (Sandbox): choose *Other*, type `DECLINE`, submit. In
**production** Apple decides within ~48h and emails the customer; the revocation is the app's
only signal, so the paywall correctly follows *approval*, never submission.

⚠️ **iOS-on-Mac bridge loss (undocumented):** on "My Mac (Designed for iPad)" every push
signal about the refund sheet dies in the remote→host bridge — `onDismiss` never fires, no
scene notification arrives, and the orphaned presentation blocks all input. The workaround is
**pull-based and Mac-only** (`startRefundWatchdogOnMac`): a task started at the tap polls the
store every 2s; when the auto-approved revocation appears, the entitlement re-read raises the
paywall and the root swap tears down the stuck presentation (log: `Refund revocation detected
by polling…`; bounded at ~5 min). iPhone/iPad never start the watchdog — `onDismiss` works
there. Refunds can also be issued from **Debug ▸ StoreKit ▸ Manage Transactions…**.
