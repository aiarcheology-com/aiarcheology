"""Criterion 1: does Core ML's `CropResize` reproduce torchvision's `roi_align`, and does it move boxes?

The naive experiment — run both, subtract, report the residual — cannot answer this. A residual
confounds three independent causes: a sampling-grid offset (torchvision's `aligned=False`), an axis
or coordinate-layout mismatch, and the sampling-ratio difference (torchvision averages 2x2 bilinear
samples per bin; CropResize takes one). Ranking configurations by residual would pick a winner
without ever saying which cause it fixed, and a large number would be indistinguishable from a bug in
this file.

So the measurement is a decomposition instead, in three steps:

1. **Recover each operator's sampling grid exactly**, using an input on which bilinear interpolation
   is exact. Channel 0 carries `f(h, w) = h`, channel 1 carries `f(h, w) = w`. Bilinear
   interpolation of an affine function is exact, and the *average* of an affine function over any
   symmetric set of sample positions equals its value at their centroid — so whatever
   `sampling_ratio` an operator uses, its output at cell (i, j) IS the (row, col) of the effective
   sample position, read straight off the two channels. No fitting, no tolerance.
   A coordinate-layout error is then loud rather than subtle: packing an ROI width-first while
   declaring it height-first moves the recovered grid by 6.46 feature pixels against 0.000002 for the
   honest packing — measured, not assumed. (An earlier version of this file tried to *classify* that
   as an "axes look swapped" flag by comparing the row grid against the column grid. That heuristic
   is wrong and reported a false negative on exactly the mutation above: a mislabelled ROI layout
   does not transpose the output, it crops a different box. The grid offset alone carries the
   information, so the flag is gone.)
2. **Fit the affine map** between the two grids: `roi_align_grid = scale * crop_resize_grid + offset`,
   per axis, in feature pixels. That is the pre-compensation M3b would have to apply to ROI
   coordinates, and it is a *number*, not a search result.
3. **Test the documented construction.** CropResize at 14x14 followed by a 2x2 average pool samples
   exactly roi_align's `sampling_ratio=2` sub-positions. The falsifiable prediction is that after
   step 2's pre-compensation, that construction's residual on real features collapses to float noise
   (~1e-6) while the bare 7x7 construction's does not. A prediction that can fail is worth more than
   a ranking that cannot.

Only then is the residual on real ADAF features meaningful, and only then does "it moves boxes by N
pixels" mean anything.
"""

from __future__ import annotations

import numpy as np
import torch
from torchvision.ops import roi_align

from probes import BOX_COORDINATE_MODES, CROP_RESIZE_MODES, ProbeError, crop_resize_probe, pack_rois

# A deliberately awkward ROI: non-square, off-centre, and not aligned to the pixel grid. Every one of
# those properties is load-bearing — a square centred grid-aligned ROI hides axis swaps and cancels
# the half-pixel offset that `aligned=False` introduces, which is the failure this file exists to
# avoid.
CALIBRATION_ROI = np.array([[3.5, 7.25, 26.75, 19.5]], dtype=np.float32)
CALIBRATION_SIZE = 32


def _coordinate_ramp(height: int, width: int) -> np.ndarray:
    """Channel 0 = row index, channel 1 = column index, channel 2 = 1. Shape (1, 1, 3, H, W)."""
    rows, cols = np.meshgrid(np.arange(height), np.arange(width), indexing="ij")
    stacked = np.stack([rows, cols, np.ones_like(rows)], axis=0).astype(np.float32)
    return stacked.reshape(1, 1, 3, height, width)


def torchvision_sampling_grid(boxes: np.ndarray, output_size: int, spatial_scale: float,
                              sampling_ratio: int, aligned: bool, size: int) -> np.ndarray:
    """The effective sample position of every output cell, for `roi_align`. Shape (N, out, out, 2)."""
    ramp = _coordinate_ramp(size, size).reshape(1, 3, size, size)
    pooled = roi_align(
        torch.from_numpy(ramp),
        [torch.from_numpy(boxes)],
        output_size=(output_size, output_size),
        spatial_scale=spatial_scale,
        sampling_ratio=sampling_ratio,
        aligned=aligned,
    ).numpy()
    return np.stack([pooled[:, 0], pooled[:, 1]], axis=-1)


def crop_resize_sampling_grid(boxes: np.ndarray, output_size: int, mode: str,
                              box_coordinate_mode: str, spatial_scale: float, size: int,
                              average_pool: int = 0, crop_size: int | None = None) -> np.ndarray:
    """The same, for a `CropResize` configuration. Shape (N, out, out, 2)."""
    crop = crop_size or output_size
    probe = crop_resize_probe(
        channels=3, height=size, width=size, roi_count=boxes.shape[0],
        target_height=crop, target_width=crop, mode=mode,
        box_coordinate_mode=box_coordinate_mode, spatial_scale=spatial_scale,
        average_pool=average_pool,
    )
    out = np.asarray(
        probe.run(features=_coordinate_ramp(size, size), rois=pack_rois(boxes, box_coordinate_mode))["pooled"]
    )
    out = out.reshape(boxes.shape[0], 3, output_size, output_size)
    return np.stack([out[:, 0], out[:, 1]], axis=-1)


