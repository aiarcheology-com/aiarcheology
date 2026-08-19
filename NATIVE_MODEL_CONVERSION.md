# Native model conversion

## Decision

ML Browser will support non-Core-ML vision models through a small, native converter instead of
embedding Python or attempting to translate all of `coremltools`. The first input is a versioned,
fixed-shape graph package exported by Python. The iOS app will validate the graph, serialize a
Core ML neural-network model, compile it with Core ML, and then follow the existing import path.

This is a converter project, not an inference-runtime project. A model is converted once on the
device and then runs through the existing Core ML and Vision pipeline. Page snapshots and model
weights remain on-device.

The implementation starts with `NativeModelGraph.swift`, which defines and validates the exporter
contract. It deliberately does **not** expose ONNX in the file picker yet: an ONNX file must not be
accepted until an actual emitter produces a Core ML artifact and numerical parity tests pass.

## Why not call `coremltools` from iOS?

`coremltools` is a Python conversion toolkit. Current Apple documentation lists TensorFlow and
PyTorch as the unified converter's source formats; ONNX is not among them. Its historical ONNX
converter is frozen and unmaintained. Core ML itself loads and compiles models on iOS, but it is
not a public model-authoring API.

The Core ML model format is public protobuf, so a native converter is feasible. The first native
emitter should target the older neural-network protobuf (`.mlmodel`): its weights are stored in the
model file and it supports the starter operation set. The modern ML Program format is the long-term
target, but it requires a multi-file `.mlpackage` and external weight blobs.

Swift is compiled to native code; it is not interpreted. C++ is a reasonable later optimization
for a hot protobuf/weight-copy path, but not a prerequisite. Correct graph semantics and conformance
testing are the difficult work.

## Package contract: version 1

The Python exporter creates a directory package, named with the `.aiagraph` extension:

```
MobileNetV2.aiagraph/
  manifest.json
  graph.json
  weights.bin
```

`manifest.json` pins package-level integrity and is intentionally small:

```json
{
  "format": "com.aiarcheology.native-model-graph",
  "formatVersion": 1,
  "graph": "graph.json",
  "graphSHA256": "...",
  "weights": "weights.bin",
  "weightsSHA256": "...",
  "metadata": "metadata.json",
  "metadataSHA256": "..."
}
```

The Swift package now reads the directory as a fixed-layout package: it rejects symbolic links and
unexpected filenames, enforces manifest/graph/weights size limits, verifies the SHA-256 digests of
the full graph, weights, and optional metadata files, validates `graph.json`, and verifies that every declared weight range fits
inside `weights.bin`. The app import path will use the emitter's verified-package entry point;
the lower-level graph-and-weights API remains available for trusted test and exporter tooling.

## Conversion artifacts and formats

The current native conversion has one input format and one output format:

```text
PyTorch source model
  └─ Python reference exporter ──> Model.aiagraph/     (directory; conversion input)
                                      ├─ manifest.json
                                      ├─ graph.json
                                      ├─ weights.bin
                                      └─ metadata.json             (optional, checksummed source facts)

Model.aiagraph/ ── NativeModelGraphPackageReader + NativeModelCoreMLEmitter ──>
  converted.mlmodel                                   (single file; conversion output)
	├─ converted.metadata.json                         (byte-exact source metadata sidecar)
	└─ native-conversion-report.json                   (app-owned lifecycle/support report)
    └─ MLModel.compileModel(at:) ──> converted.mlmodelc/ (Core ML runtime compilation output)
```

The CLI makes the current contract explicit:

```text
native-model-converter INPUT.aiagraph OUTPUT.mlmodel
```

`OUTPUT.mlmodel` is a single-file, legacy Core ML neural-network protobuf. Its Float32 or Float16
weights are embedded in the model file, so current native conversion does not create an external
weights directory. The emitter uses specification version 4 for Float32 multi-array interfaces and
raises it to version 7 only when an interface is Float16.

`.mlpackage` is different: it is Core ML's multi-file authoring package, used by ML Program models
and their external weight files. The app picker already accepts a user-supplied `.mlpackage`, but it
bypasses native conversion and follows the normal model-loading path. The native emitter does **not**
yet emit an `.mlpackage`; adding an ML Program backend will be a separate output mode, likely staged
as `converted.mlpackage/` and covered by its own parity fixtures.

