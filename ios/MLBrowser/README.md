# 📱 MLBrowser iOS App

This repository contains the MLBrowser iOS app and its supporting tooling.

## 🛠️ Initial project setup (required)

From the repository root:

```bash
swift run --package-path Tools ProjectTool setup
```

Then open the project:

```bash
open ios/MLBrowser.xcworkspace
```

## 🧰 ProjectTool (all available commands)

`ProjectTool` is a SwiftPM CLI located in `Tools/`. It’s used for repo setup and secret management.

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

### `setup` — post-clone git configuration

```bash
swift run --package-path Tools ProjectTool setup
```

What it does:
- **Marks the CoreData model contents file as “assume unchanged”** to prevent noisy diffs when Xcode rewrites it:
  - `ios/MLBrowser/iOS/Persistence/MLBrowser.xcdatamodeld/MLBrowser.xcdatamodel/contents`

If you ever need to undo this manually:

```bash
git update-index --no-assume-unchanged ios/MLBrowser/iOS/Persistence/MLBrowser.xcdatamodeld/MLBrowser.xcdatamodel/contents
```

### `cleanup` — remove SwiftPM build artifacts (local)

```bash
swift run --package-path Tools ProjectTool cleanup
```

What it does:
- Removes `./.build` (relative to your current working directory). Run it from the repository root.

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
