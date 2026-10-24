# Repository guidance

These rules apply throughout this repository. Follow the current user request over default
preferences here, and retain authorization already given in the session. Read applicable nested
instructions before changing their files; read [ios/AGENTS.md](ios/AGENTS.md) for app code,
resources, Xcode configuration, and iOS tests. Load references only when relevant.

## Find the relevant context

| Work | Read |
|-|-|
| App wiring and state | [ios/ARCHITECTURE.md](ios/ARCHITECTURE.md) |
| Tests, lint, fixtures, and verification | [TESTING.md](specification/TESTING.md) |
| Setup, tools, secrets, and build caches | [ios/MLBrowser/README.md](ios/MLBrowser/README.md) |
| Converter or root SwiftPM package | [NATIVE_MODEL_CONVERSION.md](specification/NATIVE_MODEL_CONVERSION.md) |
| Map URL/location capture | [MAP_LOCATION.md](specification/MAP_LOCATION.md) |
| Findings ownership, backup, deletion, formats | [USER_DATA_PERSISTENCE.md](specification/USER_DATA_PERSISTENCE.md) |
| Findings backend | [Worker README](cloudflare/findings-worker/README.md) and its provisioning rules |
| Logging, auth, flags, or messages | [LOGGING_GUIDE.md](specification/LOGGING_GUIDE.md), [AUTH-SUBSCRIPTION.md](specification/AUTH-SUBSCRIPTION.md), [FEATUREFLAGS.md](specification/FEATUREFLAGS.md), or [USERMESSAGING.md](specification/USERMESSAGING.md), as applicable |
| Release | [README release baseline](README.md#release-baseline) and [RELEASE_CHECK.md](specification/RELEASE_CHECK.md) |

## Scope and decisions

- Keep changes traceable to the request. Preserve unrelated work; mention adjacent findings
  instead of cleaning them up. Separate renames/refactors from behavior changes where practical.
- Resolve low-risk, reversible choices independently. State material assumptions; ask when a
  consequential requirement or permission cannot be inferred. Do not repeat an answered approval request.
- Prefer existing tools, patterns, and dependencies. Add abstractions for real boundaries or test
  seams. Reuse decisions only when their meaning and lifecycle match.
- Make domain decisions explicit through named states and outcomes, types that exclude invalid
  combinations, and exhaustive handling where practical. Distinguish rejection, deferral, and
  intentional inaction when their meanings differ. Keep independent decisions independent; do
  not add empty branches or enumerate irrelevant combinations merely to appear complete.
- Encode enforceable constraints in code and protect consequential behavior with meaningful tests.
  Preserve concise comments for rationale, external constraints, and tradeoffs that code and tests
  cannot explain. Avoid comments that merely restate the implementation; update rationale when
  its underlying decision changes. Exhaustive handling does not prove the domain model is complete.
- New repository tooling normally belongs in `Tools/ProjectTool`, with thin `scripts/*.sh`
  wrappers. Existing Python tools and ready-made libraries are appropriate when they avoid
  disproportionate implementation or maintenance cost. Do not rewrite tooling for a language preference.

## Data and privacy

- Detection runs on-device. Transient page snapshots must not be uploaded. Saved finding images
  may leave the device through authorized sharing or account-backed sync, subject to ownership,
  per-finding consent, and backup preferences. Never attach imagery to telemetry or diagnostic logs.
- Sign-in does not authorize another person's local findings. Preserve account and finding
  ownership checks across async work; see [USER_DATA_PERSISTENCE.md](specification/USER_DATA_PERSISTENCE.md).
- Never expose or commit secrets or private environment values. Validate external input and API
  responses. Keep generated credentials out of version control; use the project's setup tools.
- Do not select behavior by unstable runtime symbol names or reflected strings. Use explicit
  enums, tags, or callables; verify a release build if unavoidable introspection affects behavior.

## Verification

- For each updated revision, run checks for changed behavior and affected consumers, including
  fixtures, resources, configuration, and dependencies. Use broader coverage when impact is
  uncertain. Repeat checks when changed inputs invalidate the evidence.
- [TESTING.md](specification/TESTING.md) records current commands and selection limits. The selector in #850
  is planned, not available. Preserve existing required CI and release gates.
- Check successful builds, actual test execution, and fixture/platform requirements. Missing
  fixtures, zero-test selections, unexpected skips, or stale products do not establish a pass.
- Preserve compatible build caches. Invalidate selectively for incompatible inputs or demonstrated
  corruption; prune known unused caches for age/size or storage pressure. Never delete a cache
  used by an active build. See [cache troubleshooting](ios/MLBrowser/README.md#build-caches).
- Documentation-only changes need relevant link, command, and consistency checks; do not launch
  an app build solely to validate prose. This does not bypass existing hooks or required CI checks.

## Issues and Git

- Read the entire issue thread, including comments, before implementation.
- Every issue belongs to [AI Archeology, project #1](https://github.com/orgs/aiarcheology-com/projects/1).
  New issues start at **Todo**. Verify project status after changing it.
- Work a batch of issues serially unless told otherwise: finish one (merged, issue closed, board
  **Done**) before starting the next. Agents share the simulator, DerivedData, and `develop`.
- Use `AIA-XXXX: <summary>` issue titles. Branches are `<type>/AIA-XXXX/description`, with
  `feature`, `fix`, `doc`, or `test`. Commit summaries are imperative and prefixed `[AIA-XXXX]`
  (or multiple relevant keys). Explain material tradeoffs in the body.
- Never commit or push directly to `develop` or `main`. Never push without explicit user consent;
  consent already given in the session remains valid. Never force-push unless explicitly requested.
  Do not amend commits without asking or add co-author footers.
- Branch normal work from `develop` and target `develop` with its pull requests. Promote reviewed
  work to `main` through a disposable `release/*` branch cut from `develop`, with a PR into `main`.
  Never use `develop` as a PR source (head): automatic head-branch deletion can remove it when
  an administrator bypasses its deletion protection. Keep automatic branch deletion enabled.
  Pushing `release/*` triggers paid Xcode Cloud work; follow the release guidance below.
- Merge without passing CI only with the user's approval, following
  [merging without CI](specification/TESTING.md#merging-without-ci); never leave a ruleset disabled.
- Closing keywords do not auto-close issues merged into `develop`, the
  non-default branch. Close the issue and move its project status to **Done** after verified
  completion within the user's requested delivery scope; record any unmerged or local-only work.

## Review and delivery

- Scope code review to the requested diff against `develop` by default. Include affected consumers
  and integration boundaries when needed, and explain scope expansion. An explicit broader review
  request takes precedence. Lead with actionable findings and file/line references.
- Update directly affected comments/docs when behavior, names, or wiring change. App Store metadata
  and human visual acceptance are separate evidence; a local build cannot prove them.
- Update [TestFlight notes](ios/TestFlight/WhatToTest.en-US.txt) for tester-visible changes or
  meaningful testing impact. Documentation/tooling/test-only work with no tester action needs no
  invented notes. Describe one build with concrete steps, retain a `Build:` line, and stay within
  the existing 4,000-character gate.
- For releases, use [RELEASE_CHECK.md](specification/RELEASE_CHECK.md) and delivery instructions in [README.md](README.md).
  A pushed `release/*` branch triggers paid Xcode Cloud work. `deliver.sh` requires a release branch
  or an explicit ref matching HEAD; preserve this guard.
- Update the README's app/database release baseline when a version ships. Do not tick manual or
  external checks from reading code; report precisely what was and was not verified.
- Change persistent guidance when the user requests it or approves a proposed durable rule.
  Keep short rules here, procedures in linked references, and historical changes in Git history.
