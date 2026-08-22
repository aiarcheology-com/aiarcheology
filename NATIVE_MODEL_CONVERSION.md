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

One emission can now write more than one file in that single output format. The emitter's
`emit(graph:weights:to:roiBoxHeadChunk:)` overload writes a second standalone `.mlmodel` beside the
primary — `converted.mlmodel` yields `converted.roi-box-head-chunk.mlmodel` — and records it in a
manifest inside the primary model's Core ML metadata, carrying the companion's role, plain basename,
SHA-256, fixed batch size, proposal count, and derived invocation count. The companion is written
first and the primary last, because the primary is the discovery anchor: publishing it earlier would
leave a model advertising a file that does not exist.

That companion is deliberately **not** a Core ML pipeline stage. A stage is embedded in the outer
model and runs inside the same `prediction` call, which is precisely the in-graph chunking AIA-0670
measured as saving nothing; a separate model is what lets the host drive the loop itself and invoke
the chunk the manifest's invocation count times. It is also **not yet production-managed**: the app's
cleanup path removes exactly the converted model and its metadata sidecar, and the CLI reports a
single output model size, so until those paths learn about companions in M3c the caller owns the
companion's lifetime. Neither the high-level `NativeModelConverter.convert` API nor the CLI reaches
this overload today.

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
each kind of fact separate:

| Layer | Durable location | Meaning |
| --- | --- | --- |
| Source metadata | `Model.aiagraph/metadata.json`, then byte-for-byte `converted.metadata.json` | The original exporter/model facts, including arbitrary nested JSON. |
| Conversion provenance | Namespaced Core ML user-defined keys | Graph/weights/metadata SHA-256, exporter name/version, target format, and the derived target interface. |
| Target metadata | Standard Core ML metadata plus target namespaced keys | Facts true of the generated NeuralNetwork `.mlmodel`, never unverified source claims. |
| Artifact manifest | `com.aiarcheology.native.target.artifact-manifest.json` | The companion files the primary model cannot run without: role, plain basename, SHA-256, fixed batch size, proposal count, invocation count. |
| Parity provenance | `com.aiarcheology.native.target.parity-provenance.json` | What this emission is entitled to claim about its numerics: `verified` or `structurally-matched`. |

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

The last two rows are canonical JSON documents rather than flat strings, each carrying its own
`format` and `formatVersion`, and both are written to the model's *outer* description — the only
description `MLModelDescription` publishes for a pipeline. The artifact manifest appears only when an
emission wrote a companion, and its digest is what lets a future consumer detect an older companion
left beside a newer primary before loading it — nothing in this converter enforces that yet: no
manifest reader and no hash-checking loader exists, so today the digest records the binding rather
than checking it, and a stale companion still compiles and predicts with silently mismatched shapes.
It deliberately records interface facts only; batch size and invocation count are numbers a runtime
must obey, whereas how fast a chunk ran on some device is a measurement that would age into a lie
inside a shipped model.

Parity provenance is written by every emission path that writes target metadata at all, and never
conditionally within one, because a model missing the fact is indistinguishable from one whose
numbers were checked. Those paths are the package overload, the ONNX/classifier overload, the
detector overload, and the ROI-box-head-chunk overload, which stamps both files it writes. The bare
`emit(graph:weights:to:)` and `emit(graph:to:)` overloads pass no metadata, so a model written
through them carries no metadata block at all — no parity provenance, no conversion revision, no
target interface. They exist for conformance fixtures and tests; a caller emitting a model to ship
uses one of the four stamped paths.

The default claim is the honest one: `structurally-matched` says the graph validated, every
operation lowered, and the model serialized successfully — the emitter never compiles or loads its
own output, so it cannot say more. It is a statement about the conversion, not about the numbers it
produces. `verified` means the emitted outputs were compared against a reference oracle and agreed
within that check's tolerance, and only a
caller that ran such a check may ask for it. A caller who says nothing gets the conservative claim
rather than no claim at all, so silence can never ship a model asserting a parity run that did not
happen. The value carries the claim and nothing else — no oracle name, no error bound, no date; those
describe a run, and which of the two claims an emission is entitled to make does not age.

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

Every `.mlmodel` emitted through a metadata-writing path — the four listed above — carries these
separate, non-substitutable identities in Core ML user-defined metadata:

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