`.mlmodelc` is Core ML's compiled runtime representation, not the converter's portable output.
The app accepts an already compiled user model where supported. For a newly converted `.aiagraph`,
it retains `converted.mlmodel`, asks `MLModel.compileModel(at:)` to create the `.mlmodelc` runtime
artifact, and loads that compiled model. Before conversion, the app asks whether to retain the
app-sandbox copy of the original `.aiagraph`; the external user-selected source is never altered.

The app writes `native-conversion-report.json` as a journal before starting emission. The journal
contains only relative artifact names, phases, metrics, and path-free diagnostics. When a user
cancels or a normal error completes an attempt, the app removes generated `.mlmodel`/sidecar output
and releases in-memory task/progress state; the retained source package and journal are the only
retry/support records. A process termination cannot run cleanup, so its journal and source remain
and recovery labels the incomplete attempt as interrupted rather than treating any staged output as
registered. Only after Core Data registration succeeds does the **Convert Only** choice remove the
copied source package. The journal is retained after success as the converted model's support
record and is removed together with that configuration's directory.

After registration, ML Browser exposes an explicit export/share action. It stages one temporary ZIP
containing `ConvertedModel/converted.mlmodel`, the byte-exact `converted.metadata.json` sidecar when
present, `native-conversion-report.json`, and a short README. The source `.aiagraph` package is not
included implicitly: retaining it is a separate user choice and it can be large or private. The
staging tree is removed before the archive is returned; the completed share sheet removes the
temporary archive as well.

## Metadata: source facts, conversion provenance, and target facts

Metadata must not be copied blindly. A source model can describe image normalization, labels, or a
classifier wrapper that the generated Core ML model does not expose. The contract therefore keeps
three separate kinds of facts:

| Layer | Durable location | Meaning |
| --- | --- | --- |
| Source metadata | `Model.aiagraph/metadata.json`, then byte-for-byte `converted.metadata.json` | The original exporter/model facts, including arbitrary nested JSON. |
| Conversion provenance | Namespaced Core ML user-defined keys | Graph/weights/metadata SHA-256, exporter name/version, target format, and the derived target interface. |
| Target metadata | Standard Core ML metadata plus target namespaced keys | Facts true of the generated NeuralNetwork `.mlmodel`, never unverified source claims. |

`metadata.json` is optional for legacy v1 packages and required by current exporters. When present,
the manifest names it explicitly and pins its SHA-256. It has this extensible envelope:

```json
{
  "format": "com.aiarcheology.native-model-metadata",
  "formatVersion": 1,
  "source": {
    "shortDescription": "Original model description",
    "versionString": "source version",
    "author": "original author",
    "license": "source license",
    "userDefined": {
      "task": "classify",
      "names": "[\"label one\",\"label two\"]"
    }
  },
  "labels": ["label one", "label two"],
  "preprocessing": { "source-specific": "details" },
  "task": "classification",
  "provenance": { "arbitrary": "source details" }
}
```

Only the `source` attribution section is interpreted by the current emitter. Its author and license
remain relevant to the converted weights and are copied to Core ML's standard fields. The source
description is labelled as a conversion of that source; source user-defined values are retained
under `com.aiarcheology.native.source.user-defined.*`. They are never copied unprefixed as target
claims. Labels, preprocessing, task, and arbitrary provenance remain losslessly in the sidecar;
they may also be represented as JSON strings in source user-defined values for consumers that need
them inside the `.mlmodel`.

The package test `testEmit_metadata_preservesSourceClassesWithoutClaimingTargetClassifierLabels`
proves that the raw `labels` array survives exactly and source `names` is namespaced in the compiled
Core ML metadata. It also proves the unprefixed target `names` key is absent: the current model
emits raw logits, not a Core ML classifier wrapper, so presenting source labels as target behavior
would be incorrect.

The emitter derives its target keys from what it actually writes: target model format, graph version,
input/output names/shapes/types, source producer, and graph/weight/metadata hashes. A future image
preprocessing adapter, classifier wrapper, or detector decoder must add the corresponding target
metadata only when that behavior has been emitted and is parity-tested.

