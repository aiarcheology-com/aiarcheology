"""M3a's one failed prediction: why does the pooled construction miss by 4%, and which fix closes it?

`criterion_roi_align` predicted that CropResize at 2x followed by a 2x2 average pool would reproduce
`roi_align(sampling_ratio=2)` to float noise once the sampling grid was calibrated. It reproduced the
*grid* to 1.9e-06 feature pixels and then missed the *values* by 0.0436 relative on real features. A
prediction that fails is worth more than one that cannot, but only if somebody goes and finds out
why, because M3c has to build one of several different fixes depending on the answer:

- if the residual is spread evenly over every ROI, the two operators differ in **shape** and no
  coordinate trick recovers it — the ROI stage would have to be built some other way entirely;
- if it concentrates on ROIs whose sampling reaches past the feature map, the operators differ only
  in **boundary semantics**, and a boundary is something a graph can pad its way out of.

So this file measures three ROI populations — interior, edge-touching, and deliberately overhanging —
and then tests the padding fixes against the population that actually carries the error.

**The ticket's stated hypothesis is backwards, and the measurement says so.** #673 assumed that
`roi_align` zero-pads samples outside the feature map while CropResize clamps, which makes a
*zero* ring the obvious fix. Both halves are wrong, and this file's `boundary_semantics` block
demonstrates it rather than asserting it, by building two behavioural models in numpy and asking
which one reproduces which operator:

- `roi_align` **clamps**. Its `bilinear_interpolate` returns zero only for a sample outside
  `[-1, H]`; a sample in `[-1, 0)` is pulled to 0 and a sample in `(H-1, H]` is pulled to `H-1`, so
  the last half pixel of a box that reaches the image bound is sampled as a *replicated edge*.
- `CropResize` **zeroes**. Any sample outside `[0, H-1] x [0, W-1]` contributes exactly nothing.

That inversion decides the fix. A zero ring plus a `+1` coordinate shift gives CropResize a zero row
to interpolate against precisely where torchvision replicates — it moves the residual around without
removing it. A **replicate** ring gives it a copy of the edge row, which is what torchvision's clamp
already computes, and the two then agree to float noise. Both rings are measured here; recording only
the one that works would hide that the obvious fix is the wrong one.

Everything is measured on a real ADAF FPN level, at that level's own `spatial_scale`, because the
ring's coordinate shift is one *feature-map* pixel and `1 / spatial_scale` image pixels — a shift
applied in the wrong frame is a 16x error that would look like the ring failing.
"""

from __future__ import annotations

import json
import math
from pathlib import Path

import numpy as np
import torch
from PIL import Image
from torchvision.ops import roi_align

import inputs
import oracle
from decision_rule import MAX_ELEMENTWISE_ABS, Verdict
from probes import crop_resize_probe, pack_rois

RESULTS = Path(__file__).resolve().parent / "results"

# The detector and figure `criterion_roi_align` measured its 0.0436 on, so the numbers below are
# comparable to it rather than to a differently-fed model.
MODEL_ID = "OD_ringfort"
FIGURE = "ringfort.jpg"

# Two FPN levels, deliberately. `0` is P2 (200x200 at stride 4) — M3a's exact configuration, so the
# real-proposal partition can be quoted against its published residual. `2` is P4 (50x50 at stride
# 16), where a 16-image-pixel band is a whole feature pixel, so edges are cheap to hit and the
# populations are not dominated by a handful of ROIs.
LEVELS = ("0", "2")

OUTPUT_SIZE = 7
SAMPLING_RATIO = 2
CROP_SIZE = OUTPUT_SIZE * 2      # the construction under test: crop at 2x, average-pool 2x2
POOL = 2
MODE = "ROI_ALIGN_MODE"
BOX_MODE = "CORNERS_HEIGHT_FIRST"

# How many of the RPN's proposals to carry over from `criterion_roi_align.choose_construction`, which
# used the first 64. Changing it would make the reproduction incomparable, so it is not a knob.
REAL_PROPOSAL_COUNT = 64

