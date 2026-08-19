"""Criterion 0: `GeneralizedRCNNTransform`, which the ticket does not list and every criterion needs.

The four exit criteria all describe things that happen *after* the image has been resized, padded and
normalised. Nothing about that step is free. A 512 tile does not run at 512: the transform scales the
short side to `min_size` (800 by default) with
`interpolate(bilinear, recompute_scale_factor=True, align_corners=False)`, pads to a multiple of 32,
and rescales the boxes back on the way out. Core ML's legacy resize conventions are the same hazard
class as criterion 1 — except this one resamples the whole image rather than a 7x7 patch, so its
error feeds every subsequent measurement.

There are two separable questions and they have different answers, which is why they are measured
separately:

**(a) Can NN-spec reproduce the resize?** `add_resize_bilinear` offers several modes, none of which
is documented as PyTorch's `align_corners=False` half-pixel rule. `add_upsample` does offer an
`ALIGN_CORNERS_FALSE` mode, but it takes *integer* scale factors, and 512 to 800 is 1.5625 — so it
cannot express this resize at all. Measured, the closest mode leaves a visible residual.

**(b) Can the resize be avoided entirely?** If `min_size` is pinned to the tile size, the scale factor
is exactly 1.0, and a 512 tile is already divisible by 32 so no padding is needed either — the whole
transform collapses to normalisation, which is a scale and a bias and is trivially expressible.

(b) is not a cheaper implementation of (a). It is a *different model*: objects appear to the network
at 0.64x the scale its weights were trained at, so parity measured against a `min_size=512` reference
is parity against something ADAF never ran. It is reported side by side with (a) and labelled, and
which reference M3c targets is a human's decision, not this file's.
"""

from __future__ import annotations

import numpy as np
import torch
import torch.nn.functional as F

import coremltools as ct
from coremltools.models import datatypes
from coremltools.models.neural_network import NeuralNetworkBuilder

from probes import CPU_ONLY

RESIZE_MODES = (
    "STRICT_ALIGN_ENDPOINTS_MODE",
    "ALIGN_ENDPOINTS_MODE",
    "UPSAMPLE_MODE",
    "ROI_ALIGN_MODE",
)


def torchvision_resize(image_chw: np.ndarray, target: int) -> np.ndarray:
    """Exactly what `GeneralizedRCNNTransform._resize_image_and_masks` does to one image."""
    source = image_chw.shape[-1]
    return F.interpolate(
        torch.from_numpy(image_chw).unsqueeze(0),
        scale_factor=target / source,
        mode="bilinear",
        recompute_scale_factor=True,
        align_corners=False,
    ).numpy()


def resize_probe_delta(image_chw: np.ndarray, target: int, mode: str) -> dict:
    """One NN-spec resize mode against torchvision's, elementwise."""
    channels, height, width = image_chw.shape
    reference = torchvision_resize(image_chw, target)

    builder = NeuralNetworkBuilder(
        [("image", datatypes.Array(1, 1, channels, height, width))],
        [("out", None)],
        disable_rank5_shape_mapping=True,
    )
    builder.add_resize_bilinear(
        name="resize", input_name="image", output_name="out",
        target_height=target, target_width=target, mode=mode,
    )
    model = ct.models.MLModel(builder.spec, compute_units=CPU_ONLY)
    candidate = np.asarray(
        model.predict({"image": image_chw.reshape(1, 1, channels, height, width)})["out"]
    ).reshape(reference.shape)

    difference = np.abs(candidate - reference)
    data_range = float(reference.max() - reference.min()) or 1.0
    return {
        "mode": mode,
        "max_abs_diff": float(difference.max()),
        "mean_abs_diff": float(difference.mean()),
        "max_diff_as_fraction_of_range": float(difference.max() / data_range),
    }


def compare_resize(image_chw: np.ndarray, target: int = 800) -> dict:
    """Question (a): every NN-spec resize mode against torchvision's, on one image."""
    return {
        "source_px": int(image_chw.shape[-1]),
        "target_px": target,
        "scale_factor": target / image_chw.shape[-1],
        "integer_scale_factor": float(target / image_chw.shape[-1]).is_integer(),
        "modes": [resize_probe_delta(image_chw, target, mode) for mode in RESIZE_MODES],
    }


