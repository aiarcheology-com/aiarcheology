# Security policy

## Reporting a vulnerability

Report privately through GitHub:
<https://github.com/aiarcheology-com/aiarcheology/security/advisories/new>

That draft advisory is visible only to the repository maintainers. **Please do not open a public
issue for a security problem**, and please do not include a working exploit in the first report —
describe the class of problem and how to reach it, and we will ask for more if we need it.

Tell us what you can of: affected app version, platform and OS version, the steps that reach the
problem, and what an attacker gets out of it. A first response should come within a week.

## What is in scope

This repository is an iOS application, a Swift package that converts models on-device, and two
Cloudflare Workers: `cloudflare/findings-worker`, the authenticated backend that stores saved
findings and their images in R2/D1 under a per-account quota, and a small relay that turns Sentry
issues into GitHub issues.

The things most worth your attention:

- **Anything that gets a transient page snapshot off the device.** Detection runs on-device by
  design and those snapshots are never uploaded. A path that breaks that is the highest-severity
  finding this project can have. Saved findings are different: they may sync or be shared with the
  user's authorisation — the bug there would be doing it *without* that authorisation.
- **Anything that lets one account reach another account's findings**, locally or through
  `findings-worker` — including a quota or ownership check that can be bypassed.
- **Model loading.** The app loads user-supplied Core ML and ONNX models. Memory-safety or
  resource-exhaustion problems reachable from a malicious model file are in scope.
- **The Worker's request handling** under `cloudflare/findings-worker/`.

Out of scope: anything requiring a jailbroken device or a physically unlocked device you already
control; findings against third-party services we merely use; and reports produced solely by an
automated scanner with no demonstrated impact.

## Credentials in this repository

**None of the values in the tracked configuration files are live secrets.** `ios/Secrets.xcconfig`
is generated locally and is gitignored; the tracked `ios/Secrets.template.xcconfig` holds 1Password
references, not values.

One credential did reach a public commit historically: the **Sentry DSN**, added in `2d0d3638` and
removed in `8738cc7e`. **It has been rotated**: a new client key was issued and is what current
builds carry. The old key stays enabled alongside it until 1.0.9 ships, because every copy of
1.0.8 already in the field has the old DSN compiled in and would otherwise stop reporting crashes.

Note what a Sentry DSN is, so the severity is neither overstated nor understated: it is a
write-only ingest endpoint that ships inside every copy of the application binary, so it is not
confidential in the first place, and the ceiling on abuse is sending junk events. It was rotated
regardless.

If you find any other credential in the history, please report it through the private channel above
rather than opening an issue.

## Supported versions

Security fixes go to the current App Store release. There is no long-term support branch.