The high-level converter additionally records the input package filename in the generated Core ML
model as `com.aiarcheology.native.conversion.source-package-filename`. A host may supply an original
model filename and an authoritative remote URL through `NativeModelConversionSourceProvenance`; ML
Browser writes those as `.original-model-filename` and `.original-model-url`. The compiled-model
test verifies all three values. Local document-provider and sandbox paths are deliberately not
stored: they are device-private locations, not portable model provenance. Arbitrary exporter-side
provenance remains byte-exact in the source metadata sidecar.

These fields are traceability only, never a model identity. The stable functional identity remains
the already-emitted graph and weight SHA-256 pair, so a host duplicate policy must compare those
content hashes rather than a URL or filename.

## Versioned converter identity

Every converted `.mlmodel` carries four separate, non-substitutable identities in Core ML
user-defined metadata:

| Identity | Metadata | Purpose |
| --- | --- | --- |
| Source exporter | `com.aiarcheology.native.conversion.producer.name` / `.version` | Ties graph lowering to the Python/ONNX exporter and its training-export environment. |
| Source artifact | `com.aiarcheology.native.conversion.source-package-filename` / `.original-model-filename` / `.original-model-url` | Identifies the package and, when supplied by the host, the portable original artifact and its remote origin. |
| Interchange schema | `com.aiarcheology.native.target.graph-format-version` | Defines how `graph.json` and `weights.bin` must be interpreted. |
| Swift package release | `com.aiarcheology.native.converter.package-version` | The SemVer release of `NativeModelConverter` that produced the model. |
| Swift conversion revision | `com.aiarcheology.native.converter.conversion-revision` | Monotonic lowering/serialization revision, incremented for artifact-affecting changes even when the public Swift API is unchanged. |

The app's durable report records the same package release and conversion revision. A model author
can therefore compare a model's source exporter/training metadata, graph and weight hashes, and
the exact native conversion implementation even after the app later ships a newer converter.

Release rule: change the SemVer package version for public API or package compatibility changes;
increment `conversionRevision` for every output-affecting emitter, validation, or target-metadata
change; keep the source producer version owned by the exporter. The package test checks all four
embedded identities against the compiled Core ML model.

The torchvision reference exporter writes this metadata by default and accepts
`--metadata-json SOURCE.json` to preserve a supplied metadata document byte-for-byte. A package
whose metadata does not meet the integrity or envelope checks is rejected; it is never converted
with metadata silently omitted.

```json
{
  "formatVersion": 1,
  "producer": { "name": "aiarcheology-pytorch", "version": "0.1.0" },
  "inputs": [
    { "name": "image", "dataType": "float32", "shape": [1, 3, 224, 224] }
  ],
  "weights": [
    {
      "name": "features.0.weight",
      "dataType": "float32",
      "shape": [32, 3, 3, 3],
      "offset": 0,
      "byteCount": 3456
    }
  ],
  "operations": [
    {
      "name": "features.0",
      "kind": "conv2d",
      "inputs": ["image", "features.0.weight"],
      "outputs": [
        { "name": "features.0", "dataType": "float32", "shape": [1, 32, 112, 112] }
      ],
      "attributes": {
        "kernelSize": [3, 3],
        "strides": [2, 2],
        "padding": [1, 1],
        "dilations": [1, 1],
        "groups": 1
      }
    }
  ],
  "outputs": ["features.0"]
}
```

Rules enforced today:

- Fixed, positive tensor dimensions only; no symbolic or dynamic dimensions.
- Float32 and Float16 only.
- A single little-endian `weights.bin`; every weight has an exact byte range derived from its type
  and shape.
- No overlapping ranges, duplicate tensor names, forward tensor references, or duplicate outputs.
- Operations are already topologically ordered and declare one typed output each.
- Only JSON scalar/vector attributes are allowed; tensors may not be constructed dynamically.

## Starter operation set

Version 1's validator recognizes 21 operations: `conv2d` (including grouped/depthwise), `linear`,
`relu`, `relu6`, `maxPool2d`, `averagePool2d`, `globalAveragePool2d`, `reshape`, `transpose`,
`concat`, `softmax`, `matmul`, `add`, `subtract`, `multiply`, `divide`, `batchNorm`, `sigmoid`,
`tanh`, `flatten`, and `identity`.

