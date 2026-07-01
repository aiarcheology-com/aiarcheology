# Banned-diff guard

Run **before every commit and every push**, against the staged/pushing diff
(`git diff --cached` for commit; `git diff <remote>/<branch>..HEAD` for push).

Two tiers — keep them separate so the hard block stays trustworthy and auditable.

## Tier 1 — deterministic hard block (grep-detectable → STOP and ask)

If any added line (`^\+`, excluding the diff header) matches, halt and surface the exact match to
the human. These are string/file patterns with no judgment call:

- **App Transport Security weakening:**
  `NSAppTransportSecurity`, `NSAllowsArbitraryLoads`, `NSAllowsArbitraryLoadsInWebContent`,
  `NSExceptionAllowsInsecureHTTPLoads`, `NSExceptionDomains`
- **Secrets / credentials:**
  `-----BEGIN [A-Z ]*PRIVATE KEY-----`, `AKIA[0-9A-Z]{16}`,
  `(api[_-]?key|secret|client[_-]?secret|password|token)\s*[:=]\s*["'][^"']{12,}`,
  `xox[baprs]-`, `ghp_[0-9A-Za-z]{30,}`, `sk-[0-9A-Za-z]{20,}`
- **Signing / provisioning changes:**
  `CODE_SIGN_IDENTITY`, `PROVISIONING_PROFILE`, `DEVELOPMENT_TEAM`, `CODE_SIGN_STYLE`,
  `commit.gpgsign` in anything other than the documented locked-1Password fallback
- **Entitlements:** any `*.entitlements` file, `com.apple.developer.`, `aps-environment`,
  `keychain-access-groups`, `associated-domains`
- **Feature-flag flips:** changes to `FeatureFlags.swift` (e.g. `isPaymentsEnabled`) —
  flipping a flag to satisfy a test is exactly the failure mode this blocks
- **Auth-bypass tokens leaking to production:** `SIMCTL_CHILD_UI_TESTING`, `UI_TESTING`,
  `isRunningUITests`, `MockAuthProvider`, `MockSubscriptionProvider` appearing **outside**
  `#if DEBUG` / test targets / the DependencyContainer test-only path

On a match: **do not commit/push.** Write the finding to the state comment, show the human the
matched line + file, and ask. Never auto-resolve by reverting the guard.

## Tier 2 — semantic / intent (NOT grep-detectable → advisory P4 finding)

These need judgment, so they must **not** sit on the deterministic stop rail (non-deterministic
blocks make the hard guard untrustworthy). Raise them as a **P4 code-review finding for human
approval** instead:

- Test-only behavior conditionally reaching a production code path.
- Assertions relaxed / tests weakened to make a red suite pass.
- A "fix" that disables or short-circuits the feature rather than correcting it.
- Error handling that silently swallows a failure the test was catching.

## False-positive handling
A legitimate hit (e.g. the documented `git -c commit.gpgsign=false` 1Password fallback, or a
`UI_TESTING` reference inside a test target) is confirmed **once by the human per run** and recorded
in the state comment so the same known-good pattern isn't re-prompted every commit.