# Populations are built from a seeded generator so two runs of this file compare like with like.
POPULATION_SEED = 20260820
POPULATION_SIZE = 24

# The behavioural models loop in Python over every sample, so they run on a channel slice. Sixteen
# channels is enough to distinguish two boundary rules — they disagree by whole feature values, not
# by a hair — and cheap enough that the identification is not the run's cost centre.
MECHANISM_CHANNELS = 16

# --------------------------------------------------------------------------------------------
# Decision rule
# --------------------------------------------------------------------------------------------

# Interior ROIs must land on float noise. This is the load-bearing control: if interior ROIs are
# *also* 0.04-ish then the operators differ in shape, no ring can help, and every conclusion below is
# void. 1e-4 is `decision_rule.MAX_ELEMENTWISE_ABS` read as a relative budget — well above float32
# accumulation over a 7x7x256 pooled cell and far below anything that could move a box.
INTERIOR_RESIDUAL_CEILING = MAX_ELEMENTWISE_ABS

# A fix is a fix only if it puts the edge-touching and overhanging populations on the interior's own
# floor. "Better than before" is not a criterion — the residual is already only 4%, and M3c does not
# need a smaller wrong number, it needs the right operator.
FIXED_RESIDUAL_CEILING = MAX_ELEMENTWISE_ABS


# --------------------------------------------------------------------------------------------
# Sampling geometry, shared by the behavioural models and the population classifier
# --------------------------------------------------------------------------------------------


def sample_positions(box_xyxy, output_size: int, spatial_scale: float, sampling_ratio: int) -> tuple:
    """`roi_align`'s sample positions for one box, in feature-map pixels.

    Reproduced from torchvision's CPU kernel rather than inferred: `roi_start = x0 * spatial_scale`
    with no half-pixel offset (that is what `aligned=False` means), the ROI's extent floored at one
    pixel, and the samples laid at bin centres. The positions are the part both operators agree on —
    `criterion_roi_align` measured the agreement at 1.9e-06 — so pinning them here lets the boundary
    rule be the only thing that varies.
    """
    x0, y0, x1, y1 = (float(v) for v in box_xyxy)
    start_w, start_h = x0 * spatial_scale, y0 * spatial_scale
    # `aligned=False` floors the ROI extent at one pixel (roi_align_kernel.cpp), which matters here
    # because the RPN emits degenerate proposals and a floored extent moves the samples.
    width = max(x1 * spatial_scale - start_w, 1.0)
    height = max(y1 * spatial_scale - start_h, 1.0)
    bin_h, bin_w = height / output_size, width / output_size
    grid_h = sampling_ratio if sampling_ratio > 0 else math.ceil(height / output_size)
    grid_w = sampling_ratio if sampling_ratio > 0 else math.ceil(width / output_size)
    rows = np.array([[start_h + p * bin_h + (i + 0.5) * bin_h / grid_h for i in range(grid_h)]
                     for p in range(output_size)])
    cols = np.array([[start_w + p * bin_w + (i + 0.5) * bin_w / grid_w for i in range(grid_w)]
                     for p in range(output_size)])
    return rows, cols


def overhang(box_xyxy, spatial_scale: float, side: int) -> float:
    """How far this box's samples reach outside `[0, side - 1]`, in feature pixels.

    `side - 1` and not `side` is the whole point. The interpolable region ends at the *centre* of the
    last pixel, so a proposal clipped to the image bound — which every RPN proposal is — still
    samples up to a pixel beyond it, and that band is where the two operators part company.
    """
    rows, cols = sample_positions(box_xyxy, OUTPUT_SIZE, spatial_scale, SAMPLING_RATIO)
    limit = side - 1
    return float(max(0.0, -rows.min(), -cols.min(), rows.max() - limit, cols.max() - limit))


# --------------------------------------------------------------------------------------------
# Two behavioural models, so "which semantic" is a measurement and not a claim
# --------------------------------------------------------------------------------------------


