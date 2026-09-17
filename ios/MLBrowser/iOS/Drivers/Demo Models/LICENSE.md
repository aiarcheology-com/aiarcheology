# Demo model licences

The two first-party demo models in this directory are covered by the repository's Apache-2.0
licence (`/LICENSE`), as described below.

Apple's FastViT is a separately downloaded test fixture, not an app demo. Its licence and
provenance are recorded in [the test-fixture guide](../../../../TestFixtures/FastViT/LICENSE.md).

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
