# Contributing to ML Browser

Thanks for taking an interest. This file covers the mechanics; the architecture and the reasoning
behind the rules live in the documents it links to.

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md). Security problems go
through the [security policy](SECURITY.md), **not** a public issue.

## Before you write code

**Open an issue first** for anything beyond a typo or an obviously-correct one-line fix. It is
cheaper for both of us to disagree about an approach in an issue than in a finished branch. Say
what you intend to change and why; if you already know how, say that too.

Issues are titled `AIA-XXXX: <summary>`. The number is assigned automatically — open the issue with
a plain title and a workflow normalises it.

## Getting the project building

Start at the [README](../README.md#getting-started). It covers the two paths:

- **With the project's 1Password vault** — maintainers only.
- **Without it** — the [contributor setup](../README.md#building-without-the-project-vault), which
  is the path you want. The app builds and runs on the simulator with no accounts and no vault;
  that section lists exactly which features degrade and how.

You need macOS with Xcode 26.x and an iPhone simulator runtime. Everything else is installed by
`swift run --package-path Tools ProjectTool setup`.

## Licensing of what you contribute

The **source code** is Apache-2.0 (see [LICENSE](../LICENSE)); contributions are made under the
same terms. You must have the right to contribute what you submit — if your employer owns your
work, get their sign-off first.

The two first-party detectors in `ios/MLBrowser/iOS/Drivers/Demo Models/` (`AIArcheology`,
`HroudaDetector15`) are **Apache-2.0 like the code** — trained from scratch by this project, with no
ADAF lineage, so nothing propagates into work built on them. `FastViTT8F16` is a test fixture,
not an app demo; it is downloaded into a gitignored cache only for tests. It is
**Apple's** and covered by its custom licence, which permits redistribution subject to retaining
its required notices. It is not relicensed under Apache-2.0.
See
[the demo licence](../ios/MLBrowser/iOS/Drivers/Demo%20Models/LICENSE.md),
[the Apple fixture licence](../ios/TestFixtures/FastViT/LICENSE.md), and the root
[NOTICE](../NOTICE), which records every asset that sits outside the repository licence.

## Branches and commits

Branch from `develop`, never from `main`:

```
<type>/AIA-XXXX/short-description        # type ∈ feature | fix | doc | test
```

Commit subjects are imperative and carry the issue key:

```
[AIA-XXXX] Refuse an oversized Core ML load instead of being killed by it
```

Use the body to explain *why*, and to record any tradeoff a reviewer would otherwise have to
reconstruct. Keep a change traceable to its issue — if you spot something unrelated on the way,
mention it rather than fixing it in the same branch.

Normal pull requests target **`develop`**. Note that GitHub's `Closes #NNN` keyword does not fire on a
merge into `develop`, because it is not the default branch — the issue is closed by hand.

For release promotion, cut a disposable `release/*` branch (for example, `release/1.0.8`) from
`develop` and open its PR into **`main`**. Never use `develop` as a PR source (head): automatic
head-branch deletion can remove it when an administrator bypasses deletion protection. Keep
automatic branch deletion enabled so merged feature and release branches are cleaned up.
Pushing `release/*` triggers paid Xcode Cloud work; follow the
[release delivery instructions](../README.md#-emergency-delivery-lane-xcode-cloud-fallback).

## Run the checks before you open the PR

All three from the repository root:

```bash
./scripts/swiftlint.sh        # lint
./scripts/harmonize.sh        # architecture tests
./scripts/unittest.sh         # unit suite on a simulator
```

`./scripts/fetch_apple_test_models.sh` downloads missing or corrupt FastViT test fixtures and
verifies their pinned hashes. Use `--verify` for an offline cache check. The first-party detectors
have no published upstream against which to verify their provenance.

[TESTING.md](../specification/TESTING.md) has the full picture, including the UI suite and how to run a subset.
A green local run is what makes a review worth someone's time; CI is paid, so please do not use it
as your first test run.

## What makes a reviewable pull request

- One concern per PR. A rename and a behaviour change in one diff are much harder to review than
  two PRs.
- Tests that would fail without your change. A test that passes both before and after is not
  evidence.
- Updated comments and docs wherever you changed behaviour, names, or wiring — a stale comment
  asserting an invariant the code no longer has is worse than no comment.
- If the change is visible to testers, a line in
  [ios/TestFlight/WhatToTest.en-US.txt](../ios/TestFlight/WhatToTest.en-US.txt). Documentation,
  tooling and test-only work needs none.

Reviews come from maintainers and from automated reviewers. Disagreeing with a review comment is
fine — say why. "Done" with no change is not.

## Things that will be declined

- Reformatting or refactoring unrelated to a stated issue.
- New dependencies without a case for why the maintenance and security cost is worth it.
- Anything that uploads a **transient page snapshot**. Detection is on-device by design and those
  snapshots never leave it. Note this is not a blanket rule about images: a **saved finding** may
  leave the device through sharing or account-backed sync the user authorised. Preserve that
  distinction rather than removing it; see [AGENTS.md](../AGENTS.md#data-and-privacy).
- Changes that weaken App Transport Security, or that commit credentials of any kind.
