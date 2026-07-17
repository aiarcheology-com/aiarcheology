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
  "weights": "weights.bin",
  "weightsSHA256": "..."
}
```

The Swift package now reads the directory as a fixed-layout package: it rejects symbolic links and
unexpected filenames, enforces manifest/graph/weights size limits, verifies the SHA-256 digest of
the full weights file, validates `graph.json`, and verifies that every declared weight range fits
inside `weights.bin`. The app import path will use the emitter's verified-package entry point;
the lower-level graph-and-weights API remains available for trusted test and exporter tooling.

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

## Python reference and parity suite

The exporter and native emitter must be tested as a pair. For every golden model:

1. Export the original PyTorch model to the native graph package.
2. Convert the source PyTorch export with current `coremltools` to the reference Core ML model.
3. Convert the native graph package with the app's emitter.
4. Compare model interfaces, tensor types/shapes, graph operations/parameters, weights, and final
   numerical outputs. On a mismatch, compare saved intermediate tensors in topological order.

Golden suites should begin with a tiny Conv/ReLU/Linear network, then a MobileNetV2 classifier, then
an SSD-MobileNet detector. Each fixture uses fixed inputs and records Float32 tolerance first;
Float16 has explicit, model-specific tolerances. Unsupported operations must fail with the operation
name and kind rather than falling back silently.

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
4. Add regular pooling, reshape, transpose, concatenate, softmax, and the remaining elementwise
   operations. Add the Python exporter and use its existing fixed inputs and coremltools output as
   the parity oracle for a real MobileNetV2 package.
5. Add the Python exporter and parity runner. Only then add the ONNX reader, lowering it to the
   same graph v1 representation.
6. Add detector adapters and the extra operations only as parity fixtures require them.

## MobileNetV2 reference fixtures

The package test fixture records the exact URLs and SHA-256 values for the supplied Apple
MobileNetV2 FP16 and INT8-LUT models. `scripts/test_native_model_converter.sh` downloads them to
a temporary directory, verifies their hashes, compiles them with Core ML as part of `swift test`,
and runs a deterministic solid-red image probe. This is terminal-only and does not start a simulator.
These are external golden artifacts: they validate the eventual converter's output contract, but do
not replace the needed PyTorch/ONNX source export and numerical parity fixtures.

## Sources

Apple documents the public protobuf Core ML model specification and states that it can be created
from languages supported by protobuf. It recommends ML Program for new Core ML features, while the
neural-network model format remains broadly deployable. The unified conversion documentation lists
TensorFlow and PyTorch source formats; the historic ONNX converter repository says it is no longer
maintained.

- [Core ML model format and protobuf specification](https://apple.github.io/coremltools/docs-guides/source/mlmodel.html)
- [Core ML source and target conversion formats](https://apple.github.io/coremltools/docs-guides/source/target-conversion-formats.html)
- [Historical ONNX-to-Core-ML converter status](https://github.com/onnx/onnx-coreml)