Under that rule `conversionRevision` moves from 7 to 9 in this change, because the emitted artifact
contents changed again. Revision 3 was anchor-free detector emission — a Core ML network plus
non-maximum-suppression pipeline for YOLO v8/v11 raw heads, with its task, class count, label
provenance, and coordinate-space metadata. Revision 4 adds the two-stage detector operations
(ROI crop/resize, top-K, gather, the in-graph non-maximum-suppression layer, and the elementwise
primitives the box arithmetic composes from), the standalone ROI box head chunk named by an artifact
manifest in the primary model's metadata, and the parity provenance every metadata-writing emission
path now records. Revision 5 adds the closed ADAF Faster R-CNN registry and its fixed-canvas,
ImageNet-normalized detector graph. Revision 6 adds the two measured terminal suppression layers and
makes the mandatory Vision NMS model an explicit no-policy interface adapter, so it cannot silently
turn two ADAF passes into three. Revision 7 masks Core ML's false zero-survivor NMS slot before the
adapter sees it, so an empty tile produces no phantom recognized object. A revision-7 model is
therefore distinguishable from its earlier forms by its metadata alone, which is what the revision
exists to make possible. Revision 8 records the initial parity finding for the ADAF Faster R-CNN
graph. Revision 9 records the hardware-preserving runtime policy derived from that finding: an
importing runtime may use `.cpuAndGPU` (dedicated GPU, ANE excluded) without changing placement for
unrelated models.

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
- Operations are already topologically ordered. Each declares one typed output, except `splitND`
  (one per split size), `topK` (values, then indices), and `nms` (kept boxes, kept scores, kept
  source indices, and the valid count) — the arities the Core ML layers themselves require.
- Only JSON scalar/vector attributes are allowed; tensors may not be constructed dynamically.

## Starter operation set

The validator recognizes 43 operation names, and which of them a graph may use depends on its format
version. Nineteen are shared by both families: `conv2d` (including grouped/depthwise), `linear`,
`relu`, `relu6`, `maxPool2d`, `averagePool2d`, `upsample2d`, `globalAveragePool2d`, `softmax`, `add`,
`multiply`, `divide`, `batchNorm`, `sigmoid`, `tanh`, `leakyRelu`, `exp`, `flatten`, and `identity`.
Version 1, the classic rank-5 layout family, adds six of its own — `reshape`, `transpose`, `concat`,
`sliceChannels`, `softmaxChannel`, and `constant` — for 25 in total. Version 2, the exact-ND family,
adds seventeen — `reshapeND`, `transposeND`, `concatND`, `sliceND`, `splitND`, `batchedMatmulND`,
`constantND`, `subtract`, `minND`, `maxND`, `floor`, `log`, `greaterEqual`, `cropResize`, `topK`,
`gather`, and `nms` — for 36. `matmul` is a recognized name but valid under neither version.

Several of those are exact-ND only for a stronger reason than layout preference. `floor`, `log`,
`greaterEqual`, `minND`, `maxND`, and `subtract` have no equivalent in the classic layer set at all —
there is no floor, no comparison, and no subtract there — so their only Core ML form is an exact-rank
layer, and admitting one into a version 1 graph would mix layers that read the same blob differently.
`cropResize` adds a second reason: its blobs are rank 5 *as data*, the box input being
`[K, 1, 4, 1, 1]` and the output batching over K, which the legacy mapping's fixed four-axis reading
cannot name. `gather` adds a third, its output rank being `data.rank - 1 + indices.rank` rather than
the data input's, a rank that varies with the indices blob. And `nms` adds a fourth: its kernel
refuses inputs that are not rank 3 exactly, and rank 3 is a shape the legacy mapping reads as
`[C, H, W]` rather than the `[batch, boxes, 4]` the layer means.

This is enough for a fixed-shape MobileNetV2 classifier exported in inference mode, and — since
revision 3 — for an anchor-free YOLO v8/v11 raw head emitted as a Core ML network plus
non-maximum-suppression pipeline against the app's Vision detector contract (`confidence` and
`coordinates`). It is not yet enough to import an arbitrary detector. What the operations above give
a two-stage architecture is layer vocabulary, not an assembled detector: no Faster R-CNN proposal
generator or box head is built, exported, or parity-tested here.

