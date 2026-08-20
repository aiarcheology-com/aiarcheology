#!/usr/bin/env python3
"""Generate the reference figures for AIA-0680's app-side image sizing.

The Swift side of this ticket resizes an ADAF input the way `GeneralizedRCNNTransform` does, pads it
the way `batch_images` does, and hands the result to a Core ML graph that carries torchvision's
normalisation. This script produces the numbers that claim is asserted against, and it produces them
by **calling torchvision**, not by re-deriving what torchvision is documented to do.

That distinction is the whole point. AIA-0675's weight-path slice shipped a "verified against real
bytes" test that turned out to be a closed loop — it compared the implementation against a second
copy of its own logic — and review caught it only late. `scripts/m3a_parity_spike/criterion_transform.py`
carries a smaller instance of the same hazard: its `torchvision_resize` helper derives the scale from
`image.shape[-1]`, the *width*, which matches `_resize_image_and_masks` only for square inputs. It was
written for a square probe and is correct there. It is not correct for the non-square cases this
ticket exists to pin, so nothing here reuses it.

What is emitted, per case:

* the exact integer geometry — resized size, canvas size, pad edges, and the two per-axis scales.
  `recompute_scale_factor=True` means the output size is `floor(in · s)` per axis and the kernel then
  re-derives `out_i / in_i`, so the horizontal and vertical scales differ whenever the floor rounds
  differently. Sampled pixel values alone cannot catch a correct resample laid out on a wrong canvas,
  which is why the geometry is committed as literals beside the samples.
* `paddedNormalisedSamples` — points sampled from the tensor the network actually receives, i.e. the
  output of the whole transform. Some of them deliberately land in the padded margin, so the pad
  value is pinned rather than assumed.
* `resizedRawSamples` — the same resize applied to the raw `[0, 1]` image with no normalisation, so a
  Swift failure can be attributed to the resampler or to the normalisation/padding, rather than
  leaving both suspect.

Run it with the pinned interpreter from the M3a spike (`scripts/m3a_parity_spike/README.md`):

    .venv-m3a/bin/python scripts/generate_torchvision_resize_oracle.py

Writes Tests/NativeModelConverterTests/Fixtures/TorchvisionResizeOracle.json.
"""

from __future__ import annotations

import json
import platform
import sys
from pathlib import Path

import numpy as np
import torch
import torchvision
from torchvision.models.detection.transform import GeneralizedRCNNTransform, _resize_image_and_masks

# torchvision's own defaults for `fasterrcnn_resnet50_fpn_v2`, which is the architecture M3a measured
# and M3c is assembling. They are stated here rather than imported so the committed JSON records what
# the numbers were produced under.
MIN_SIZE = 800
MAX_SIZE = 1333
SIZE_DIVISIBLE = 32
IMAGE_MEAN = [0.485, 0.456, 0.406]
IMAGE_STD = [0.229, 0.224, 0.225]

REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_PATH = (
    REPOSITORY_ROOT / "Tests" / "NativeModelConverterTests" / "Fixtures" / "TorchvisionResizeOracle.json"
)

