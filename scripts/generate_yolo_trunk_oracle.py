#!/usr/bin/env python3
"""Regenerates a YOLO trunk oracle fixture (raw output0 samples) for the converter tests.

The trunk tests (e.g. YOLO11TrunkConversionTests) feed the deterministic flat pattern
((i*17+11) % 256)/255 over [1,3,H,W] into the converted Core ML model and compare sampled
output0 values against onnxruntime on the source export. Samples deliberately include the
top-scoring class entries so a conversion bug that zeroes or attenuates the score channels
fails the test — near-zero-only samples under a loose tolerance verify nothing (2026-07-21
review of PR #492).

Usage:
  generate_yolo_trunk_oracle.py MODEL.onnx [SIZE=640] [TOP_SCORES=96] [SPREAD=384]

Prints the "samples" JSON array plus suggested tolerances to merge into the fixture.
Requires: onnxruntime, numpy.
"""
import json
import sys

import numpy as np
import onnxruntime as ort


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    model_path = sys.argv[1]
    size = int(sys.argv[2]) if len(sys.argv) > 2 else 640
    top_scores = int(sys.argv[3]) if len(sys.argv) > 3 else 96
    spread = int(sys.argv[4]) if len(sys.argv) > 4 else 384

    session = ort.InferenceSession(model_path, providers=["CPUExecutionProvider"])
    input_name = session.get_inputs()[0].name
    output_name = session.get_outputs()[0].name

    count = 3 * size * size
    flat = ((np.arange(count, dtype=np.int64) * 17 + 11) % 256).astype(np.float32) / 255.0
    output = session.run([output_name], {input_name: flat.reshape(1, 3, size, size)})[0]
    channels, columns = output.shape[1], output.shape[2]
    flat_output = output.reshape(-1)

    score_area = output[0, 4:, :].reshape(-1)
    # Top class scores (offset back to flat output0 indices past the 4 coordinate rows).
    top_idx = np.argsort(score_area)[-top_scores:] + 4 * columns
    # Deterministic evenly-spaced spread over the whole tensor: coordinates, objectness-free
    # score background, everything. Complements rather than replaces the top-score picks.
    spread_idx = np.linspace(0, channels * columns - 1, spread, dtype=np.int64)
    indices = np.unique(np.concatenate([top_idx, spread_idx]))

    samples = [
        {"index": int(i), "value": float(flat_output[i])}
        for i in sorted(indices, key=int)
    ]
    coords = output[0, :4, :]
    print(json.dumps({"samples": samples}, indent=1))
    print(
        f"// {len(samples)} samples; max |coordinate| {np.abs(coords).max():.3f}; "
        f"top sampled score {score_area.max():.6g}; "
        f"pick tolerances a few times the measured Core ML conversion drift and well "
        f"below the top sampled score",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