The emitter is no longer much narrower than the validator. It emits every recognized operation except
`divide`, `tanh`, `identity`, and the universally rejected `matmul`; those still fail at emission time
with their graph node name and kind rather than falling back silently. Alongside the MobileNetV2
classifier spine — grouped/depthwise `conv2d`, `batchNorm`, `relu`, `relu6`, residual `add`,
`globalAveragePool2d`, `flatten` (axis 1), `linear` — and the YOLO trunk and decode operations, it
now emits `floor`, `log`, `greaterEqual`, `minND`, `maxND`, `subtract`, `cropResize`, `topK`,
`gather`, and `nms`. `averagePool2d`, which the validator already accepted, gained an emitter path in
the same change. Weights remain Float32 or Float16 stored inside the Core ML neural-network model.

Two of the new operations need care at the call site. `cropResize` is deliberately only the crop:
torchvision's `roi_align(sampling_ratio=2)` is reproduced as a graph-level composition — crop at twice
the target size, then a 2x2 `averagePool2d` — so neither operation is welded to one sampling ratio.
And the in-graph `nms` layer is not the standalone NMS *model* the detector pipeline emits as its
terminal stage: the layer has fixed padded outputs, sits mid-graph where its survivors feed everything
after it, and mandates `[center-x, center-y, width, height]` box coordinates, where every other box
operation in this IR works in corners.

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

Every operation added for two-stage detection follows that rule. `NativeModelDetectionLayerTests`
compiles a single-operation model per behavior and compares its Core ML output against an
independently computed expectation, including the crop-then-average-pool composition checked against
`torchvision.ops.roi_align` on interior boxes; `NativeModelEmissionRegressionTests` decodes a
representative conversion to prove the previous revision's structure survived the change. One
divergence is pinned rather than hidden: for a box overhanging the feature map, `cropResize`
contributes exactly zero past the last interpolable row and column where `roi_align` replicates the
edge, so the two disagree there by construction. Closing that gap is M3c.

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

### Fixture-gated suites: feeding `NATIVE_MODEL_ONNX_DIRECTORY`, `NATIVE_MODEL_REFERENCE_DIRECTORY` and `ADAF_CHECKPOINT_DIRECTORY`

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
| `ADAF_CHECKPOINT_DIRECTORY` | `ADAFCheckpointDirectoryTests` — every published ADAF PyTorch checkpoint is read and identified, and a detector graph is emitted, compiled, and opened | `scripts/fetch_adaf_checkpoints.sh`, then run via `scripts/test_adaf_checkpoints.sh` |

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

```bash
# 3. ADAF PyTorch checkpoints (AIA-0666). The default fetch reconstructs the metadata ranges the
#    reader needs and creates sparse, zero-filled bodies. This gate proves structural loadability:
#    extract, emit, compile and open. Use --full only for a future numerical/prediction assertion;
#    it downloads all five files (~4.6 GB) and verifies each whole-file md5.
./scripts/fetch_adaf_checkpoints.sh
./scripts/test_adaf_checkpoints.sh
```

**The checkpoint gate is the one you should not run with `swift test` directly.** Its wrapper fails
when the fixtures are missing *or when any test skips*, which a bare run cannot tell you: measured
on this branch, `swift test --filter ADAFCheckpointDirectoryTests` with the variable unset reports
skipped checkpoint tests and exits 0 — a green run that opened
nothing. `scripts/test_adaf_checkpoints.sh` exits 1 in that situation, and 1 again against an empty
or absent directory.

Unlike the other two, the checkpoint reader also has an **always-on** real-bytes suite. The head and
tail ranges of two published checkpoints are committed under
`Tests/NativeModelConverterTests/Fixtures/ADAF/` (CC-BY-SA-4.0 — see its `NOTICE.md` for
attribution), and the reader's entire read set — the archive's end records, its central directory,
`data.pkl` and `version` — lies inside them, so a plain `swift test` genuinely exercises it against
real bytes. Their test double also *fails* on any read outside those ranges, which is what keeps the
read set narrow: a regression that starts walking the 932 scattered local headers would work fine
against the real file and fails loudly here. The gated suite is the redundant check over freshly
fetched and optionally complete files, not the only one.