This is enough for a fixed-shape MobileNetV2 classifier when exported in inference mode. It is not
yet enough to import an arbitrary detector: YOLO-style heads need more shape, slice, resize, decode,
and non-maximum-suppression coverage, and their output must be adapted to the app's Vision detector
contract (`confidence` and `coordinates`).

The emitter is intentionally narrower than the validator. It now emits and numerically tests the
MobileNetV2 classifier spine: grouped/depthwise `conv2d`, `batchNorm`, `relu`, `relu6`, residual
`add`, `globalAveragePool2d`, `flatten` (axis 1), and `linear`. It stores Float32 or Float16
weights inside a Core ML neural-network model. The remaining validated operations are rejected at
emission time until they receive the same compiler-backed coverage.

## Model priority

The useful order is based on shared operators, device suitability, and the app's two current tasks,
not on chasing every architecture name.

| Priority | Models / family | First required outcome |
| --- | --- | --- |
| 1 | MobileNetV2/V3, EfficientNet-Lite, ResNet-18/50 | Image classification from PyTorch export; MobileNetV2 is the golden model. |
| 2 | SSD-MobileNet, EfficientDet-Lite | Detection with a conventional, fixed-shape head. |
| 3 | YOLOv5/YOLOv8 nano/small, YOLOX-Tiny | Widely exported ONNX detectors; add the head/decode/NMS adapter deliberately. |
| 4 | RetinaFace/SCRFD | Face detection; shares the detector work but needs anchor/decode support. |
| 5 | MobileFaceNet/ArcFace | Face embeddings/verification; add embedding-output support rather than forcing it through Vision classification. |

The popular source interchange formats are PyTorch export/TorchScript, TensorFlow, ONNX, and TFLite.
ONNX should be the first raw-format adapter after the graph-package path works because it is common
for detector distribution. The native graph is still the stable internal boundary: each source
adapter lowers to it, so the Core ML emitter is implemented once.

## Test and conformance principles

The exporter and native emitter are tested as a pair, but neither implementation is assumed to be
correct just because it agrees with the other. Every golden model follows this order:

1. Run the original source framework model on fixed inputs.
2. Export it to `.aiagraph`; validate the package, checksums, graph, tensor metadata, and weight
   ranges before the native emitter is allowed to read it.
3. Convert the package with the Swift CLI and load the resulting `.mlmodel` with the macOS Core ML
   runtime. This is terminal-only; it does not boot an iOS simulator.
4. Compare the Swift-generated Core ML outputs to the source model. On any mismatch, expose and
   compare tensors in topological order to locate the first divergent operation.
5. Optionally convert the original source model through `coremltools`, but first prove that this
   *reference conversion itself* matches the source framework. It is an independent differential
   oracle, never a substitute for the source-model comparison.

The rules that keep these tests meaningful are:

- **No silent fallback.** An unimplemented operation fails with its graph node name and kind.
- **Structural checks precede numerical checks.** Inputs/outputs, tensor type/shape, attributes,
  weight byte ranges, package checksums, and Core ML compilation are all verified before comparing
  values.
- **Budgets are model- and type-specific.** Float32 tolerances represent documented runtime
  reduction-order differences; Float16 needs its own measured budget and must also preserve the
  relevant decision (for classification, top-1). A tolerance may not be widened to hide a new
  discrepancy.
- **Intermediates are the debugger.** A final-logit mismatch is insufficient evidence. The parity
  harness must report the first failing graph tensor; `--diagnose` also prints the five largest
  intermediate errors.
- **Perturbations catch insensitive errors.** Finite-difference tests compare output deltas for
  several input epsilon values, with amplified logits so very small conversion errors cannot vanish
  below an absolute tolerance.
- **Fixtures are reproducible.** Random fixtures set a seed, pretrained fixtures record the source
  checkpoint family, and all external model artifacts have a pinned SHA-256.
- **Conversion and inference remain distinct.** Python is exporter/reference tooling only. The app
  performs native package validation and native Core ML serialization, then uses its existing Core
  ML/Vision inference path.