def fit_affine(reference_grid: np.ndarray, candidate_grid: np.ndarray) -> dict:
    """Least-squares `reference = scale * candidate + offset`, per axis, plus the fit residual.

    A near-zero residual means the two operators differ by a pure affine reparameterisation of the
    ROI — which M3b can cancel exactly. A large residual means they differ in *shape*, which it
    cannot, and that distinction is the actual go/no-go content of this criterion.
    """
    result = {}
    for axis, name in enumerate(("row", "col")):
        x = candidate_grid[..., axis].ravel()
        y = reference_grid[..., axis].ravel()
        design = np.stack([x, np.ones_like(x)], axis=1)
        (scale, offset), *_ = np.linalg.lstsq(design, y, rcond=None)
        residual = float(np.abs(design @ np.array([scale, offset]) - y).max())
        result[name] = {"scale": float(scale), "offset": float(offset), "max_fit_residual": residual}
    return result


def calibrate(spatial_scale: float = 1.0, output_size: int = 7, sampling_ratio: int = 2,
              aligned: bool = False) -> dict:
    """Step 1+2: recover every configuration's sampling grid and fit it to torchvision's."""
    reference = torchvision_sampling_grid(
        CALIBRATION_ROI, output_size, spatial_scale, sampling_ratio, aligned, CALIBRATION_SIZE
    )
    results = {}
    for mode in CROP_RESIZE_MODES:
        for coordinate_mode in BOX_COORDINATE_MODES:
            for label, crop, pool in (("direct_7x7", output_size, 0),
                                      ("crop14_pool2", output_size * 2, 2)):
                key = f"{mode}|{coordinate_mode}|{label}"
                try:
                    candidate = crop_resize_sampling_grid(
                        CALIBRATION_ROI, output_size, mode, coordinate_mode, spatial_scale,
                        CALIBRATION_SIZE, average_pool=pool, crop_size=crop,
                    )
                except ProbeError as exc:
                    results[key] = {"ok": False, "error": str(exc)[:200]}
                    continue
                fit = fit_affine(reference, candidate)
                results[key] = {
                    "ok": True,
                    "fit": fit,
                    "max_grid_offset_px": float(np.abs(reference - candidate).max()),
                    "mean_grid_offset_px": float(np.abs(reference - candidate).mean()),
                }
    return {
        "reference_grid_shape": list(reference.shape),
        "calibration_roi_xyxy": CALIBRATION_ROI.tolist(),
        "configurations": results,
    }


def best_grid_configuration(calibration: dict) -> tuple:
    """The configuration whose sampling grid is closest to torchvision's.

    **This cannot pick the construction on its own, and treating it as if it could was a real bug.**
    The calibration input is an affine ramp, and the average of an affine function over any symmetric
    sample set equals its value at the centroid — which is exactly why the grid can be recovered at
    all, and exactly why the metric is *blind to `sampling_ratio`*. `direct_7x7` and `crop14_pool2`
    therefore tie at ~2e-06, and an earlier version took `min()` of that tie, which resolved by
    insertion order to `direct_7x7` and recorded it as the chosen construction. Measured on real
    features, `direct_7x7` has a ~50% relative residual where `crop14_pool2` has ~0.006: the tie-break
    was picking the wrong operator.

    So this returns the geometry winner, and `choose_construction` below decides which construction
    to actually use, on values.
    """
    scored = [
        (key, value["max_grid_offset_px"])
        for key, value in calibration["configurations"].items()
        if value.get("ok")
    ]
    if not scored:
        raise ProbeError("no CropResize configuration produced a usable sampling grid")
    return min(scored, key=lambda item: item[1])


def choose_construction(features: np.ndarray, boxes_xyxy: np.ndarray, spatial_scale: float, *,
                        mode: str = "ROI_ALIGN_MODE",
                        box_coordinate_mode: str = "CORNERS_HEIGHT_FIRST") -> dict:
    """Run the value test the grid metric cannot: compare constructions on real feature maps.

    This is the step the module docstring calls (iii) — the falsifiable part. The prediction is that
    cropping at 2x and average-pooling 2x2 reproduces `sampling_ratio=2`'s averaging while a bare 7x7
    crop does not, and unlike the grid comparison this can actually fail.
    """
    results = {}
    for label, crop, pool in (("direct_7x7", 7, 0), ("crop14_pool2", 14, 2)):
        results[label] = measure_on_features(
            features, boxes_xyxy, mode=mode, box_coordinate_mode=box_coordinate_mode,
            spatial_scale=spatial_scale, average_pool=pool, crop_size=crop,
        )
    winner = min(results.items(), key=lambda item: item[1]["relative_mean_abs_diff"])
    return {"constructions": results, "chosen": winner[0],
            "chosen_relative_mean_abs_diff": winner[1]["relative_mean_abs_diff"]}