**Run all three — no command alone is sufficient.** Each script feeds one gate, so the other gate's
suites still skip. Measured on this branch: step 1 executes the 4 ONNX Runtime oracles with 0 skips;
step 2 executes 296 tests with 4 skips, and those 4 skips *are* the ONNX oracles. Only the union
covers what AGENTS.md §13 asks for. The skip counts are the quickest way to tell which gate you
forgot: with none of the three variables set the suite now skips 7 (the 5 above plus the 2 checkpoint
tests), 4 means only the reference gate was fed, and 2 means only the checkpoint gate is missing.

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

## App-side image sizing, and why normalisation stays in the graph

AIA-0680. M3a measured that no NN-spec resize mode reproduces `GeneralizedRCNNTransform`'s bilinear
(`align_corners=False`) — the closest leaves 0.1296 absolute on `[0, 1]` data — and that pinning
`min_size` to the tile size is not a cheaper way to get the same model but a **different** model,
moving boxes 19.43 px and dropping a detection. So the resize cannot live in the emitted graph. It
lives in `NativeModelImageSizing`, and the boxes come back out through its inverse.

### Two decisions, and the evidence for each

**Vision's `.scaleFit` is an identity at matched sizes.** Measured, not assumed, by
`VisionScaleFitProbeTests` driving a committed identity model through the exact layer `Detector`
uses — `VNCoreMLModel` → `VNCoreMLRequest(.scaleFit)` → `VNImageRequestHandler(ciImage:)`. Three
figures, because one number would conflate pixel-format conversion with resampling:

| | measured (raw 0…255 code units) |
|-|-|
| (a) conversion floor: `CIContext.render` into the model's own pixel format, then `MLModel.prediction` | 0.0 |
| (b) Vision `.scaleFit` at matched 64×64 | 0.0 |
| (c) Vision `.scaleFit` at mismatched 65×65 — the blindness control | 250.0 |
| **Vision against the direct prediction, elementwise** | **0.0** |

(c) is not decoration: without it, a probe that reported "identity" because it was reading nothing at
all would be indistinguishable from a real result. Taken on the iOS 26.5 simulator with an sRGB
source and a BGRA pixel format; no physical device is currently attachable (`xcrun devicectl list
devices` reports the only physical entry as unavailable, and AIA-0675 records Xcode 26.6 failing to
personalise an iOS 27-generation developer disk image for a device on iOS 26.5.2). **So the app can
pre-size and Vision will pass the buffer through untouched**, and the alternative — bypassing
`VNCoreMLRequest`'s scaling — is not needed, which matters because it would have collided with
AIA-0675 criterion 9. Nothing is wired yet: `Detector` is deliberately untouched by this slice and
the component has no non-test call site, so this records a settled design question, not a shipped
behaviour.

**Normalisation stays in the graph.** `NativeModelImagePreprocessing.imageNetRGB` already performs
exactly torchvision's arithmetic and the emitter already exercises it. The reason is not preference
but constraint: AIA-0675 criterion 9 requires a Vision detector interface, a Vision detector
interface requires an image input, and Core ML image inputs are 8-bit — `ColorSpace` offers
grayscale, RGB and BGR and nothing float. There is no float buffer an app-side normalisation could
be handed. **The app will size; the graph normalises.** ("Will": the sizing component exists and is tested,
but nothing calls it yet — see the note above.)

The elementwise row is the one the conclusion rests on. Subtracting (a) from (b) would not
establish it: those are two independent maxima that can fall on different pixels with errors in
opposite directions, so they could cancel a real divergence.

That choice fixes the padding fill. `batch_images` pads the **normalised** tensor with zeros, and
bilinear interpolation is a convex combination while the per-channel affine is linear, so the two
commute exactly: filling with the ImageNet mean **in pixel space** reproduces torchvision's zero
padding. In real arithmetic it is exact; through an 8-bit buffer it is not, because
`255 · 0.485 = 123.675` is not a representable code value. The residual is stated rather than rounded
away — per channel, `[+0.00127, −0.00110, +0.00184]` in `[0, 1]` units (`[+0.00557, −0.00490,
+0.00819]` normalised), blue worst.

### What the rules actually are

