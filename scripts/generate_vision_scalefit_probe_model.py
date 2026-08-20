#!/usr/bin/env python3
"""Build the identity Core ML model that AIA-0680's Vision probe drives.

AIA-0680's first acceptance criterion asks whether `VNCoreMLRequest`'s `.scaleFit` is an identity
when the image already matches the model's input size. Answering it needs a model that hands back
exactly what it was given, so the pixels Vision fed it can be read: an **image input** and a **raw
multi-array output**, with nothing in between.

This repository's own emitter cannot express that, for two independent reasons, both deliberate:

* `NativeModelCoreMLEmitter` declares an image input only when it has resolved a classifier or
  detector interface (`NativeModelCoreMLEmitter.swift:598`). A raw predictor keeps a multi-array
  input, which Vision will not accept.
* Routing around that by declaring a classifier does not help: `classifierPlan`
  (`NativeModelCoreMLEmitter.swift:947-980`) appends a softmax over the class axis unless the graph
  already ends in one, which destroys the very values the probe exists to read. And `identity` is
  explicitly not an operation the emitter implements (`NATIVE_MODEL_CONVERSION.md:358`).

So the probe model is built once, here, with the same `NeuralNetworkBuilder` the M3a spike used, and
committed as a fixture. It is a few kilobytes: an affine activation with alpha 1 and beta 0 has no
weights.

No image scaling or bias is set on the input, so Core ML hands the network raw `[0, 255]` pixels and
the output is literally the input — which is what makes a comparison against the source bytes
meaningful.

Run:

    .venv-m3a/bin/python scripts/generate_vision_scalefit_probe_model.py

Writes ios/MLBrowserUnitTests/Fixtures/VisionScaleFitProbe.mlmodel.
"""

from __future__ import annotations

import sys
from pathlib import Path

import coremltools as ct
from coremltools.models import datatypes
from coremltools.models.neural_network import NeuralNetworkBuilder
from coremltools.proto import FeatureTypes_pb2 as ft

SIDE = 64
REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_PATH = REPOSITORY_ROOT / "ios" / "MLBrowserUnitTests" / "Fixtures" / "VisionScaleFitProbe.mlmodel"


def main() -> int:
    builder = NeuralNetworkBuilder(
        [("image", datatypes.Array(3, SIDE, SIDE))],
        [("passthrough", datatypes.Array(3, SIDE, SIDE))],
        disable_rank5_shape_mapping=True,
    )
    # y = 1·x + 0. The cheapest identity Core ML has, and one that cannot be optimised into a
    # different numerical path the way a no-op reshape might.
    builder.add_activation(
        name="identity",
        non_linearity="LINEAR",
        input_name="image",
        output_name="passthrough",
        params=[1.0, 0.0],
    )

    spec = builder.spec
    image_input = spec.description.input[0]
    image_input.type.imageType.width = SIDE
    image_input.type.imageType.height = SIDE
    image_input.type.imageType.colorSpace = ft.ImageFeatureType.RGB

    spec.description.metadata.shortDescription = (
        "Identity pass-through, AIA-0680. Image input, raw multi-array output, no scaling: whatever "
        "Vision hands the model comes straight back out, so a test can compare it against the bytes "
        "it started from."
    )
    spec.description.metadata.author = "scripts/generate_vision_scalefit_probe_model.py"

    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    ct.models.MLModel(spec).save(str(OUTPUT_PATH))

    print(f"wrote {OUTPUT_PATH.relative_to(REPOSITORY_ROOT)} ({OUTPUT_PATH.stat().st_size} bytes)")
    print(f"  input : image {SIDE}x{SIDE} RGB, no scaling (raw 0…255)")
    print(f"  output: multi-array [3, {SIDE}, {SIDE}]")
    return 0


if __name__ == "__main__":
    sys.exit(main())