Golden suites start with tiny Conv/ReLU/Linear tests, then MobileNetV2, then SSD-MobileNet and a
detector head. Unsupported operations must receive compiler-backed coverage before being enabled.

## Required tools and commands

The native package needs Xcode's command-line tools (Swift, Core ML compiler/runtime) and macOS 14
or newer. It intentionally uses terminal tests rather than a simulator.

| Purpose | Command | What it proves |
| --- | --- | --- |
| Fast native suite | `swift test` | Graph validation, package integrity, protobuf serialization, compile/load, and small numerical fixtures. |
| Apple artifact contract | `./scripts/test_native_model_converter.sh` | Downloads Apple MobileNetV2 FP16 and INT8-LUT artifacts, pins their SHA-256, compiles them, and runs their red-image probes. |
| Source-to-native parity | `$PARITY_PYTHON scripts/test_torchvision_mobilenet_v2_parity.py --intermediates` | Torchvision source versus Swift-generated Core ML, including 151 rank-preserving tensors. |
| Float16 serialization | `$PARITY_PYTHON scripts/test_torchvision_mobilenet_v2_parity.py --float16-weights --intermediates` | Source with Float16-quantized weights versus native Float16 package emission. |
| Sensitivity | `$PARITY_PYTHON scripts/test_torchvision_mobilenet_v2_parity.py --sensitivity --intermediates` | Finite-difference output response at three epsilon values. |
| Pretrained checkpoint | `$PARITY_PYTHON scripts/test_torchvision_mobilenet_v2_parity.py --pretrained --intermediates` | A real torchvision ImageNet-1K MobileNetV2 checkpoint, not only a seeded random model. |
| Independent Python oracle | `$REFERENCE_PYTHON scripts/test_torchvision_mobilenet_v2_parity.py --pretrained --coremltools-reference` | A diagnostic comparison with a separately converted coremltools model, only after that model agrees with PyTorch. |
| Release conversion report | `swift run -c release native-model-converter INPUT.aiagraph OUTPUT.mlmodel --report conversion-report.json` | Native package read/emission wall time and exact input/output artifact sizes, serialized as JSON. |

### Fixture-gated suites: feeding `NATIVE_MODEL_ONNX_DIRECTORY` and `NATIVE_MODEL_REFERENCE_DIRECTORY`

A bare `swift test` does **not** run the numerical parity oracles. They are gated on two environment
variables, and a gate that is unset **skips** — so the run still reports success while proving
nothing about conversion accuracy. Measured on a clean checkout: `swift test` with neither variable
set executes 296 tests, skips 5, and exits 0. Treat "green" from that command as covering graph
validation and serialization only, never parity. Both variables are the two suites AGENTS.md §13
requires to stay green, so set them before claiming a converter change is verified.

| Variable | Unlocks | How to populate |
| --- | --- | --- |
| `NATIVE_MODEL_ONNX_DIRECTORY` | `ONNXConversionIntegrationTests` and `YOLOv5/​v8/​11TrunkConversionTests` — top-1 and elementwise comparison against an ONNX Runtime oracle | `scripts/fetch_native_test_models.sh [TARGET_DIR]` |
| `NATIVE_MODEL_REFERENCE_DIRECTORY` | The Apple MobileNetV2 FP16 / INT8-LUT artifact contract and its red-image probes | `scripts/test_native_model_converter.sh` sets it for you |

```bash
# 1. ONNX + YOLO oracles. Downloads 7 .onnx fixtures (~375 MB) to .native-model-fixtures/,
#    which is gitignored; each file is SHA-256 verified and re-runs are cached, so this is
#    cheap after the first time.
./scripts/fetch_native_test_models.sh
NATIVE_MODEL_ONNX_DIRECTORY="$PWD/.native-model-fixtures" swift test \
  --filter "ONNXConversionIntegrationTests|YOLOv5TrunkConversionTests|YOLOv8TrunkConversionTests|YOLO11TrunkConversionTests"

# 2. Apple artifact contract. Downloads the two reference .mlmodel files into a temp directory,
#    exports NATIVE_MODEL_REFERENCE_DIRECTORY, runs the suite, and deletes the directory on exit.
./scripts/test_native_model_converter.sh
```

