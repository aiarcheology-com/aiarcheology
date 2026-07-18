#!/usr/bin/env python3
"""Independent oracle for ONNXConversionIntegrationTests.

Prints the top-1 ImageNet label that onnxruntime predicts for solid-color probes of an ONNX image
classifier. These labels are the `expectedClassLabel` values baked into
Tests/NativeModelConverterTests/Fixtures/ONNXConversionModels.json — a converted Core ML model must
reproduce them. Re-run this when adding a model or a probe, or to re-verify an expectation.

Preprocessing matches the converter: per-channel ImageNet normalization on a uniform RGB image,
NCHW [1,3,H,W]. onnxruntime (not the converter) is the source of truth here.

Requires: onnxruntime, numpy, torchvision (for the label list, in torchvision/ONNX-Zoo order).

Usage:
  generate_onnx_probe_labels.py MODEL.onnx [WIDTH HEIGHT]
  # then reads probes as "R,G,B" lines from stdin, or uses a default probe set.

Example:
  generate_onnx_probe_labels.py mobilenetv2-10.onnx
  printf '255,0,0\\n0,255,0\\n' | generate_onnx_probe_labels.py mobilenetv2-10.onnx
"""
import sys
import numpy as np
import onnxruntime as ort
import torchvision

MEAN = np.array([0.485, 0.456, 0.406], np.float32)
STD = np.array([0.229, 0.224, 0.225], np.float32)
DEFAULT_PROBES = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (128, 128, 128)]


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    model_path = sys.argv[1]
    width = int(sys.argv[2]) if len(sys.argv) > 2 else 224
    height = int(sys.argv[3]) if len(sys.argv) > 3 else 224

    categories = torchvision.models.MobileNet_V2_Weights.IMAGENET1K_V1.meta["categories"]
    session = ort.InferenceSession(model_path)
    input_name = session.get_inputs()[0].name

    probes = DEFAULT_PROBES
    if not sys.stdin.isatty():
        parsed = []
        for line in sys.stdin:
            line = line.strip()
            if line:
                parsed.append(tuple(int(v) for v in line.split(",")))
        if parsed:
            probes = parsed

    for red, green, blue in probes:
        normalized = (np.array([red, green, blue], np.float32) / 255.0 - MEAN) / STD
        tensor = np.empty((1, 3, height, width), np.float32)
        for channel in range(3):
            tensor[0, channel, :, :] = normalized[channel]
        logits = session.run(None, {input_name: tensor})[0].reshape(-1)
        print(f"({red},{green},{blue}) -> {categories[int(logits.argmax())]!r}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