def _bilinear(feature: np.ndarray, row: float, col: float, rule: str) -> np.ndarray:
    channels, height, width = feature.shape
    if rule == "roi_align_clamp":
        # torchvision, `bilinear_interpolate`: zero only outside [-1, H], clamp inside it.
        if row < -1.0 or row > height or col < -1.0 or col > width:
            return np.zeros(channels)
        row, col = max(row, 0.0), max(col, 0.0)
        row_low, col_low = int(row), int(col)
        if row_low >= height - 1:
            row_high = row_low = height - 1
            row = float(row_low)
        else:
            row_high = row_low + 1
        if col_low >= width - 1:
            col_high = col_low = width - 1
            col = float(col_low)
        else:
            col_high = col_low + 1
    elif rule == "crop_resize_zero":
        # The hypothesis this file tests: anything outside the interpolable region contributes
        # nothing at all — not a clamped value, and not a blend against an implicit zero row.
        if row < 0.0 or row > height - 1 or col < 0.0 or col > width - 1:
            return np.zeros(channels)
        row_low, col_low = int(math.floor(row)), int(math.floor(col))
        row_high, col_high = min(row_low + 1, height - 1), min(col_low + 1, width - 1)
    else:
        raise ValueError(rule)
    dr, dc = row - row_low, col - col_low
    return ((1 - dr) * (1 - dc) * feature[:, row_low, col_low]
            + (1 - dr) * dc * feature[:, row_low, col_high]
            + dr * (1 - dc) * feature[:, row_high, col_low]
            + dr * dc * feature[:, row_high, col_high])


def behavioural_pool(feature: np.ndarray, boxes: np.ndarray, spatial_scale: float, rule: str) -> np.ndarray:
    """The crop-at-2x + pool-2x2 construction, computed in numpy under one boundary rule.

    Written at `CROP_SIZE` with one sample per cell and then pooled, because that is what the Core ML
    construction does; `roi_align`'s `sampling_ratio=2` sub-positions are exactly this grid's
    centres, which is why the construction was chosen in the first place.
    """
    pooled = np.zeros((len(boxes), feature.shape[0], CROP_SIZE, CROP_SIZE))
    for index, box in enumerate(boxes):
        rows, cols = sample_positions(box, CROP_SIZE, spatial_scale, 1)
        for r in range(CROP_SIZE):
            for c in range(CROP_SIZE):
                pooled[index, :, r, c] = _bilinear(feature, rows[r, 0], cols[c, 0], rule)
    return average_pool(pooled)