# Every case states the failure it exists to catch, because a case list without that is indistinguishable
# from a case list that happens to pass.
CASES = [
    {
        "name": "square512to800",
        "emitRawSamples": True,
        "width": 512,
        "height": 512,
        "pins": "The ticket's own figure: scale 1.5625, the non-integer factor no NN-spec resize mode "
                "can express. Square, so it says nothing about per-axis scales.",
        "falsifyAlignCorners": True,
    },
    {
        "name": "nonSquare769x512",
        "width": 769,
        "height": 512,
        "pins": "The two axes floor differently — 1201/769 against 800/512 — so an implementation "
                "carrying a single scalar scale fails here.",
    },
    {
        "name": "nonSquare768x512",
        "width": 768,
        "height": 512,
        "pins": "The trap. Non-square, but both axes scale by exactly 1.5625, so a single-scalar "
                "implementation PASSES. Present so the suite cannot mistake it for coverage.",
    },
    {
        "name": "pageAspectRegion393x852",
        "width": 393,
        "height": 852,
        "pins": "A third of a portrait phone snapshot, aspect 2.168. Above 1333/800 = 1.66625, so "
                "max_size binds and the short side never reaches min_size — the case the "
                "'scales the short side to min_size' shorthand gets wrong.",
    },
    {
        "name": "downscale2000x1500",
        "emitRawSamples": True,
        "width": 2000,
        "height": 1500,
        "pins": "Scale below 1. A half-pixel rule implemented for upsampling only breaks here, and it "
                "is the one case where the two align_corners conventions also disagree at the low "
                "corner, because there the false-convention coordinate is positive and unclamped.",
        "falsifyAlignCorners": True,
    },
    {
        "name": "knifeEdge646x1077",
        "emitRawSamples": True,
        "width": 646,
        "height": 1077,
        "pins": "The floor knife-edge. max_size binds, yet 1077 · (1333/1077) evaluates just below "
                "1333 in float64, so the long side lands on 1332 and the short on 799 — one pixel "
                "short on BOTH axes. An implementation that assumes the binding side reaches its "
                "limit exactly, or that evaluates the product in a different precision or order, "
                "disagrees here and nowhere else in this list.",
    },
    {
        "name": "boundaryAspect800x1333",
        "width": 800,
        "height": 1333,
        "pins": "Sits exactly on the 1333/800 = 1.66625 aspect boundary where the binding rule "
                "changes hands, and both candidate scales come out at exactly 1.0 — so the resize is "
                "an identity and only the padding acts. Pins the degenerate branch and the pad value "
                "together. It is deliberately NOT named for a tie-break: the two scales being equal "
                "at 1.0 exercises no tie-break at all, since min() returns the same number either "
                "way. A scan of long sides 801…6000 for two candidate scales within 1e-12 of each "
                "other that straddle a floor boundary found only exact-ratio coincidences "
                "(1333x800, 2666x1600, 3999x2400, 5332x3200), all of which land on integers; no "
                "non-trivial contested tie exists in that range.",
    },
    {
        "name": "degenerate1x1",
        "width": 1,
        "height": 1,
        "pins": "The smallest input the trust boundary can be handed. Exercises the low-side clamp, "
                "where the align_corners=False source coordinate 0.5·a − 0.5 is negative and has to "
                "be pinned to source pixel 0 rather than read out of bounds.",
    },
]


def deterministic_image(width: int, height: int) -> np.ndarray:
    """`((c·31 + y·7 + x·13) mod 256)` as float32, planar CHW, in [0, 255].

    Integer-valued, so it is exact in float32 *and* exact through a uint8 buffer — which means any
    disagreement between Swift and torch is the resampler, never the input. The same pattern already
    backs the ONNX trunk oracles in this suite (`Fixtures/YOLOv8TrunkOracle.json`).
    """
    channels = np.arange(3).reshape(3, 1, 1)
    rows = np.arange(height).reshape(1, height, 1)
    columns = np.arange(width).reshape(1, 1, width)
    return ((channels * 31 + rows * 7 + columns * 13) % 256).astype(np.float32)