def transform_is_identity(model: torch.nn.Module, tile_px: int) -> dict:
    """Question (b): with `min_size` pinned to the tile size, what is left of the transform?

    Reports the facts that decide whether the resize has to be emitted at all, rather than asserting
    the conclusion: whether the scale factor is exactly 1, whether the tile is already divisible by
    the padding stride, and what remains (the ImageNet normalisation).
    """
    size_divisible = 32
    return {
        "tile_px": tile_px,
        "pinned_min_size": tile_px,
        "scale_factor": 1.0,
        "resize_needed": False,
        "padding_needed": tile_px % size_divisible != 0,
        "size_divisible": size_divisible,
        "remaining_ops": ["normalise: (x - mean) / std, expressible as a scale and a bias"],
        "image_mean": list(model.transform.image_mean),
        "image_std": list(model.transform.image_std),
        "reference_modifying": True,
        "scale_versus_training": tile_px / float(model.transform.min_size[0]),
    }


def detection_cost_of_pinning(model: torch.nn.Module, image_chw: np.ndarray, tile_px: int) -> dict:
    """What pinning `min_size` costs in detections — the number that makes (b) a choice, not a hack.

    Runs the real detector twice, once at the trained `min_size` and once pinned, and reports the
    detection sets rather than a tensor norm: past the top-K and NMS decisions an elementwise
    comparison is meaningless, because a sub-tolerance score change reorders the output set.
    """
    original_min_size = model.transform.min_size
    image = torch.from_numpy(image_chw)

    def detections() -> tuple:
        with torch.no_grad():
            out = model([image])[0]
        return out["boxes"].numpy(), out["scores"].numpy()

    try:
        boxes_trained, scores_trained = detections()
        model.transform.min_size = (tile_px,)
        boxes_pinned, scores_pinned = detections()
    finally:
        model.transform.min_size = original_min_size

    return {
        "trained_min_size": list(original_min_size),
        "pinned_min_size": tile_px,
        "detections_at_trained_min_size": int(len(boxes_trained)),
        "detections_at_pinned_min_size": int(len(boxes_pinned)),
        "max_score_trained": float(scores_trained.max()) if len(scores_trained) else None,
        "max_score_pinned": float(scores_pinned.max()) if len(scores_pinned) else None,
        "matched": _match_detections(boxes_trained, scores_trained, boxes_pinned, scores_pinned),
    }


def _match_detections(boxes_a: np.ndarray, scores_a: np.ndarray, boxes_b: np.ndarray,
                      scores_b: np.ndarray, iou_threshold: float = 0.5) -> dict:
    """One-to-one IoU matching between two detection sets, with score deltas on the matches."""
    if len(boxes_a) == 0 or len(boxes_b) == 0:
        return {"matched": 0, "unmatched_a": int(len(boxes_a)), "unmatched_b": int(len(boxes_b)),
                "max_score_delta": None, "max_box_shift_px": None}

    from torchvision.ops import box_iou

    iou = box_iou(torch.from_numpy(boxes_a), torch.from_numpy(boxes_b)).numpy()
    used_b, pairs = set(), []
    for index_a in np.argsort(-scores_a):
        candidates = [(iou[index_a, j], j) for j in range(len(boxes_b)) if j not in used_b]
        if not candidates:
            break
        best_iou, best_j = max(candidates)
        if best_iou >= iou_threshold:
            used_b.add(best_j)
            pairs.append((index_a, best_j, best_iou))

    score_deltas = [abs(float(scores_a[i] - scores_b[j])) for i, j, _ in pairs]
    shifts = [float(np.abs(boxes_a[i] - boxes_b[j]).max()) for i, j, _ in pairs]
    return {
        "matched": len(pairs),
        "unmatched_a": int(len(boxes_a) - len(pairs)),
        "unmatched_b": int(len(boxes_b) - len(pairs)),
        "iou_threshold": iou_threshold,
        "max_score_delta": max(score_deltas) if score_deltas else None,
        "max_box_shift_px": max(shifts) if shifts else None,
    }