**Run both — neither command alone is sufficient.** Each script feeds one gate, so the other gate's
suites still skip. Measured on this branch: step 1 executes the 4 ONNX Runtime oracles with 0 skips;
step 2 executes 296 tests with 4 skips, and those 4 skips *are* the ONNX oracles. Only the union
covers what AGENTS.md §13 asks for. The skip counts are the quickest way to tell which gate you
forgot: 5 skips means neither variable was set, 4 means only the reference gate was.

Run these **sequentially, never alongside an `xcodebuild` invocation**: concurrent builds race the
SPM `SourcePackages/artifacts` directory and the loser fails with a missing-XCFramework error and
zero tests run, which reads like a real failure but is a toolchain collision.

`PARITY_PYTHON` denotes any environment containing PyTorch, torchvision, and NumPy; the primary
route invokes the Swift `native-model-evaluator` CLI and imports no coremltools code. The present
exploratory environment uses Torch 2.8.0. `REFERENCE_PYTHON` must additionally contain a pinned,
coremltools-supported environment. The current verified setup is coremltools 9.0, Torch 2.7.0, and
torchvision 0.22.0. Do not use the Torch 2.8 warning-bearing environment to certify a
coremltools conversion result. The primary execution path is the Swift evaluator because it uses
the same native Core ML API as the app; it is the release gate for emitted models.

As of 2026-07-17, native Float32 pretrained MobileNetV2 parity passes on the three fixed inputs:
the maximum absolute error is `4.49419022e-05` (with identical top-1 and all 151 checked
intermediates within the `1e-4` Float32 budget). The pinned coremltools 9.0 / Torch 2.7 reference
also passes its new source-first guard when emitted as a Float32 ML Program; the corresponding
native-versus-PyTorch errors are `2.09510326e-05`, `1.57356262e-05`, and `3.79532576e-05`.
The legacy coremltools NeuralNetwork reference is not used because it cannot accept a Float32
precision request and differed by up to `0.1320852` through Float16 quantization. The direct Swift
evaluator also passes the pretrained Float16 package, including all 151 intermediate tensors; its
three final-output maximum errors are `2.02059746e-05`, `5.06639481e-06`, and `5.96046448e-06`.
An earlier `0.11538458` discrepancy occurred only in the old Python-coremltools prediction harness
and does not reproduce with the native evaluator. Its Python-path root cause has not been assigned
without a separate isolated experiment. The direct sensitivity fixture also passes all 151 fixed
input intermediates; its final-response delta errors at epsilon `1e-4`, `1e-3`, and `1e-2` are
`1.16415322e-09`, `1.28056854e-09`, and `1.16415322e-09` respectively.

## Delivery sequence

1. Done in this change: graph v1 schema and strict, deterministic validator with MobileNet-style
   test coverage. A native protobuf emitter now serializes a MobileNet-style classifier spine as a
   Core ML neural-network `.mlmodel`, including grouped/depthwise Conv2D plus Float32 and Float16
   weights. Terminal tests compile and run generated models on macOS.
2. Done in this change: add package-manifest SHA-256 validation, fixed layout, size limits, and a
   verified package reader. Local-file import accepts `.aiagraph`, converts it off the main actor
   into the configuration directory, removes the copied source package only after emission succeeds,
   and then reuses `ModelLoadingService` to compile and inspect the generated Core ML model.
3. Add explicit remote/cached package acquisition support behind a feature flag, including staged
   output and cleanup after compilation failure.
4. Done in this change: add a Swift-only Core ML evaluator to make source-to-native parity
   independent of coremltools; verify pretrained Float32 and Float16 parity at every
   rank-preserving tensor; and calibrate the optional coremltools oracle against PyTorch using a
   supported Torch 2.7 / Float32 ML Program configuration.
5. Add regular pooling, reshape, transpose, concatenate, softmax, and the remaining elementwise
   operations with the same package, compile, source-parity, and sensitivity coverage.
6. Only then add the ONNX reader, lowering it to the same graph v1 representation.
7. Add detector adapters and the extra operations only as parity fixtures require them.