def sample_positions(channels: int, height: int, width: int, content_height: int, content_width: int) -> list:
    """Where to look, chosen so the sampling is not blind to the most likely wrong implementation.

    Corners and edge midpoints are the obvious choices and they are here — but on their own they are
    close to worthless, and the reason is worth writing down. Let `a = in/out` be the ratio the
    `align_corners=False` rule uses and `b = (in-1)/(out-1)` the one `align_corners=True` uses. The
    divergence between the two source coordinates is `(a - b)·d + 0.5·(a - 1)`, whose zero sits at
    `d = (out - 1)/2` for *every* in/out pair — the edge midpoint, always. At the low corner the
    `align_corners=False` coordinate is negative for an upscale and clamps to source pixel 0, which
    is where `align_corners=True` already is; at the high corner both land on `in - 1`. So corners
    and midpoints are precisely the positions where the two conventions agree, and a suite that
    sampled only those would pass a resampler built on the wrong one.

    Hence three more families: the near-corner positions `(1, 1)` … `(H-2, W-2)`, where the
    divergence is at its largest; a contiguous 48-pixel sweep along one row and one column, which
    covers a whole phase period of any scale factor with a denominator up to 26 (1.5625 = 25/16 has
    period 25) rather than hoping a hand-picked point lands in an interesting phase; and a coprime
    lattice so the samples do not all sit on one source row.

    Padded positions are included wherever padding exists, because the fill value is a claim this
    ticket makes and therefore a claim it has to pin.
    """
    rows = {0, 1, content_height // 2, content_height - 2, content_height - 1, height - 1}
    columns = {0, 1, content_width // 2, content_width - 2, content_width - 1, width - 1}
    positions = set()
    for channel in range(channels):
        for row in sorted(rows):
            for column in sorted(columns):
                if 0 <= row < height and 0 <= column < width:
                    positions.add((channel, row, column))
        sweep_row = min(content_height - 1, 3)
        for column in range(min(26, content_width)):
            positions.add((channel, sweep_row, column))
        sweep_column = min(content_width - 1, 3)
        for row in range(min(26, content_height)):
            positions.add((channel, row, sweep_column))
        for step in range(16):
            positions.add((channel, (step * 37 + channel * 5) % height, (step * 53 + channel * 7) % width))
    return sorted(positions)


def compact(value) -> float:
    """Nine significant digits — enough to round-trip a float32 exactly, and half the bytes of the
    full double representation this fixture would otherwise carry for every sample."""
    return float(f"{float(value):.9g}")


def build_case(case: dict) -> dict:
    width, height = case["width"], case["height"]
    pixels = deterministic_image(width, height)

    transform = GeneralizedRCNNTransform(
        min_size=MIN_SIZE, max_size=MAX_SIZE, image_mean=IMAGE_MEAN, image_std=IMAGE_STD
    )
    # `GeneralizedRCNNTransform` is an `nn.Module`, so a freshly built one has `training == True`, and
    # `resize()` branches on it: eval reads `self.min_size[-1]` while training calls
    # `torch_choice(self.min_size)` and consults `_skip_resize`. With a single-element `min_size` both
    # branches land on the same number today, but an oracle produced on a code path inference never
    # takes is an oracle for a different program — and a later multi-element `min_size` would silently
    # randomise it. The assert is here so the JSON's `training: false` is a checked fact.
    transform.eval()
    assert transform.training is False, "the oracle must be produced on the inference branch"
    assert transform.size_divisible == SIZE_DIVISIBLE, (
        f"torchvision's size_divisible is {transform.size_divisible}, not the {SIZE_DIVISIBLE} recorded here"
    )

    # The whole transform, as the detector runs it: normalise the [0, 1] image, resize, then batch —
    # which is where the padding happens.
    image_list, _ = transform([torch.from_numpy(pixels / 255.0)])
    padded = image_list.tensors[0].numpy()
    resized_height, resized_width = image_list.image_sizes[0]
    canvas_height, canvas_width = padded.shape[-2:]

    # The resize alone, on the raw [0, 1] image, through torchvision's own function — so a Swift
    # failure can be localised to the resampler rather than leaving resampler and normalisation both
    # suspect. `min_size[-1]` is what `GeneralizedRCNNTransform.resize` passes in eval mode
    # (transform.py:190).
    raw_resized, _ = _resize_image_and_masks(
        torch.from_numpy(pixels / 255.0), transform.min_size[-1], transform.max_size, None, None
    )
    raw_resized = raw_resized.numpy()
    assert raw_resized.shape[-2:] == (resized_height, resized_width), (
        f"{case['name']}: the standalone resize disagrees with the transform's own image_sizes "
        f"{raw_resized.shape[-2:]} vs {(resized_height, resized_width)}"
    )

    padded_positions = sample_positions(3, canvas_height, canvas_width, resized_height, resized_width)
    resized_positions = sample_positions(3, resized_height, resized_width, resized_height, resized_width)

    # The same resize under the *other* convention. `align_corners=True` is the single most likely
    # wrong implementation of this component — it is a one-word difference, it produces a
    # plausible-looking image, and it agrees with the correct rule at exactly the corners and edge
    # midpoints an unwary oracle would sample. Committing it lets the Swift suite assert that the
    # implementation *fails* against it, which is the only way a passing test proves the convention
    # was chosen rather than guessed.
    align_corners_samples = []
    if case.get("falsifyAlignCorners"):
        wrong = torch.nn.functional.interpolate(
            torch.from_numpy(pixels / 255.0)[None],
            size=(resized_height, resized_width),
            mode="bilinear",
            align_corners=True,
        )[0].numpy()
        align_corners_samples = [
            {"c": c, "y": y, "x": x, "value": compact(wrong[c, y, x])} for c, y, x in resized_positions
        ]

    return {
        "name": case["name"],
        "pins": case["pins"],
        "sourceWidth": width,
        "sourceHeight": height,
        "resizedWidth": int(resized_width),
        "resizedHeight": int(resized_height),
        "canvasWidth": int(canvas_width),
        "canvasHeight": int(canvas_height),
        # Right and bottom only: `batch_images` copies the content into `[..., :H, :W]` of a zero
        # canvas (transform.py:250-253). Nothing is centred, and nothing pads left or top.
        "padRight": int(canvas_width - resized_width),
        "padBottom": int(canvas_height - resized_height),
        "scaleX": float(resized_width) / float(width),
        "scaleY": float(resized_height) / float(height),
        "paddedNormalisedSamples": [
            {"c": c, "y": y, "x": x, "value": compact(padded[c, y, x])} for c, y, x in padded_positions
        ],
        "resizedRawSamples": [
            {"c": c, "y": y, "x": x, "value": compact(raw_resized[c, y, x])} for c, y, x in resized_positions
        ] if case.get("emitRawSamples") else [],
        "alignCornersTrueSamples": align_corners_samples,
    }


def degenerate_axis_reference() -> list:
    """Resizes that collapse an axis to a single pixel, straight from `F.interpolate`.

    These exist because `align_corners=False` and `align_corners=True` disagree about what a one-pixel
    output samples, and it is easy to implement the wrong one. ATen's `area_pixel_compute_scale` does
    carry an `output_size > 1 ? ... : 0` guard, but it sits inside the `align_corners=True` branch;
    under `align_corners=False` the scale stays `input/output`, so the single sample lands on the
    source *centre*. Resizing [10, 20, 30, 40] to length one gives 25.0 that way and 10.0 the other.

    A one-pixel axis is reachable from the real sizing rule, not just from a unit test: a 2x2000
    region binds on max_size and resizes to 1x1333.
    """
    cases = []
    for name, values, shape, target in [
        ("row4to1", [10.0, 20.0, 30.0, 40.0], (1, 1, 4), (1, 1)),
        ("square5to1", [float(v) for v in range(25)], (1, 5, 5), (1, 1)),
        ("column6to1", [1.0, 2.0, 4.0, 8.0, 16.0, 32.0], (1, 6, 1), (1, 1)),
        ("wide8to3", [float(v) for v in range(8)], (1, 1, 8), (1, 3)),
    ]:
        tensor = torch.tensor(values, dtype=torch.float32).reshape(1, *shape)
        out = torch.nn.functional.interpolate(tensor, size=target, mode="bilinear", align_corners=False)
        cases.append({
            "name": name,
            "channels": shape[0],
            "sourceHeight": shape[1],
            "sourceWidth": shape[2],
            "targetHeight": target[0],
            "targetWidth": target[1],
            "source": [compact(v) for v in values],
            "expected": [compact(v) for v in out.flatten().tolist()],
        })
    return cases


def main() -> int:
    oracle = {
        "comment": (
            "Reference figures for AIA-0680, produced by calling torchvision's GeneralizedRCNNTransform "
            "rather than by re-implementing it. Regenerate with "
            ".venv-m3a/bin/python scripts/generate_torchvision_resize_oracle.py"
        ),
        "generator": "scripts/generate_torchvision_resize_oracle.py",
        "environment": {
            "python": platform.python_version(),
            "torch": torch.__version__,
            "torchvision": torchvision.__version__,
            "numpy": np.__version__,
            "platform": platform.platform(),
        },
        "transform": {
            "minSize": MIN_SIZE,
            "maxSize": MAX_SIZE,
            "sizeDivisible": SIZE_DIVISIBLE,
            "imageMean": IMAGE_MEAN,
            "imageStd": IMAGE_STD,
        },
        "inputPattern": "((c*31 + y*7 + x*13) mod 256), planar CHW, in [0, 255]",
        # Measured, not guessed. torch computes the sampling coordinate in float32, where the
        # granularity at an index near 2000 is ~1.2e-4; the input pattern wraps modulo 256, so
        # adjacent pixels can differ by a full unit in [0,1] and that coordinate noise passes straight
        # into the value. The observed worst case is 9.3e-5, so the bound is set just above it with
        # room for a different machine's rounding — and it still leaves a factor of ~5000 to the
        # smallest real defect (a half-pixel shift moves a value by ~1.0 on this pattern).
        "absoluteToleranceNormalised": 1e-3,
        "absoluteToleranceRaw": 2e-4,
        "toleranceReason": (
            "float32 sampling-coordinate granularity in torch's own kernel, amplified by the mod-256 "
            "discontinuities in the input pattern (adjacent pixels can differ by a full unit in [0,1], "
            "so coordinate noise passes straight into the value). Measured worst 9.3e-5 on "
            "downscale2000x1500. The ulp of a float32 coordinate near 1076 is 1.22e-4, so a half-ulp "
            "is 6.1e-5 and two or three chained roundings in scale*(d+0.5)-0.5 account for the 1.5x. "
            "The Swift formula itself was checked separately by resampling a linear ramp, where the "
            "output IS the sampling coordinate: against a float64 tensor (which forces torch's own "
            "opmath to double) the two agreed to 5.6e-17, so the formula is exact and only the "
            "precision differs. NOTE: this residual grows with coordinate magnitude, so the tolerance "
            "is validated for canvases up to 1344; a larger canvas requires re-measurement."
        ),
        "transformBranch": {"training": False, "sizeDivisibleReadFromTransform": SIZE_DIVISIBLE},
        "cases": [build_case(case) for case in CASES],
        "degenerateAxisCases": degenerate_axis_reference(),
    }

    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_PATH.write_text(json.dumps(oracle, separators=(",", ":")) + "\n")

    for case in oracle["cases"]:
        print(
            f"{case['name']:>26}: {case['sourceWidth']}x{case['sourceHeight']}"
            f" -> resized {case['resizedWidth']}x{case['resizedHeight']}"
            f" -> canvas {case['canvasWidth']}x{case['canvasHeight']}"
            f" (padRight {case['padRight']}, padBottom {case['padBottom']})"
            f"  scaleX {case['scaleX']:.6f} scaleY {case['scaleY']:.6f}"
            f"  {'PER-AXIS' if case['scaleX'] != case['scaleY'] else 'equal axes'}"
        )
    print(f"\nwrote {OUTPUT_PATH.relative_to(REPOSITORY_ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
