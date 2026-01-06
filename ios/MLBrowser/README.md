# 📱 MLBrowser iOS App

This repository contains the MLBrowser iOS app and its supporting tooling.

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
| `./scripts/harmonize.sh` | Run architectural tests | `aiaharmonize` |

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
| `aiaharmonize` | `./scripts/harmonize.sh` |
| `aiapipeline` | `aiaswiftgen && aiaswiftlint && aiaharmonize` |

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
