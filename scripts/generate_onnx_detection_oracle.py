#!/usr/bin/env python3
"""Independent detection oracle for ONNXConversionIntegrationTests (anchor-free / YOLOv8-family).

Reproduces the Swift test's deterministic LCG noise image byte-for-byte, runs onnxruntime on the raw
ONNX export (whose `output0` is `[1, 4+C, N]` with box centres/sizes and per-class sigmoid scores
already decoded in-graph), and applies non-maximum suppression the same way Core ML's built-in
`NonMaximumSuppression` does with `perClass = false`: a box's score is its max class score; boxes
below the threshold are dropped; the rest are sorted by score and greedily kept unless they overlap
an already-kept box at IoU greater than the threshold (across all classes).

The printed `(classIndex, confidence, cx, cy, w, h)` rows are the `expectedBoxes` baked into
Tests/NativeModelConverterTests/Fixtures/ONNXConversionModels.json — a converted Core ML detector
must reproduce them. onnxruntime (not the converter) is the source of truth. Choose a confidence
threshold that leaves survivors in a wide score gap so float drift cannot change the box count.

Preprocessing matches the converter's anchor-free path exactly: RGB, divided by 255 (the graph
carries no in-graph scaling), NCHW `[1, 3, H, W]`.

Requires: onnxruntime, numpy.

Usage:
  generate_onnx_detection_oracle.py MODEL.onnx 0xSEED CONFIDENCE [IOU=0.45] [SIZE=640]
"""
import sys

import numpy as np
import onnxruntime as ort

# The exact 64-bit LCG the Swift test draws pixel bytes from (see ONNXConversionIntegrationTests).
LCG_MULTIPLIER = 6_364_136_223_846_793_005
LCG_INCREMENT = 1_442_695_040_888_963_407
UINT64_MASK = (1 << 64) - 1


def noise_rgb(width: int, height: int, seed: int) -> np.ndarray:
    """The deterministic RGB noise image: three sequential LCG draws per pixel, row-major."""
    state = seed & UINT64_MASK
    image = np.empty((height, width, 3), np.float32)
    for y in range(height):
        for x in range(width):
            channels = []
            for _ in range(3):
                state = (state * LCG_MULTIPLIER + LCG_INCREMENT) & UINT64_MASK
                channels.append((state >> 33) & 0xFF)
            image[y, x, 0], image[y, x, 1], image[y, x, 2] = channels
    return image


def iou_cxcywh(a: np.ndarray, b: np.ndarray) -> float:
    ax1, ay1, ax2, ay2 = a[0] - a[2] / 2, a[1] - a[3] / 2, a[0] + a[2] / 2, a[1] + a[3] / 2
    bx1, by1, bx2, by2 = b[0] - b[2] / 2, b[1] - b[3] / 2, b[0] + b[2] / 2, b[1] + b[3] / 2
    intersection_width = max(0.0, min(ax2, bx2) - max(ax1, bx1))
    intersection_height = max(0.0, min(ay2, by2) - max(ay1, by1))
    intersection = intersection_width * intersection_height
    union = a[2] * a[3] + b[2] * b[3] - intersection
    return intersection / union if union > 0 else 0.0


def main() -> int:
    if len(sys.argv) < 4:
        print(__doc__)
        return 2
    model_path = sys.argv[1]
    seed_text = sys.argv[2]
    if not seed_text.startswith("0x"):
        print(f"Seed must be a 0x-prefixed hex literal (matching the Swift test): {seed_text!r}", file=sys.stderr)
        return 2
    seed = int(seed_text[2:], 16)
    confidence_threshold = float(sys.argv[3])
    iou_threshold = float(sys.argv[4]) if len(sys.argv) > 4 else 0.45
    size = int(sys.argv[5]) if len(sys.argv) > 5 else 640

    rgb = noise_rgb(size, size, seed) / 255.0
    nchw = np.transpose(rgb, (2, 0, 1))[None, ...].astype(np.float32)
    session = ort.InferenceSession(model_path)
    output = session.run(None, {session.get_inputs()[0].name: nchw})[0][0]  # [4+C, N]
    boxes = output[0:4, :].T  # [N, 4] cx, cy, w, h
    scores = output[4:, :].T  # [N, C]
    max_score = scores.max(axis=1)
    class_index = scores.argmax(axis=1)

    candidates = np.where(max_score >= confidence_threshold)[0]
    order = candidates[np.argsort(-max_score[candidates])]
    kept: list[int] = []
    for index in order:
        if all(iou_cxcywh(boxes[index], boxes[other]) <= iou_threshold for other in kept):
            kept.append(int(index))

    print(f"# {model_path.split('/')[-1]} seed={sys.argv[2]} conf={confidence_threshold} "
          f"iou={iou_threshold}: {len(kept)} box(es)")
    for index in kept:
        box = boxes[index]
        print(f"classIndex={int(class_index[index])} confidence={max_score[index]:.4f} "
              f"x={box[0]:.4f} y={box[1]:.4f} width={box[2]:.4f} height={box[3]:.4f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
