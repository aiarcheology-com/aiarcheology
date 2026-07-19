# ML Browser

ML Browser is an iOS app that combines a web browser with on-device machine learning: the user loads an object-detection or image-classification model — Core ML directly, or ONNX converted on the device itself — and Vision runs it against snapshots of the rendered page on a configurable timer, drawing the detections directly over the web content. No images leave the device.

The flagship use case — and where the name comes from — is archeology: browsing LIDAR / terrain-map sites with the bundled demo models to spot features such as burial mounds. But the app is model-agnostic; any imported detection model works the same way on any web content.

<p align="center">
  <img src="ExampleScreenshot.jpg" alt="AI Archeology example">
</p>

## Repository layout

| Path | Contents |
|-|-|
| `ios/` | The Xcode workspace (`MLBrowser.xcworkspace`), app sources, unit/UI/architecture tests, test plans, and Xcode Cloud `ci_scripts/` |
| `Package.swift`, `Sources/NativeModelConverter/` | `NativeModelConverter` Swift package: a native `.aiagraph` → Core ML converter used by the iOS app. |
| `Tools/` | `ProjectTool` — a SwiftPM CLI for repo setup, pinned-tool installation, and secrets management |
| `scripts/` | Developer scripts: lint, codegen, architectural tests, unit tests |
| `cloudflare/` | Cloudflare Worker relaying Sentry issues into GitHub Issues ([details](cloudflare/README.md)) |
| `.github/workflows/` | CI: SwiftLint, Harmonize (architecture tests), issue-key automation |
| `.githooks/` | Git hooks (SwiftLint pre-commit), enabled by `ProjectTool setup` |
| `.tools.json` | Pinned versions of swiftlint / swiftgen / sentry-cli used by all developers and CI |

## Supported model formats

Core ML models load directly. ONNX models are converted **on the device** by the bundled
`NativeModelConverter` — no Python, no server, no `coremltools`. Import from Files, or paste a URL
into the importer's **Download from URL** field.

| Format | Task | Handling |
|-|-|-|
| `.mlmodel`, `.mlpackage`, `.mlmodelc` | Detection, classification | Loaded directly |
| `.onnx` | Image classification | Converted on-device. When the output width matches ImageNet-1k, the ImageNet labels and RGB normalization are applied and the model runs as a Core ML classifier |
| `.onnx` | Object detection — raw-grid YOLOv2-family heads | Converted on-device into a Core ML *pipeline* model (single file): the converted network plus a synthesized box decode, followed by Core ML's built-in non-maximum suppression. Vision then returns standard `VNRecognizedObjectObservation`s |
| `.onnx` | Object detection — anchor-free raw exports (YOLOv5/v8, `nms=False`) | **Graph converts; detector interface not wired yet.** The whole trunk lowers and matches an onnxruntime oracle numerically, but no catalog entry claims the `[1, 84, N]` head, so the model imports as a plain network — disabled and flagged for review, producing no detections. Boxes arrive with the detector-head work |
| `.onnx` | Detection with embedded post-processing (`NonMaxSuppression`, `Loop`, dynamic shapes) — SSD, tiny-yolov3, ssd-mobilenet | Rejected with a precise diagnostic naming the unsupported operator |
| `.aiagraph` | — | Internal interchange package (versioned, SHA-256 pinned); not a format users are expected to author |
| `.tflite` | — | Not supported yet |

A converted detector is **one `.mlmodel` file**, exactly like a converted classifier. "Pipeline"
describes its internal structure — Apple's own detector exports (Create ML, Turi Create,
coremltools) and this repo's bundled demo detectors have the same two-stage shape — because a static
neural network cannot express suppression, whose output row count depends on the input.

### Conversion parity evidence

Each model below converts on-device and reproduces the predictions of an independent
**onnxruntime** oracle; see [NATIVE_MODEL_CONVERSION.md](NATIVE_MODEL_CONVERSION.md) and
`Tests/NativeModelConverterTests/Fixtures/ONNXConversionModels.json`.

| Model | Task | Asserted against the oracle |
|-|-|-|
| MobileNetV2 | Classification | Top-1 label per probe |
| ResNet-50 | Classification | Top-1 label per probe |
| SqueezeNet 1.0 | Classification | Top-1 label and probability |
| Tiny YOLOv2 (Pascal VOC) | Detection | Box count, IoU ≥ 0.9 per box, class label, confidence |
| YOLOv8n (raw export, 640×640) | Detection trunk | Raw `[1, 84, 8400]` output at 507 sampled positions, abs tolerance 0.002 |

### ONNX operator coverage

| Operator | Accepted forms |
|-|-|
| `Conv` | Including `auto_pad` SAME_UPPER/VALID and asymmetric padding |
| `BatchNormalization`, `Gemm` | `Gemm` requires the standard `y = xWᵀ + b` form (`transB=1`, unit alpha/beta) |
| `Relu`, `LeakyRelu`, `Sigmoid`, `Clip` | `Clip` maps to ReLU6 only at exactly `[0, 6]` |
| `Add`, `Mul`, `Sub`, `Div` | Same-shape activations, or a constant operand — scalar, per-channel, or a spatial table expanded statically. `Sub` lowers to an add (Core ML has no subtract); `Div` accepts a constant divisor only, as a multiply by its reciprocal |
| `MaxPool`, `GlobalAveragePool` | Dense, non-dilated pooling |
| `Concat` | Channel axis at rank 3–4; the rank-3 axis-2 form is rewritten as transpose → channel concat → transpose |
| `Slice` | Single-axis **channel** slices (static bounds, unit step) |
| `Reshape`, `Flatten` | Static targets with `-1` inferred; a `[batch, features]` collapse stays a flatten so classifier interfaces are preserved |
| `Transpose` | Explicit `perm` at rank 3–4 (the reverse-all-axes default is rejected) |
| `Resize` | Nearest + `asymmetric` + `floor` + integer scale factors only — the one configuration Core ML's upsample reproduces exactly |
| `Softmax` | Opset-aware axis semantics; the channel axis under Core ML's legacy rank-5 layout |
| `Dropout`, `Identity`, `Shape`, `Constant`, `ConstantOfShape` | Folded away |