def axis_swap_sensitivity(spatial_scale: float = 1.0, output_size: int = 7) -> dict:
    """Prove the calibration can see a coordinate-layout error, by committing one deliberately.

    Packing an ROI width-first while telling the layer it is height-first is the mistake that would
    otherwise be indistinguishable from a genuine operator difference. If the honest packing and the
    swapped packing produced similar grids, every "match" this file reports would be worthless — so
    the separation is measured rather than assumed, and it lives in the harness rather than in a
    docstring claiming it was checked once.
    """
    reference = torchvision_sampling_grid(
        CALIBRATION_ROI, output_size, spatial_scale, 2, False, CALIBRATION_SIZE
    )
    honest = crop_resize_sampling_grid(
        CALIBRATION_ROI, output_size, "ROI_ALIGN_MODE", "CORNERS_HEIGHT_FIRST", spatial_scale,
        CALIBRATION_SIZE,
    )
    probe = crop_resize_probe(
        channels=3, height=CALIBRATION_SIZE, width=CALIBRATION_SIZE, roi_count=1,
        target_height=output_size, target_width=output_size, mode="ROI_ALIGN_MODE",
        box_coordinate_mode="CORNERS_HEIGHT_FIRST", spatial_scale=spatial_scale,
    )
    swapped_rois = pack_rois(CALIBRATION_ROI, "CORNERS_WIDTH_FIRST")
    out = np.asarray(
        probe.run(features=_coordinate_ramp(CALIBRATION_SIZE, CALIBRATION_SIZE), rois=swapped_rois)["pooled"]
    ).reshape(1, 3, output_size, output_size)
    swapped = np.stack([out[:, 0], out[:, 1]], axis=-1)

    return {
        "honest_packing_max_grid_offset_px": float(np.abs(reference - honest).max()),
        "swapped_packing_max_grid_offset_px": float(np.abs(reference - swapped).max()),
        "harness_can_detect_a_swap": bool(
            np.abs(reference - swapped).max() > 100 * max(np.abs(reference - honest).max(), 1e-9)
        ),
    }


def compensated_boxes(boxes_xyxy: np.ndarray, fit: dict) -> np.ndarray:
    """Apply the fitted affine as a pre-compensation of ROI coordinates.

    `reference = scale * candidate + offset` describes where the candidate samples relative to where
    torchvision does, so feeding `(box - offset) / scale` makes it sample where torchvision would.
    """
    row, col = fit["row"], fit["col"]
    out = boxes_xyxy.astype(np.float64).copy()
    out[:, 0] = (out[:, 0] - col["offset"]) / col["scale"]
    out[:, 2] = (out[:, 2] - col["offset"]) / col["scale"]
    out[:, 1] = (out[:, 1] - row["offset"]) / row["scale"]
    out[:, 3] = (out[:, 3] - row["offset"]) / row["scale"]
    return out.astype(np.float32)


def measure_on_features(features: np.ndarray, boxes_xyxy: np.ndarray, *, mode: str,
                        box_coordinate_mode: str, spatial_scale: float, output_size: int = 7,
                        sampling_ratio: int = 2, average_pool: int = 0,
                        crop_size: int | None = None, fit: dict | None = None) -> dict:
    """Step 3: the residual on real feature maps, with and without pre-compensation."""
    reference = roi_align(
        torch.from_numpy(features),
        [torch.from_numpy(boxes_xyxy)],
        output_size=(output_size, output_size),
        spatial_scale=spatial_scale,
        sampling_ratio=sampling_ratio,
        aligned=False,
    ).numpy()

    boxes = compensated_boxes(boxes_xyxy, fit) if fit else boxes_xyxy
    crop = crop_size or output_size
    probe = crop_resize_probe(
        channels=features.shape[1], height=features.shape[2], width=features.shape[3],
        roi_count=boxes.shape[0], target_height=crop, target_width=crop, mode=mode,
        box_coordinate_mode=box_coordinate_mode, spatial_scale=spatial_scale,
        average_pool=average_pool,
    )
    candidate = np.asarray(
        probe.run(features=features.reshape(1, *features.shape), rois=pack_rois(boxes, box_coordinate_mode))["pooled"]
    ).reshape(reference.shape)

    difference = np.abs(reference - candidate)
    scale = float(np.abs(reference).mean()) or 1.0
    return {
        "max_abs_diff": float(difference.max()),
        "mean_abs_diff": float(difference.mean()),
        "relative_mean_abs_diff": float(difference.mean() / scale),
        "pre_compensated": fit is not None,
        "construction": f"crop{crop}" + (f"_pool{average_pool}" if average_pool else "_direct"),
    }