Read out of torchvision 0.23.0 rather than recalled, because the shorthand is wrong in three places:

| Rule | Source | What it says |
|-|-|-|
| Sizing | `transform.py:60` | `min(minSize/short, maxSize/long)`. The short side reaches `minSize` only when the long side has not hit `maxSize` first — and for a page-aspect tile (≈1.87, above `1333/800 = 1.66625`) it is `maxSize` that binds |
| Rounding | `functional.py:4717` | `_sym_int(size · scale)` — float64, truncated. The float32 branch at `:4698` is guarded by the tracing state and never runs in inference |
| Per-axis | `recompute_scale_factor=True` | output is `floor(in·s)` per axis, then the ratios are re-derived from those integers, so the two axes differ: 769×512 → 1201×800 is 1.561769 across and 1.5625 down |
| Padding | `transform.py:243-253` | canvas `ceil(dim/32)·32`, content copied to `[..., :H, :W]` — top-left origin, padding right and bottom. Not a centred letterbox |
| Inverse | `transform.py:306-319` | `x·(sourceW/resizedW)`, `y·(sourceH/resizedH)`, per axis, from the integer sizes |

`Geometry` therefore has no scalar `scale` field — the bug is not representable — and 646×1077 lands
on 799×1332, one pixel short on **both** axes even though `maxSize` binds.

### Evidence, and its limits

Reference figures come from **calling** `GeneralizedRCNNTransform`
(`scripts/generate_torchvision_resize_oracle.py`), not from re-deriving it. Note that
`scripts/m3a_parity_spike/criterion_transform.py:49` derives its scale from `image.shape[-1]`, the
width, which matches `_resize_image_and_masks` only for square inputs; it is correct for that file's
square probe and is deliberately not reused here.

Measured against that oracle over 825 samples: the resampler is within **9.34e-05** of torchvision in
`[0, 1]` units; the whole forward pass against torchvision's padded tensor within **4.08e-04**
normalised. Through an 8-bit buffer, which is what production can deliver, **0.00197** in `[0, 1]` —
**65.8×** better than the 0.1296 an in-graph resize leaves. Read that ratio as conservative rather
than exact: 0.00197 is the worst sampled value on a pattern chosen for maximal high-frequency content
and sits within 0.5 % of the 8-bit half-step (`0.5/255 = 0.00196`), which is a rounding *upper bound*
and suggests the resample contributes almost nothing on top of quantisation — while the 0.1296 was
measured on a real figure at an integer scale, i.e. not worst-cased the same way. Both figures come
from sampled comparisons, not exhaustive ones.

The oracle carries cases chosen to discriminate rather than to pass, including a **trap** (768×512
scales both axes by exactly 1.5625, so a single-scalar implementation passes it) and an
`align_corners=True` counter-reference the implementation must **fail** — necessary because the two
conventions agree at exactly the corners and edge midpoints a naive oracle would sample.

Tolerances are set from measurement: the residual is float32 rounding in torch's own
sampling-coordinate arithmetic, amplified by the pattern's mod-256 discontinuities. It grows with
coordinate magnitude, so the committed tolerance is **validated for canvases up to 1344** and a larger
canvas requires re-measurement.

### What this hands to the graph work (AIA-0685 through AIA-0688)

- **The pinned canvas is 1344×1344, and it is not free.** The host still applies torchvision's
  `800/1333` content transform; this is its fixed, right/bottom-padded model canvas. The page-aspect
  boundary remains `1333/800 = 1.66625`: above it, the long-side rule binds; below it, the short-side
  rule does. A tempting 1333-square canvas is not graph-valid for this FPN: its `334 → 167 → 84 → 42`
  levels cannot make the required exact ×2 top-down join at width 167. 1344 produces
  `336 → 168 → 84 → 42 → 21`, so all joins are exact and every application tile aspect fits. Its
  square anchor grid still differs from torchvision's variable `1344×N` grid; the AIA-0688 gate below
  treats that fixed-canvas difference as a numerical claim, not a structural equivalence claim.