Anything outside this set is rejected rather than approximated: a model that converts is expected to
match its source, and one that cannot is expected to say why. The restrictions above are enforced,
not documented aspirationally — e.g. a `half_pixel` `Resize` or a two-activation `Div` fails with a
diagnostic instead of converting to something that merely compiles.

## NativeModelConverter Swift package

`NativeModelConverter` is a local Swift Package Manager dependency for ML Browser. It reads a
standard `.onnx` file, or a versioned `.aiagraph` directory, and emits a Core ML `.mlmodel` entirely
in native Swift—no Python is bundled with, or invoked by, the iOS app. See
[Supported model formats](#supported-model-formats) for what converts today.

| Item | Value |
| --- | --- |
| Library product | `NativeModelConverter` |
| Supported platforms | iOS 17+, macOS 14+ |
| App use | An `.onnx` or `.aiagraph` import journals a path-free conversion report, validates/writes `converted.mlmodel` off the main actor, then uses the existing Core ML loading path. Interrupted imports can resume or be explicitly discarded; a registered conversion can be explicitly exported as a metadata-preserving ZIP. |
| Development CLIs | `native-model-converter` converts one package; `native-model-evaluator` runs an emitted model through Core ML for terminal parity tests. |
| Format version | Native graph package v1; graph, weights, and optional source metadata are SHA-256 pinned. Converted source metadata is retained as `converted.metadata.json`; the app retains a path-free `native-conversion-report.json` with lifecycle and support evidence. |
| Converter provenance | Source package filename, original filename/remote URL when known, source exporter name/version, graph format, Swift package SemVer, conversion revision, interface, and artifact hashes are embedded in the generated `.mlmodel`; version history remains traceable after the app converter evolves. |
| Client observability | `NativeModelConverter.convert` reports package/emission progress, process-memory samples, cancellation, stable diagnostics, artifact sizes, and monotonic timings; it also emits OSLog signposts for Instruments. A process-global FIFO gate runs one high-level conversion at a time and reports `waitingForExclusiveAccess` to queued jobs. |

### Apple platform scope

| Distribution / target | Support | Evidence and boundary |
| --- | --- | --- |
| iPhone and iPad | iOS 17+ | `Package.swift` declares `.iOS(.v17)`; this is the ML Browser app target. |
| Mac, Designed for iPad | iOS 17+ compatibility runtime | It runs the iOS app/package slice, so the iOS 17 deployment target applies. |
| Native macOS app | macOS 14+ | `Package.swift` declares `.macOS(.v14)`; terminal compile/evaluation tests run on this target. |
| watchOS, tvOS, visionOS, Mac Catalyst | Not supported/claimed yet | No platform declaration or test evidence exists in this package. |

The package is already registered in `ios/MLBrowser.xcodeproj` as a local package reference. To add
it to another target in Xcode, choose **File → Add Package Dependencies… → Add Local…**, select this
repository root, and add the `NativeModelConverter` library product to that target. `.onnx` files are
read directly by `ONNXModelReader`; other source formats must lower into the validated graph package
first.

The API guide is available in Xcode's documentation browser as **Native Model Converter**. The
format, supported operators, validation policy, test harness, and current parity evidence are
maintained in [NATIVE_MODEL_CONVERSION.md](NATIVE_MODEL_CONVERSION.md).

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

**Credentials** — an App Store Connect API key. This is a *delivery* credential: a private,
account-level key that can upload builds, read sales data and manage users. It is deliberately
**not** part of `Secrets.xcconfig` (which compiles build secrets into the app) and must never
become an input to the app build.

The recommended setup is to materialize it **once** from 1Password:

```sh
swift run --package-path Tools ProjectTool asc credentials generate
```

That resolves the `op://` references in `ios/asc.env` into the gitignored `ios/asc.auth/`
(directory `0700`; `AuthKey_<KEYID>.p8`, `key-id` and `issuer-id` each `0600`). `deliver.sh` reads
those files directly, so a delivery no longer depends on a live 1Password session at an arbitrary
moment during a long run — a session that expired mid-sweep used to discard ten minutes of work.

| Command | Effect |
|-|-|
| `asc credentials generate` | Resolve from 1Password if not already present |
| `asc credentials refresh` | Re-resolve, replacing the directory (use after key rotation) |
| `asc credentials status` | Report the materialized key id (never prints key material) |
| `asc credentials clean` | Remove the directory and the private key it holds |

Without `ios/asc.auth/`, `deliver.sh` still falls back to resolving the `op://` references on every
run, writing the key to a short-lived `0600` temp file wiped on exit. Explicit `ASC_*` environment
variables always win over both — `ASC_KEY_PATH` points at a `.p8` already on disk (keep it outside
the repo, `chmod 600`).

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
