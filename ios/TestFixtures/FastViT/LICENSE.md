# FastViT test fixture

## `FastViTT8F16.mlpackage` — Apple

This asset is Apple's and is a test fixture, not an app demo. Download it on demand with
`./scripts/fetch_apple_test_models.sh`. The gitignored cache is
`.apple-test-fixtures/FastViTT8F16.mlpackage`; no model binary is tracked at HEAD.
The previous copy under `Drivers/Demo Models/` remains in Git history.

The fetcher verifies the archive and each package file against `scripts/apple_test_models.json`.
Use `--verify` to check the cache offline. Test builds explicitly opt in with
`AIA_INCLUDE_TEST_FIXTURES=YES`; the build phase compiles the verified model into the Debug app
under test and includes the two notice files below. Normal builds omit it; Release builds reject
opt-in. Unit tests load it from the bundle, and UI tests seed it only when explicitly requested.

The model's embedded licence metadata identifies Apple's custom licence at commit
`8af5928238cab99c45f64fc3e4e7b1516b8224ba` of `apple/ml-fastvit`:
[upstream licence](https://github.com/apple/ml-fastvit/blob/8af5928238cab99c45f64fc3e4e7b1516b8224ba/LICENSE).
This is a reference carried by the exact model asset, not an inference from the research code's
licence. On 2026-09-14, all three then-committed model files were also compared byte-for-byte with a
fresh download of Apple's gallery archive; its SHA-256 matched the digest recorded in `/NOTICE`.

The licence permits use, reproduction, modification and redistribution in source or binary form;
it contains no research-only or non-commercial restriction. For redistribution of the complete,
unmodified asset, retain Apple's copyright notice, licence text and disclaimers. Apple's names and
marks may not be used to endorse derived products without permission, and the licence makes no
additional patent grant. Apple's terms apply to this asset; it is not relicensed under Apache-2.0.

Unmodified copies of the upstream texts from that pinned commit accompany the model:

- [Apple licence](FastViT-LICENSE.txt)
- [Referenced component acknowledgements](FastViT-ACKNOWLEDGEMENTS.txt)

Keep both texts with redistributions of this model, including distributions containing historical
copies. The notice sources are stored here, outside the downloaded package, so its verified contents remain unchanged.
See issue #906, A1.