- **Terminal suppression is a pair, not a tunable pipeline default.** The graph keeps its candidate
  boxes as `[x0, y0, x1, y1]` corners and converts to Core ML NMS's mandatory
  `[center-x, center-y, width, height]` only immediately before its first terminal layer. The complete
  path applies the strict torchvision `score > 0.05` floor to **ROI-head foreground scores** before
  the `0.5` / top-100 pass. Core ML's NMS threshold is inclusive, so it receives the smallest Float32
  value above `0.05`; the final score/box mask uses that same threshold. The second pass applies ADAF's
  class-agnostic IoU `0.2`. M3a measured
  the difference in every one of 200 trials: **73.89** boxes for the pair versus **153.07** for one
  `0.2` pass. Core ML reports a real sub-threshold slot when its first pass has zero survivors, so the
  final graph masks both the score and box with that eligibility predicate before the Vision adapter.
  The standalone NMS model remains solely because Vision requires that model type for recognized-object
  observations. Its fixed `IoU = 1` / `score = 1e-12` adapter settings and absent threshold inputs make
  that ownership explicit: the positive score floor removes only fixed-NMS zero padding, not a third
  policy pass.
- **ROI edges use a replicated feature ring, not a zero ring.** `CropResize` zeroes outside a feature
  map where torchvision `roi_align` clamps. The parity primary materialises every one of its fixed
  1,000 proposals through each ROI-pooling FPN level (`P2` through `P5`), masks those pools with
  torchvision's level mapper, and feeds their sum through the checkpoint's box head and foreground
  predictor. It slices and concatenates one copy of every edge, then adds one **feature-map pixel**
  (`1 / spatialScale` image pixels) to each `[y0, x0, y1, x1]` ROI coordinate before CropResize. A
  later host-side chunk loop may reduce that working set only by preserving this sequence exactly. The
  pinned Core ML/torchvision
  edge probe puts the **P2 synthetic edge-touching** replicate-ring residual at `7.25e-07` relative;
  its P2 interior control is `8.26e-07`, and both are below the probe's `1e-04` decision ceiling. The
  unpadded and zero-ring worst boundary variants remain at `3.35e-01` and `1.67e-01` respectively.
- **Pre-sizing means ADAF cannot use `VNCoreMLRequest.regionOfInterest` at all.** The request must run
  full-frame on an already-cropped buffer, so a pass goes from one reused `VNImageRequestHandler`
  across 15 regions to 15 handlers.
- **Cost is compute, not allocation — and measured Release, it is not a problem.** Sizing one
  393×852 region onto a 640×1344 canvas takes **4.8 ms** built with `-O`, so a 15-region pass costs
  about **0.07 s** against the detect path's roughly 3-second cadence. The scalar Swift loop is
  therefore sufficient and neither Accelerate nor a separable two-pass is needed. The Debug figure is
  **506 ms** per region (≈7.6 s per pass), a 105× difference, which is exactly why this file insists
  on measuring Release: quoting the Debug number would have argued for a rewrite that the evidence
  does not support. `testResample_reportsItsCostForTheWiringSlice` prints the Debug figure on every
  run; the Release figure comes from compiling the same call with `swiftc -O`, because
  `swift test -c release` currently fails on an unrelated DEBUG-only test helper
  (`queuedJobCountForTesting`).

### Converted-detector parity gate (AIA-0688)

Run `bash scripts/test_adaf_fasterrcnn_parity.sh` after fetching a **dense** `OD_ringfort.tar` with
`scripts/fetch_adaf_checkpoints.sh --full`. The gate emits and compiles the detector, drives it through
`VNCoreMLRequest` on the committed Ringfort figure, and compares its source-space detection set with
torchvision's own transform, backbone, RPN, RoI heads, postprocess, and ADAF's final NMS. The runner
dumps the exact post-ImageIO, 8-bit fixed canvas sent to Core ML; torchvision receives those same
bytes after the emitted ImageNet affine. It still calls `GeneralizedRCNNTransform` to establish the
source/content geometry and records any reconstructed-canvas byte mismatch, so an almost-identical
resizer cannot silently become the reference input. Its JSON records matched pairs,
appeared/disappeared detections, maximum box motion, and maximum score delta.
It also runs a deterministic blank tile through both engines, so the real terminal NMS mask must keep
the zero-survivor result empty. An out-of-class archaeological figure is not substituted for this
case because it can have real false positives in the torchvision oracle.