## MobileNetV2 reference fixtures

The package test fixture records the exact URLs and SHA-256 values for the supplied Apple
MobileNetV2 FP16 and INT8-LUT models. `scripts/test_native_model_converter.sh` downloads them to
a temporary directory, verifies their hashes, compiles them with Core ML as part of `swift test`,
and runs a deterministic solid-red image probe. This is terminal-only and does not start a simulator.
These are external golden artifacts: they validate the eventual converter's output contract, but do
not replace the needed PyTorch/ONNX source export and numerical parity fixtures.

`scripts/test_torchvision_mobilenet_v2_parity.py` is the first real source-model parity fixture. It
exports a deterministic torchvision MobileNetV2, invokes the Swift CLI, and compares logits from
three fixed Float32 inputs against PyTorch. `--intermediates` compares all 151 rank-preserving
emitted tensors; `--coremltools-reference` adds an independent Python conversion; `--sensitivity`
checks finite-difference output changes with amplified logits; and `--float16-weights` covers
Float16 serialization. `--pretrained` uses torchvision's ImageNet-1K checkpoint, downloading it
through torchvision when it is not already cached. Run the script with an environment containing
PyTorch, torchvision, and NumPy; `coremltools` is required only for the optional independent
reference flag. The independent coremltools comparison and the
amplified sensitivity mode are intentionally separate because the legacy coremltools
NeuralNetwork backend does not preserve this fixture's amplified logits. The independent reference
therefore uses a Float32 ML Program on macOS 14; the app converter's NeuralNetwork `.mlmodel`
remains the product being tested. Float32 comparisons use
an explicit `1e-4` absolute/relative budget for normal CPU kernel reduction-order differences and
also require an identical top-1 class; intermediate parity localizes any graph discrepancy.

## Updating the Python coremltools reference

`coremltools` is a differential oracle and reference implementation, not a runtime dependency or
source to translate into Swift. Update it in an isolated, pinned Python environment. Record the
coremltools, Python, Torch, torchvision, macOS, and Xcode/Core ML runtime versions; regenerate the
reference artifacts; then run the source-framework → native Swift parity gate before comparing the
new coremltools output. A changed coremltools artifact may expose a Swift bug, an Apple converter
change, or a source-export change—none is accepted without source-first numerical and structural
evidence. Promote a newly supported operation or metadata behavior only with a versioned native
graph fixture, target metadata assertions, and source/native parity. The native graph schema and
Swift conversion revision remain independent of the coremltools package version.

## Client progress, errors, and instrumentation

Client code should call the high-level `NativeModelConverter.convert(from:to:reporting:)` API. Its
progress callback is invoked from conversion work, so a UI must marshal changes to the main actor.
It reports exact package stages and then an exact `0...operationCount` count during model emission;
it intentionally does not invent an overall percentage before `graph.json` has revealed the
operation count.

```swift
let converter = NativeModelConverter()
let metrics = try await converter.convert(from: source, to: destination) { progress in
    Task { @MainActor in
        importViewModel.progress = progress
    }
}
```

All high-level failures are `NativeModelConversionError`. Its `diagnostic` is a serializable,
path-free `{ code, phase, message }` value for the UI or an explicit user-created support report.
For example, a modified graph produces the stable code
`package.graphChecksumMismatch`; the message retains the expected and actual checksums. Neither
the converter nor the app uploads the source package or metadata automatically.

A normal Swift/Core ML error is localized through that typed error boundary. A same-process trap,
uncaught Objective-C exception, or operating-system termination cannot be converted into a Swift
`Error`: the app is no longer executing. ML Browser therefore writes its app-owned journal before
conversion and at durable progress boundaries. On the next launch it marks an incomplete `staged`
or `converting` journal as `interrupted`, records the last durable phase with code
`app.interruptedBeforeCompletion`, and offers the user its path-free report plus retry/discard.
That report deliberately does **not** invent an exact termination cause; it only distinguishes an
interruption from a typed converter failure and preserves evidence suitable for support.

