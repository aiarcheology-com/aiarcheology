# AI Archeology

AI Archeology (app target **ML Browser**) is an iOS app that combines a web browser with on-device machine learning: the user loads any CoreML object-detection model (image classification is planned), and Vision runs it against snapshots of the rendered page on a configurable timer, drawing the detections directly over the web content. No images leave the device.

The flagship use case — and where the name comes from — is archeology: browsing LIDAR / terrain-map sites with the bundled demo models to spot features such as burial mounds. But the app is model-agnostic; any imported detection model works the same way on any web content.

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

## Conventions

- **Branches**: `feature/…`, `fix/…`, `doc/…`, `test/…` with a short kebab-case description; pull requests target `develop`. Never commit directly to `develop` or `main`.
- **Commits**: imperative summary prefixed with the issue key — `[AIA-XXXX] Fix crash when…`.
- **Issues**: GitHub Issues carry `AIA-####` keys (normalized automatically by the `auto-issue-key` workflow); production crashes arrive as issues via Sentry → Cloudflare relay.

## Further reading

| Document | What it covers |
|-|-|
| [ios/AGENTS.md](ios/AGENTS.md) | Engineering guidelines: architecture & state patterns, concurrency, testing strategy, quality gates, code-review bar. **Read this before contributing code** (it applies to humans, not just AI agents) |
| [ios/MLBrowser/README.md](ios/MLBrowser/README.md) | Project setup, `ProjectTool` reference, pinned tools, secrets via 1Password, Xcode Cloud notes |
| [LOGGING_GUIDE.md](LOGGING_GUIDE.md) | OSLog categories, log levels, privacy annotations, Sentry breadcrumb/quota policy |
| [cloudflare/README.md](cloudflare/README.md) | Sentry → GitHub Issues relay worker: architecture, setup, configuration |
