# Demo model licences

The files in this directory are **not** covered by the repository's Apache-2.0 licence
(`/LICENSE`). Each has its own terms, set out below.

This file sits beside the `.mlpackage` bundles rather than inside them: an `.mlpackage` is a
directory described by its own `Manifest.json`, and the point of `scripts/fetch_demo_models.sh` is
to prove each one still matches Apple's published contents exactly — which a file added inside it
would defeat, whether or not Core ML happens to object.

## `AIArcheology.mlpackage`, `HroudaDetector15.mlpackage` — first-party weights

Copyright 2023-2026 AI Archeology.

**Licensed under Apache-2.0**, the same terms as the source code — see `/LICENSE`. You may use,
modify and redistribute them, including commercially, subject to that licence.

These are trained detector weights produced by this project. Both halves of the provenance a
grant like this rests on are accounted for:

- **Training data** — the project's own.
- **Base model** — none. They were trained from scratch, **not** fine-tuned from the
  CC-BY-SA-4.0 ADAF checkpoints excerpted in `Tests/NativeModelConverterTests/Fixtures/ADAF/`, so
  that licence's ShareAlike term does not reach them and does not propagate into anything built on
  them.

Both are stated rather than left implicit, because they are the questions a downstream user cannot
answer for themselves by reading the repository: a permissive licence over trained weights is only
worth as much as the provenance behind it.

## `FastViTT8F16.mlpackage` — Apple

This asset is Apple's. It is a development and test asset only and is excluded from Release builds
(`EXCLUDED_SOURCE_FILE_NAMES` in the Xcode project), so it is not part of the shipped application.

The copy here is byte-for-byte identical to Apple's published Core ML model gallery download. The
source URL and the SHA-256 of the archive and of every file inside it are recorded in `/NOTICE` and
in `scripts/demo_models.json`, so the claim can be rechecked rather than taken on trust.
`scripts/fetch_demo_models.sh` verifies the tree against those recorded digests, and `--restore`
re-downloads from Apple.

The terms under which Apple publishes this gallery asset have not been established by this project.
Until they are, no representation is made about redistribution rights in it.