`NativeModelConverter` checks cooperative task cancellation before each package stage and before
each graph operation. It reports the stable `cancelled` diagnostic and final `cancelled` progress
phase. The conversion test deliberately cancels between two emitted operations and verifies that
no output model is committed. Atomic output writes prevent a partially serialized `.mlmodel` from
replacing a prior model. ML Browser treats any generated output from a terminal cancellation or
normal error as transient and deletes it while retaining only the source package and support
journal; host recovery handles the distinct case where process termination prevented cleanup.

One conversion serializes graph operations and weight serialization in topological order. Swift
tasks move work off the main actor but do not promise a dedicated OS thread or operation-level
parallelism. Package data is per-conversion immutable; `NativeModelGraphPackageReader` and the
app's report writer are actors. A process-global FIFO gate covers every high-level
`NativeModelConverter.convert` call: only one job reads, validates, emits, and writes at a time;
later jobs receive `waitingForExclusiveAccess` progress until their turn. Conversion timing starts
after the gate, so it excludes queue delay. The three-job gate test proves that a third job remains
queued while the second owns access. The direct reader/emitter APIs are low-level tooling APIs and
do not enter this host-conversion gate. The gate is process-local—separate processes still require
host coordination.

The package writes unified-log events to subsystem `com.aiarcheology.NativeModelConverter`, category
`Conversion`, using public-only operation counts, byte counts, failure codes, and stages—never a
user file path. Instruments can inspect these explicit `os_signpost` intervals:

- `Native model conversion`
- `Read native model package`
- `Emit Core ML model`

Phase changes are also `os_signpost(.event)` entries. This separates package verification from
protobuf emission when investigating a slow conversion.

## Performance and memory evidence

Measure the Release binary, not Debug: ML Browser's Release configuration is already whole-module
Swift compilation with safe `-O`; SwiftPM's equivalent is `swift run -c release`. Do not use
`-Ounchecked`: it removes checks relied on by the malformed-package validation path.

The CLI `--report` result contains reproducible file sizes, monotonic read/emission timings, and
the last observed process-memory sample. Every progress update after exclusive access contains the
same `processMemoryUsage`: current whole-process physical footprint, the baseline at conversion
start, and the largest value seen at a progress boundary. ML Browser presents the current value and
observed increase while conversion runs, then retains the final value in its report. These values
are intentionally labelled **process** memory: app UI, Core ML, and other work share the process.
They are sampled rather than continuously measured, so the observed peak is a lower bound—not a
converter-only allocation total or a guaranteed peak. The current implementation retains source
weight bytes while it builds the embedded-weight `.mlmodel`, so file size alone cannot establish
working-set memory.

`NativeModelConversionPerformanceTests` supplies the physical-device measurement. It is opt-in:
set `NATIVE_MODEL_CONVERSION_DEVICE_BENCHMARK=1` in the Test action, select a connected iPhone or
iPad, and run that one test. XCTest records `XCTClockMetric` and `XCTMemoryMetric` in the resulting
`.xcresult`; an attached JSON preflight records the exact source/output bytes and per-run library
timings. The fixture has six Float32 convolution layers and approximately 14 MiB of weights, the
same Float32 weight-size class as MobileNetV2, but it is not an architecture or numerical-parity
substitute for the real MobileNetV2 suite.

Do not set a device budget from a Mac result or from a single phone. First collect the same fixture
on each supported iPhone/iPad class under the same OS/build configuration, record the `.xcresult`
and JSON evidence, and then use that baseline to choose package limits or a streaming emitter. A
streaming serialization path is the likely memory optimization if the measured peak is too high;
compiler flags alone cannot remove an algorithmic duplicate of model-weight bytes.

## Sources

Apple documents the public protobuf Core ML model specification and states that it can be created
from languages supported by protobuf. It recommends ML Program for new Core ML features, while the
neural-network model format remains broadly deployable. The unified conversion documentation lists
TensorFlow and PyTorch source formats; the historic ONNX converter repository says it is no longer
maintained.

- [Core ML model format and protobuf specification](https://apple.github.io/coremltools/docs-guides/source/mlmodel.html)
- [Core ML source and target conversion formats](https://apple.github.io/coremltools/docs-guides/source/target-conversion-formats.html)
- [Historical ONNX-to-Core-ML converter status](https://github.com/onnx/onnx-coreml)
