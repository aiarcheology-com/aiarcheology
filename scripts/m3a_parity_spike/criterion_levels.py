"""Criterion 3: per-ROI FPN level assignment, measured by the harness rather than by hand.

This module exists because the criterion was previously reported as passing on numbers produced by
ad-hoc commands that were never committed. The probe existed; nothing called it. That is exactly the
failure the ticket's own acceptance criteria warn about — "so a later attempt starts from the
measurement rather than repeating it" — and a number nobody can regenerate is not a measurement.

Three things are asked, each with an answer that can fail:

1. Does the NN-spec expression reproduce torchvision's `LevelMapper` on **real** proposal areas?
2. Does it survive the inputs a static graph will actually hand it — power-of-two boundaries, where
   `floor` can tip either way, and the degenerate boxes that NMS padding produces (zero area, one
   pixel, out of image), where `log2(sqrt(0))` is negative infinity?
3. How much margin is there in fp16, which is what the shipping model will use?
"""

from __future__ import annotations

import numpy as np
import torch

from probes import level_assignment_probe

# torchvision's defaults for a four-level FPN pooler (`poolers.py`).
CANONICAL_LEVEL = 4.0
CANONICAL_SCALE = 224.0
EPS = 1e-6
LEVEL_MIN = 2
LEVEL_MAX = 5


def torchvision_levels(areas: np.ndarray) -> np.ndarray:
    """`floor(k0 + log2(sqrt(area)/s0) + eps)`, clamped — the epsilon OUTSIDE the logarithm."""
    side = torch.sqrt(torch.tensor(areas, dtype=torch.float32))
    value = CANONICAL_LEVEL + torch.log2(side / CANONICAL_SCALE) + torch.tensor(EPS)
    return torch.clamp(torch.floor(value), min=LEVEL_MIN, max=LEVEL_MAX).numpy()


def _compare(areas: np.ndarray) -> dict:
    probe = level_assignment_probe(
        count=len(areas), canonical_level=CANONICAL_LEVEL, canonical_scale=CANONICAL_SCALE,
        eps=EPS, level_min=LEVEL_MIN, level_max=LEVEL_MAX,
    )
    produced = np.asarray(
        probe.run(areas=np.asarray(areas, dtype=np.float32).reshape(-1, 1, 1, 1, 1))["levels"]
    ).ravel()
    expected = torchvision_levels(np.asarray(areas, dtype=np.float32))
    mismatches = int((produced != expected).sum())
    return {
        "count": int(len(areas)),
        "mismatches": mismatches,
        "agrees": mismatches == 0,
        "first_mismatch_area": None if mismatches == 0
        else float(np.asarray(areas)[produced != expected][0]),
    }


def real_proposals(model: torch.nn.Module, image_chw: np.ndarray) -> dict:
    """The comparison that matters: the areas the RPN actually emits for a real image."""
    with torch.no_grad():
        images, _ = model.transform([torch.from_numpy(image_chw)])
        features = model.backbone(images.tensors)
        proposals, _ = model.rpn(images, features)
    boxes = proposals[0].numpy()
    areas = np.clip((boxes[:, 2] - boxes[:, 0]) * (boxes[:, 3] - boxes[:, 1]), 0, None)
    return _compare(areas.astype(np.float32))


def adversarial_set() -> dict:
    """The inputs a static graph will hand it that a real image never would.

    Power-of-two boundaries are where `floor` decides between two levels on a hair's width, and the
    degenerate boxes come from NMS padding: criterion 2 measured that padded slots are zero boxes,
    and a zero box has zero area, so this expression sees `log2(0) = -inf` on every empty slot of
    every tile.
    """
    boundaries = []
    for level in range(-3, 4):
        side = CANONICAL_SCALE * (2.0 ** level)
        for nudge in (-2, -1, 0, 1, 2):
            value = np.float32(side * side)
            for _ in range(abs(nudge)):
                value = np.nextafter(value, np.float32(np.inf if nudge > 0 else -np.inf))
            boundaries.append(float(value))

    degenerate = [0.0, 1e-12, 1.0, 4.0, 1e12]
    areas = np.array(boundaries + degenerate, dtype=np.float32)
    result = _compare(areas)
    result["includes_degenerate"] = degenerate
    result["note"] = ("zero area comes from the boxes NMS pads with, so log2(sqrt(0)) = -inf is a "
                      "real input on every tile, not a hypothetical")
    return result


def fp16_margin(model: torch.nn.Module, image_chw: np.ndarray, samples: int = 200_000) -> dict:
    """How close the assignment sits to a boundary, and how often fp16 coordinates cross it.

    The shipping model will not be float32. This turns "fp16 might flip a floor on device" into a
    rate, using box shapes drawn to match what the RPN emits rather than an arbitrary range.
    """
    with torch.no_grad():
        images, _ = model.transform([torch.from_numpy(image_chw)])
        features = model.backbone(images.tensors)
        proposals, _ = model.rpn(images, features)
    boxes = proposals[0].numpy()
    widths = boxes[:, 2] - boxes[:, 0]
    heights = boxes[:, 3] - boxes[:, 1]

    rng = np.random.default_rng(0)
    width = rng.choice(widths[widths > 0], size=samples, replace=True)
    height = rng.choice(heights[heights > 0], size=samples, replace=True)

    exact = CANONICAL_LEVEL + np.log2(np.sqrt(width * height) / CANONICAL_SCALE) + EPS
    fractional = exact - np.floor(exact)
    distance = np.minimum(fractional, 1.0 - fractional)

    half = lambda a: a.astype(np.float16).astype(np.float64)  # noqa: E731
    rounded = CANONICAL_LEVEL + np.log2(np.sqrt(half(width) * half(height)) / CANONICAL_SCALE) + EPS
    flips = int((np.floor(exact) != np.floor(rounded)).sum())

    return {
        "samples": samples,
        "min_distance_to_boundary": float(distance.min()),
        "median_distance_to_boundary": float(np.median(distance)),
        "within_1e_3_of_boundary": int((distance < 1e-3).sum()),
        "fp16_level_flips": flips,
        "fp16_level_flip_rate": flips / samples,
        "source": "box widths and heights resampled from this image's real RPN proposals",
    }