def average_pool(cropped: np.ndarray) -> np.ndarray:
    count, channels, height, width = cropped.shape
    return cropped.reshape(count, channels, height // POOL, POOL, width // POOL, POOL).mean(axis=(3, 5))


# --------------------------------------------------------------------------------------------
# The two sides being compared
# --------------------------------------------------------------------------------------------


def torchvision_pooled(feature: np.ndarray, boxes: np.ndarray, spatial_scale: float) -> np.ndarray:
    return roi_align(
        torch.from_numpy(feature[None]), [torch.from_numpy(boxes.astype(np.float32))],
        output_size=(OUTPUT_SIZE, OUTPUT_SIZE), spatial_scale=spatial_scale,
        sampling_ratio=SAMPLING_RATIO, aligned=False,
    ).numpy()


def crop_resize_pooled(feature: np.ndarray, boxes: np.ndarray, spatial_scale: float) -> np.ndarray:
    probe = crop_resize_probe(
        channels=feature.shape[0], height=feature.shape[1], width=feature.shape[2],
        roi_count=len(boxes), target_height=CROP_SIZE, target_width=CROP_SIZE, mode=MODE,
        box_coordinate_mode=BOX_MODE, spatial_scale=spatial_scale, average_pool=POOL,
    )
    out = probe.run(features=feature.reshape(1, 1, *feature.shape),
                    rois=pack_rois(boxes.astype(np.float32), BOX_MODE))["pooled"]
    return np.asarray(out).reshape(len(boxes), feature.shape[0], OUTPUT_SIZE, OUTPUT_SIZE)


def ringed(feature: np.ndarray, boxes: np.ndarray, spatial_scale: float, mode: str) -> tuple:
    """A one-pixel ring around the feature map, with the ROIs shifted to follow it.

    The shift is one pixel *in the level's own frame*, which is `1 / spatial_scale` image pixels —
    at P4 that is 16. Applying it in the image frame instead would move the ROIs by a sixteenth of a
    feature pixel and the ring would look like it had failed.
    """
    padded = np.pad(feature, ((0, 0), (1, 1), (1, 1)), mode=mode)
    return padded, boxes.astype(np.float64) + 1.0 / spatial_scale


def residual(reference: np.ndarray, candidate: np.ndarray) -> dict:
    """Same definition as `criterion_roi_align.measure_on_features`, so the numbers are comparable."""
    difference = np.abs(np.asarray(reference, dtype=np.float64) - np.asarray(candidate, dtype=np.float64))
    scale = float(np.abs(np.asarray(reference, dtype=np.float64)).mean()) or 1.0
    return {
        "max_abs_diff": float(difference.max()),
        "mean_abs_diff": float(difference.mean()),
        "relative_mean_abs_diff": float(difference.mean() / scale),
        "rois": int(len(reference)),
    }


# --------------------------------------------------------------------------------------------
# Populations
# --------------------------------------------------------------------------------------------


def synthetic_populations(side: int, spatial_scale: float) -> dict:
    """Interior, edge-touching and overhanging ROIs, in the image frame.

    Boxes are laid out in the *level's* frame — where "edge" has a meaning — and divided back into
    the image frame, so the three populations differ in exactly one property. Every box is
    non-square, off-grid and off-centre for the reason `criterion_roi_align.CALIBRATION_ROI` is: a
    square grid-aligned ROI cancels the half-pixel effects this file is looking for.
    """
    rng = np.random.default_rng(POPULATION_SEED)
    limit = float(side)

    def build(sampler) -> np.ndarray:
        boxes = np.array([sampler(rng) for _ in range(POPULATION_SIZE)], dtype=np.float64)
        return (boxes / spatial_scale).astype(np.float32)

    def interior(rng) -> list:
        x0, y0 = rng.uniform(3.0, limit - 15.0), rng.uniform(3.0, limit - 15.0)
        return [x0, y0, x0 + rng.uniform(4.0, 11.0), y0 + rng.uniform(4.0, 11.0)]

    def edge(rng) -> list:
        # What `clip_boxes_to_image` actually emits: a side pinned exactly to the image bound, which
        # in this frame is `side` — one pixel past the last interpolable centre.
        span = rng.uniform(3.0, 12.0)
        if rng.random() < 0.5:
            x0, x1 = limit - span, limit
        else:
            x0, x1 = 0.0, span
        span = rng.uniform(3.0, 12.0)
        if rng.random() < 0.5:
            y0, y1 = limit - span, limit
        else:
            y0, y1 = 0.0, span
        return [x0, y0, x1, y1]

    def overhanging(rng) -> list:
        # Only reachable if an emitted graph omits `clip_boxes_to_image` — a variable-length filter is
        # cheap in torch and awkward in a static graph, so this is a shape M3c may well have to run.
        out = rng.uniform(1.5, 6.0)
        if rng.random() < 0.5:
            x0, x1 = limit - rng.uniform(3.0, 10.0), limit + out
        else:
            x0, x1 = -out, rng.uniform(3.0, 10.0)
        out = rng.uniform(1.5, 6.0)
        if rng.random() < 0.5:
            y0, y1 = limit - rng.uniform(3.0, 10.0), limit + out
        else:
            y0, y1 = -out, rng.uniform(3.0, 10.0)
        return [x0, y0, x1, y1]

    return {"interior": build(interior), "edge_touching": build(edge), "overhanging": build(overhanging)}


def partition_real_proposals(boxes: np.ndarray, spatial_scale: float, side: int) -> dict:
    """Split M3a's own proposal set by whether its sampling leaves the interpolable region.

    This is the measurement that explains the published 0.0436 rather than merely reproducing it: if
    the residual is a boundary effect, it lives entirely in one half of a set nobody chose for this
    purpose.
    """
    reach = np.array([overhang(box, spatial_scale, side) for box in boxes])
    return {
        "interior": boxes[reach <= 0.0],
        "edge_touching": boxes[reach > 0.0],
        "overhang_px": reach,
    }


# --------------------------------------------------------------------------------------------
# The run
# --------------------------------------------------------------------------------------------


def _variants(feature: np.ndarray, boxes: np.ndarray, spatial_scale: float) -> dict:
    """Residual against `roi_align` for the bare construction and for each candidate ring."""
    if not len(boxes):
        return {}
    reference = torchvision_pooled(feature, boxes, spatial_scale)
    rows = {"no_ring": residual(reference, crop_resize_pooled(feature, boxes, spatial_scale))}
    for label, mode in (("zero_ring", "constant"), ("replicate_ring", "edge")):
        padded, shifted = ringed(feature, boxes, spatial_scale, mode)
        rows[label] = residual(reference, crop_resize_pooled(padded, shifted.astype(np.float32), spatial_scale))
    return rows


def boundary_semantics(feature: np.ndarray, boxes: np.ndarray, spatial_scale: float) -> dict:
    """Which numpy rule reproduces which operator — the mechanism, as a pair of numbers.

    Each behavioural model is checked against *both* operators. Checking only the expected pairing
    would let a model that happens to be wrong in the same direction as its target pass as an
    explanation.
    """
    slim = np.ascontiguousarray(feature[:MECHANISM_CHANNELS])
    reference = torchvision_pooled(slim, boxes, spatial_scale)
    candidate = crop_resize_pooled(slim, boxes, spatial_scale)
    models = {rule: behavioural_pool(slim, boxes, spatial_scale, rule)
              for rule in ("roi_align_clamp", "crop_resize_zero")}

    report = {"channels": int(MECHANISM_CHANNELS), "rois": int(len(boxes))}
    for rule, modelled in models.items():
        report[rule] = {
            "vs_roi_align": residual(reference, modelled),
            "vs_crop_resize": residual(candidate, modelled),
        }
    report["roi_align_is_clamping"] = bool(
        report["roi_align_clamp"]["vs_roi_align"]["relative_mean_abs_diff"] <= INTERIOR_RESIDUAL_CEILING
    )
    report["crop_resize_is_zeroing"] = bool(
        report["crop_resize_zero"]["vs_crop_resize"]["relative_mean_abs_diff"] <= INTERIOR_RESIDUAL_CEILING
    )
    report["hypothesis_in_ticket_673"] = (
        "roi_align zero-pads and CropResize clamps — the inverse of what the two rules above measure"
    )
    return report


def measure() -> dict:
    built = oracle.build_oracle(MODEL_ID)
    pixels = np.asarray(Image.open(RESULTS / "figures" / FIGURE).convert("RGB"))
    chw = inputs.scaling_candidates(pixels)["divide_255"].numpy().astype(np.float32)

    with torch.no_grad():
        images, _ = built.model.transform([torch.from_numpy(chw)])
        features = built.model.backbone(images.tensors)
        proposals, _ = built.model.rpn(images, features)
    padded_side = int(images.tensors.shape[-1])
    real_boxes = proposals[0].numpy()[:REAL_PROPOSAL_COUNT]

    report = {
        "configuration": {
            "model_id": MODEL_ID, "figure": FIGURE,
            "padded_input_side": padded_side,
            "construction": f"CropResize({MODE}, {CROP_SIZE}x{CROP_SIZE}) + {POOL}x{POOL} average pool",
            "reference": f"torchvision.ops.roi_align(output_size={OUTPUT_SIZE}, "
                         f"sampling_ratio={SAMPLING_RATIO}, aligned=False)",
            "real_proposals_used": int(len(real_boxes)),
            "population_size": POPULATION_SIZE,
            "ring_shift_note": "one feature-map pixel, applied as 1/spatial_scale image pixels",
        },
        "decision_rule": {
            "interior_relative_residual_ceiling": INTERIOR_RESIDUAL_CEILING,
            "fixed_relative_residual_ceiling": FIXED_RESIDUAL_CEILING,
        },
        "levels": {},
    }

    for name in LEVELS:
        feature = features[name].numpy()[0]
        side = int(feature.shape[-1])
        spatial_scale = side / padded_side

        real = partition_real_proposals(real_boxes, spatial_scale, side)
        synthetic = synthetic_populations(side, spatial_scale)

        level = {
            "feature_shape": list(feature.shape),
            "spatial_scale": spatial_scale,
            "ring_shift_image_px": 1.0 / spatial_scale,
            "real_proposals": {
                "all": _variants(feature, real_boxes, spatial_scale),
                "interior": _variants(feature, real["interior"], spatial_scale),
                "edge_touching": _variants(feature, real["edge_touching"], spatial_scale),
                "counts": {"interior": int(len(real["interior"])),
                           "edge_touching": int(len(real["edge_touching"]))},
                "max_overhang_px": float(real["overhang_px"].max()),
            },
            "synthetic": {label: _variants(feature, boxes, spatial_scale)
                          for label, boxes in synthetic.items()},
        }
        level["boundary_semantics"] = boundary_semantics(
            feature, np.concatenate(list(synthetic.values())), spatial_scale
        )
        report["levels"][name] = level

    report["mechanism"] = _mechanism(report)
    report["recommendation"] = _recommendation(report)
    return report


def _mechanism(report: dict) -> str:
    """State the mechanism from the numbers just measured, so a future run cannot inherit a stale claim."""
    checks = [level["boundary_semantics"] for level in report["levels"].values()]
    clamping = all(check["roi_align_is_clamping"] for check in checks)
    zeroing = all(check["crop_resize_is_zeroing"] for check in checks)
    if clamping and zeroing:
        return ("roi_align clamps a sample in [-1, 0) or (H-1, H] onto the edge pixel and zeroes only "
                "beyond [-1, H]; CropResize contributes exactly zero for any sample outside "
                "[0, H-1] x [0, W-1]. A box clipped to the image bound samples up to one pixel past "
                "the last interpolable centre, so torchvision replicates the edge there and Core ML "
                "drops it — which is the entire residual.")
    if not clamping and not zeroing:
        return ("neither behavioural model reproduces its operator: the difference is not a boundary "
                "rule and the populations below do not localise it")
    return (f"partial identification only — roi_align_is_clamping={clamping}, "
            f"crop_resize_is_zeroing={zeroing}; do not build a fix on this")


def _recommendation(report: dict) -> str:
    scores = {}
    for label in ("no_ring", "zero_ring", "replicate_ring"):
        worst = 0.0
        for level in report["levels"].values():
            for group in ("edge_touching", "overhanging"):
                row = level["synthetic"].get(group, {}).get(label)
                if row:
                    worst = max(worst, row["relative_mean_abs_diff"])
        scores[label] = worst
    best = min(scores, key=scores.get)
    if scores[best] > FIXED_RESIDUAL_CEILING:
        return (f"no candidate reaches the interior floor; best is {best} at "
                f"{scores[best]:.2e} relative (ceiling {FIXED_RESIDUAL_CEILING:.0e}). M3c cannot fix "
                f"this by padding.")
    # The winning candidate is named from `best`, never spelled out as a literal: `_mechanism` above
    # restates its conclusion from the numbers so a future run cannot inherit a stale claim, and a
    # recommendation that hardcoded "replicate" would contradict its own evidence the first time a
    # different candidate won.
    padding = {
        "no_ring": "leave every FPN level unpadded",
        "zero_ring": "pad every FPN level with a one-pixel ZERO ring",
        "replicate_ring": "pad every FPN level with a one-pixel REPLICATE ring",
    }[best]
    shift = "" if best == "no_ring" else (" and add one feature-map pixel (1/spatial_scale image "
                                          "pixels) to every ROI coordinate")
    return (f"M3c should {padding}{shift}: {best} holds the worst boundary population at "
            f"{scores[best]:.2e} relative, against {scores['no_ring']:.2e} unpadded and "
            f"{scores['zero_ring']:.2e} for the zero ring the ticket proposed.")


def evaluate(report: dict) -> list:
    verdicts = []
    for name, level in report["levels"].items():
        interior = level["synthetic"]["interior"]["no_ring"]["relative_mean_abs_diff"]
        verdicts.append(Verdict(
            f"criterion edge-ROI interior control [P{int(name) + 2}]",
            "PASS" if interior <= INTERIOR_RESIDUAL_CEILING else "FAIL",
            f"interior ROIs sit at {interior:.2e} relative "
            f"(ceiling {INTERIOR_RESIDUAL_CEILING:.0e}); above it, the operators differ in shape and "
            f"no ring can help",
        ))
        for group in ("edge_touching", "overhanging"):
            fixed = level["synthetic"][group]["replicate_ring"]["relative_mean_abs_diff"]
            bare = level["synthetic"][group]["no_ring"]["relative_mean_abs_diff"]
            zeroed = level["synthetic"][group]["zero_ring"]["relative_mean_abs_diff"]
            verdicts.append(Verdict(
                f"criterion edge-ROI replicate ring [{group}, P{int(name) + 2}]",
                "PASS" if fixed <= FIXED_RESIDUAL_CEILING else "FAIL",
                f"{bare:.2e} unpadded, {zeroed:.2e} with a zero ring, {fixed:.2e} with a replicate ring",
            ))
    ok = all(level["boundary_semantics"]["roi_align_is_clamping"]
             and level["boundary_semantics"]["crop_resize_is_zeroing"]
             for level in report["levels"].values())
    verdicts.append(Verdict("criterion edge-ROI mechanism identified", "PASS" if ok else "FAIL",
                            report["mechanism"]))
    return verdicts


def render(report: dict) -> str:
    lines = []
    for name, level in report["levels"].items():
        lines.append(f"level {name} (P{int(name) + 2}) {level['feature_shape']} "
                     f"spatial_scale {level['spatial_scale']:.4f} "
                     f"ring shift {level['ring_shift_image_px']:.1f} image px")
        header = f"  {'population':<22}{'n':>4}{'no ring':>12}{'zero ring':>12}{'replicate':>12}"
        lines.append(header)
        groups = [(f"synthetic {label}", rows) for label, rows in level["synthetic"].items()]
        groups += [(f"proposals {label}", level["real_proposals"][label])
                   for label in ("all", "interior", "edge_touching")]
        for label, rows in groups:
            if not rows:
                lines.append(f"  {label:<22}{0:>4}   (empty population)")
                continue
            lines.append(
                f"  {label:<22}{rows['no_ring']['rois']:>4}"
                f"{rows['no_ring']['relative_mean_abs_diff']:>12.2e}"
                f"{rows['zero_ring']['relative_mean_abs_diff']:>12.2e}"
                f"{rows['replicate_ring']['relative_mean_abs_diff']:>12.2e}"
            )
        semantics = level["boundary_semantics"]
        lines.append(f"  roi_align reproduced by the clamping model at "
                     f"{semantics['roi_align_clamp']['vs_roi_align']['relative_mean_abs_diff']:.2e}; "
                     f"CropResize by the zeroing model at "
                     f"{semantics['crop_resize_zero']['vs_crop_resize']['relative_mean_abs_diff']:.2e}")
        lines.append("")
    lines.append("relative mean |delta| against torchvision roi_align, as criterion_roi_align defines it")
    lines.append(f"mechanism: {report['mechanism']}")
    lines.append(f"recommendation: {report['recommendation']}")
    return "\n".join(lines)


if __name__ == "__main__":
    measured = measure()
    judged = evaluate(measured)
    measured["verdicts"] = [{"criterion": v.criterion, "outcome": v.outcome, "detail": v.detail}
                            for v in judged]
    print(render(measured))
    for verdict in judged:
        print(verdict)
    RESULTS.mkdir(parents=True, exist_ok=True)
    (RESULTS / "criterion_edge_rois.json").write_text(json.dumps(measured, indent=2))
    print("wrote results/criterion_edge_rois.json")