The report is entitled to say `verified` only when no source figure has a mismatch and each checkpoint
has enough *aggregate* matched detections to exercise the score and box budgets. `--all-checkpoints`
expands the diagnostic to every detector; the all-archaeology model runs every committed figure
because a single Ringfort result exercises only one detection. A one-detection AO figure remains
explicitly `UNDERPOWERED` in the per-figure report, while the checkpoint-level coverage verdict pools
its required, disjoint figures. A failure, an unmeasured figure, or underpowered checkpoint coverage
leaves the artifact `structurally-matched` and is evidence to investigate, not a way to certify it.

The ADAF extractor still deliberately rounds checkpoint values to Float16 for its bounded on-disk
blob, but the detector graph widens those exact binary16 values into Float32 tensors before Core ML
emission. On `.cpuOnly`, that preserves Float32 accumulation through the RPN and ROI head, where a
sub-millipoint score reversal could otherwise change a greedy-NMS survivor. This is a CPU-oracle
choice, not an ANE claim: the Neural Engine may still execute those values in its documented
half-precision path and must be assessed with the device-level detection-set run above.

The Mac M3a `.all` trunk measurement was **2.66e-02** and had collapsed the score-margin concern to
**3.8×**. The real iPhone 16 Pro Max (iOS 26.5.2) result is materially better: over 16 deterministic
runs, `.cpuOnly` versus `.all` measured **1.644224e-03** on scores and **2.341270e-03** on boxes;
`.cpuAndGPU` was bit-identical to CPU while `.cpuAndNeuralEngine` equalled `.all`, proving the
remaining difference is the ANE fp16 path and about 16× tighter than the Mac result. This local gate
runs `cpuOnly`, so it proves conversion semantics but not device/ANE parity. Before a device claim,
rerun the emitted detector and this same detection-set comparison on that iPhone across the committed
figures; the elementwise device values alone cannot say whether a box moves or a detection appears.

The device detection-set closeout (AIA-0688) ran the emitted detector against the torchvision oracle
on that iPhone — OD_AO / barrows.jpg, exact 1344×1344 canvas, three `-test-iterations` runs with
relaunch, tool versions recorded by the gate report and the device OS version printed by the test.
`.cpuOnly` held every decision-rule budget in all three runs (the macOS runner baseline for the same
fixture is 0.00033 px max box shift and 3e-06 max score delta). The original shipping-default `.all`
path kept the detection set identical — nothing appeared or disappeared — stayed inside the 0.01
score budget, and left the blank tile empty, but moved one box by **3.913543701171875 px**, identically
in every run, breaching the 1 px box budget that the vectoriser's raster quantisation justifies. The
3.8× question was therefore answered on device numbers: **the score margin survives the device; the
box budget does not.**

The fix is an explicit runtime policy in the emitted model's `creatorDefined` metadata. The pinned
ADAF Faster R-CNN producer requests `.cpuAndGPU`, and `DeepDriver.loadModel` honors that policy before
Vision receives the model; models without a recognized policy retain Core ML's default placement.
This is not a CPU fallback: it leaves the phone's dedicated GPU available and excludes only the
Neural Engine's reduced-precision path. The reason is now localized: #676's physical probe showed
the ROI box-head scores and deltas changing on `.cpuAndNeuralEngine`/`.all` while `.cpuAndGPU` was
bit-identical to `.cpuOnly`; the box decoder's exponential width/height expansion turns that small
delta into the 3.9135 px final shift. `ADAFDetectorDeviceParityTests` exercises the production
loader and asserts the CPU, GPU and torchvision detection-set budgets, while the original `.all`
measurement remains recorded as the reason for excluding ANE.

## Sources

Apple documents the public protobuf Core ML model specification and states that it can be created
from languages supported by protobuf. It recommends ML Program for new Core ML features, while the
neural-network model format remains broadly deployable. The unified conversion documentation lists
TensorFlow and PyTorch source formats; the historic ONNX converter repository says it is no longer
maintained.

- [Core ML model format and protobuf specification](https://apple.github.io/coremltools/docs-guides/source/mlmodel.html)
- [Core ML source and target conversion formats](https://apple.github.io/coremltools/docs-guides/source/target-conversion-formats.html)
- [Historical ONNX-to-Core-ML converter status](https://github.com/onnx/onnx-coreml)
