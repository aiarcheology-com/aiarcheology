# Demo model licences

The files in this directory are **not** covered by the repository's Apache-2.0 licence
(`/LICENSE`). Each has its own terms, set out below.

This file sits beside the `.mlpackage` bundles rather than inside them: an `.mlpackage` is a
directory described by its own `Manifest.json`, and the point of `scripts/fetch_demo_models.sh` is
to prove each one still matches Apple's published contents exactly — which a file added inside it
would defeat, whether or not Core ML happens to object.

## `AIArcheology.mlpackage`, `HroudaDetector15.mlpackage` — first-party weights

Copyright 2023-2026 AI Archeology. All rights reserved.

These are trained detector weights produced by this project. They are **not** licensed under
Apache-2.0.

**What you may do with them.** You are granted permission to use these files solely to build,
run, and test this project, including in a fork or a pull request. That permission exists so the
repository is usable as an open-source project — you can clone it and everything builds.

**What you may not do.** No other rights are granted. In particular there is no permission to
redistribute the weights on their own, to use them in another product, or to use them to train or
derive other models.

**Why this is not simply Apache-2.0.** The training-data and base-model provenance review for
these weights is not finished — in particular, confirming they derive in no part from the
CC-BY-SA-4.0 ADAF checkpoints, whose ShareAlike term would otherwise propagate into anything built
on them. That question is unresolved, and the project would rather say so than publish a grant it
has not yet checked it is in a position to give. The intent is to license them openly once the
review concludes.

Tracking issue: <https://github.com/aiarcheology-com/aiarcheology/issues/898>

## `FastViTT8F16.mlpackage` — Apple

This asset is Apple's. It is a development and test asset only and is excluded from Release builds
(`EXCLUDED_SOURCE_FILE_NAMES` in the Xcode project), so it is not part of the shipped application.

The copy here is byte-for-byte identical to Apple's published Core ML model gallery download;
`scripts/fetch_demo_models.sh` verifies that and can restore it. Source URL and SHA-256 digests are
recorded in `/NOTICE`.

The terms under which Apple publishes this gallery asset have not been established by this project.
Until they are, no representation is made about redistribution rights in it.
