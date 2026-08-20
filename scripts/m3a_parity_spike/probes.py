"""NN-spec probes: single Core ML operations, built, compiled and run in isolation.

Why NN-spec and not MIL. This repository emits the legacy neural-network protobuf
(`NATIVE_MODEL_CONVERSION.md`), so a MIL measurement would answer a question about a format M3c is
not going to emit. coremltools appears here only as a throwaway *builder* of NN-spec protobufs and as
the `predict` harness; its torch converter is used in exactly one place (the trunk, see `trunk.py`)
and never as the shipping path. Worth recording while we are here: coremltools 9.0 registers no
`roi_align` mapping at all — `roi_align` has zero matches in the installed package — so there is no
upstream conversion route to inherit a choice from, which is itself evidence for the ticket.

Two mechanical facts cost real time to discover, so they are stated once here:

- **Every input must be declared rank 5.** `CropResize` validates `rank >= 5` and rejects a rank-3
  declaration with `has input rank 3 but expects rank at least 5`. Inputs are therefore declared in
  NN-spec's `(Seq, Batch, C, H, W)` layout.
- **ROIs are `[N, 1, 4 or 5, 1, 1]`**, with the 4-value layout ordered by `box_indices_mode`.

Compute units are pinned to CPU for every probe. That is a deliberate choice of a controlled semantic
baseline, not a claim about the app: the app leaves `MLModelConfiguration` at its default
(`DeepDriver.swift:67`), so the shipping path may run on GPU or ANE with fp16 and graph partitioning.
That divergence is a named residual risk this spike does not measure.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

import coremltools as ct
from coremltools.models import datatypes
from coremltools.models.neural_network import NeuralNetworkBuilder

CPU_ONLY = ct.ComputeUnit.CPU_ONLY

CROP_RESIZE_MODES = (
    "STRICT_ALIGN_ENDPOINTS_MODE",
    "ALIGN_ENDPOINTS_MODE",
    "UPSAMPLE_MODE",
    "ROI_ALIGN_MODE",
)
BOX_COORDINATE_MODES = (
    "CORNERS_HEIGHT_FIRST",
    "CORNERS_WIDTH_FIRST",
    "CENTER_SIZE_HEIGHT_FIRST",
    "CENTER_SIZE_WIDTH_FIRST",
)


class ProbeError(RuntimeError):
    """A probe that cannot be built or run. Reported as a result, never swallowed."""


@dataclass
class Probe:
    """One compiled single-op Core ML model plus the shapes it was declared with."""

    model: ct.models.MLModel
    input_shapes: dict

    def run(self, **arrays: np.ndarray) -> dict:
        payload = {}
        for name, array in arrays.items():
            declared = self.input_shapes[name]
            payload[name] = np.ascontiguousarray(array, dtype=np.float32).reshape(declared)
        return self.model.predict(payload)


def _build(inputs: list, outputs: list, populate) -> Probe:
    builder = NeuralNetworkBuilder(inputs, outputs, disable_rank5_shape_mapping=True)
    populate(builder)
    try:
        model = ct.models.MLModel(builder.spec, compute_units=CPU_ONLY)
    except Exception as exc:  # noqa: BLE001 - a failure to compile IS the measurement
        raise ProbeError(f"{type(exc).__name__}: {exc}") from exc
    return Probe(model=model, input_shapes={name: shape.dimensions for name, shape in inputs})


# --------------------------------------------------------------------------------------------
# CropResize — criterion 1
# --------------------------------------------------------------------------------------------


def crop_resize_probe(
    *,
    channels: int,
    height: int,
    width: int,
    roi_count: int,
    target_height: int,
    target_width: int,
    mode: str = "ROI_ALIGN_MODE",
    box_coordinate_mode: str = "CORNERS_HEIGHT_FIRST",
    spatial_scale: float = 1.0,
    normalized_roi: bool = False,
    average_pool: int = 0,
) -> Probe:
    """One `CropResize`, optionally followed by an average pool.

    `average_pool` is the whole point of the construction. `add_crop_resize`'s own docstring says
    *"RoI Align layer can be implemented with this layer followed by a pooling layer"*: torchvision's
    `sampling_ratio=2` averages 2x2 bilinear samples per output bin, while CropResize takes a single
    bilinear sample per output cell. So cropping at 2x the target and average-pooling 2x2 is the
    documented construction, and comparing a bare 7x7 CropResize against `roi_align` measures a
    residual that the construction created rather than anything about Core ML.
    """
    inputs = [
        ("features", datatypes.Array(1, 1, channels, height, width)),
        ("rois", datatypes.Array(roi_count, 1, 4, 1, 1)),
    ]

    def populate(builder: NeuralNetworkBuilder) -> None:
        builder.add_crop_resize(
            name="crop_resize",
            input_names=["features", "rois"],
            output_name="cropped" if average_pool else "pooled",
            target_height=target_height,
            target_width=target_width,
            mode=mode,
            normalized_roi=normalized_roi,
            box_indices_mode=box_coordinate_mode,
            spatial_scale=spatial_scale,
        )
        if average_pool:
            builder.add_pooling(
                name="average_pool",
                height=average_pool,
                width=average_pool,
                stride_height=average_pool,
                stride_width=average_pool,
                layer_type="AVERAGE",
                padding_type="VALID",
                input_name="cropped",
                output_name="pooled",
                exclude_pad_area=True,
            )

    return _build(inputs, [("pooled", None)], populate)


def pack_rois(boxes_xyxy: np.ndarray, box_coordinate_mode: str) -> np.ndarray:
    """Lay out `[x0, y0, x1, y1]` boxes the way a given `box_indices_mode` expects.

    Getting this wrong is indistinguishable from a genuine operator difference on a square, centred
    ROI, which is exactly why the calibration in `criterion_roi_align.py` uses a non-square,
    off-centre ROI over an anisotropic ramp: an axis swap then shows up as a transposed gradient
    instead of hiding inside the residual.
    """
    count = boxes_xyxy.shape[0]
    packed = np.zeros((count, 1, 4, 1, 1), dtype=np.float32)
    x0, y0, x1, y1 = (boxes_xyxy[:, index] for index in range(4))
    if box_coordinate_mode == "CORNERS_HEIGHT_FIRST":
        values = (y0, x0, y1, x1)
    elif box_coordinate_mode == "CORNERS_WIDTH_FIRST":
        values = (x0, y0, x1, y1)
    elif box_coordinate_mode == "CENTER_SIZE_HEIGHT_FIRST":
        values = ((y0 + y1) / 2, (x0 + x1) / 2, y1 - y0, x1 - x0)
    elif box_coordinate_mode == "CENTER_SIZE_WIDTH_FIRST":
        values = ((x0 + x1) / 2, (y0 + y1) / 2, x1 - x0, y1 - y0)
    else:
        raise ProbeError(f"unknown box_indices_mode {box_coordinate_mode}")
    for index, value in enumerate(values):
        packed[:, 0, index, 0, 0] = value
    return packed


# --------------------------------------------------------------------------------------------
# Level assignment — criterion 3
# --------------------------------------------------------------------------------------------


def level_assignment_probe(*, count: int, canonical_level: float, canonical_scale: float, eps: float,
                           level_min: int, level_max: int) -> Probe:
    """`floor(k0 + log2(sqrt(area)/s0) + eps)`, clamped — built from NN-spec primitives.

    Note where the epsilon goes. torchvision computes
    `floor(lvl0 + log2(s / s0) + eps)` (`poolers.py:78`) — the eps is added *outside* the logarithm,
    not inside it. Writing `log2(s/s0 + eps)` is a different function, and near a level boundary the
    difference is exactly the thing this criterion exists to detect.

    NN-spec has no log2, so this uses natural log scaled by 1/ln 2.
    """
    inputs = [("areas", datatypes.Array(count, 1, 1, 1, 1))]

    def populate(builder: NeuralNetworkBuilder) -> None:
        builder.add_unary(name="sqrt_area", input_name="areas", output_name="s", mode="sqrt")
        # The unary layer computes f(scale * x + shift), so `scale` folds the 1/s0 division into
        # the logarithm's argument: ln(s / s0).
        builder.add_unary(
            name="ln_ratio", input_name="s", output_name="ln_ratio", mode="log",
            scale=float(1.0 / canonical_scale),
        )
        # log2(x) = ln(x)/ln(2), then + k0 + eps — one affine step, with the epsilon added OUTSIDE
        # the logarithm exactly as torchvision does it (`poolers.py:78`).
        builder.add_scale(
            name="log2_shift", W=np.array([1.0 / np.log(2.0)], dtype=np.float32),
            b=np.array([canonical_level + eps], dtype=np.float32), has_bias=True,
            input_name="ln_ratio", output_name="shifted",
        )
        builder.add_floor(name="floor", input_name="shifted", output_name="floored")
        builder.add_clip(
            name="clamp", input_name="floored", output_name="levels",
            min_value=float(level_min), max_value=float(level_max),
        )

    return _build(inputs, [("levels", None)], populate)


# --------------------------------------------------------------------------------------------
# NMS — criterion 4
# --------------------------------------------------------------------------------------------


def nms_layer_probe(*, box_count: int, class_count: int, iou_threshold: float,
                    score_threshold: float, max_boxes: int, per_class_suppression: bool) -> Probe:
    """The NN-*layer* NMS, which is what a mid-graph suppression would have to use.

    This is a different operator from the standalone NMS model the repository currently emits as its
    terminal pipeline stage (`NativeModelDetectorPipeline.swift:93`), and it has different semantics:
    fixed, padded outputs plus a valid-count, where the standalone model has flexible outputs and a
    Vision-facing interface. Measuring one and reporting the other would be a category error, so the
    terminal stage is probed separately by `standalone_nms_spec`.

    The padding is not a detail. Surviving boxes fewer than `max_boxes` are padded out with zero
    boxes, and in a static graph those zeros flow onward into level assignment (`log2(sqrt(0))`) and
    the box head, which will happily assign them fresh scores.
    """
    # Unlike CropResize, which validates rank >= 5, the NMS kernel requires its first two inputs to
    # be rank 3 exactly: [batch, boxes, 4] and [batch, boxes, classes].
    inputs = [
        ("boxes", datatypes.Array(1, box_count, 4)),
        ("scores", datatypes.Array(1, box_count, class_count)),
    ]
    outputs = [("kept_boxes", None), ("kept_scores", None), ("kept_indices", None), ("valid_count", None)]

    def populate(builder: NeuralNetworkBuilder) -> None:
        builder.add_nms(
            name="nms",
            input_names=["boxes", "scores"],
            output_names=["kept_boxes", "kept_scores", "kept_indices", "valid_count"],
            iou_threshold=iou_threshold,
            score_threshold=score_threshold,
            max_boxes=max_boxes,
            per_class_suppression=per_class_suppression,
        )

    return _build(inputs, outputs, populate)


def standalone_nms_spec(*, iou_threshold: float, confidence_threshold: float, labels: list,
                        per_class: bool):
    """The standalone NMS *model* — the operator this repo actually emits as its terminal stage.

    Built as a bare spec rather than a `Probe` because it is a pipeline stage with a Vision-facing
    interface, not something to feed arrays to in isolation. `perClass` left false suppresses across
    classes, matching both the reference detector and the repo's comment at
    `NativeModelDetectorPipeline.swift:95-96`.
    """
    spec = ct.proto.Model_pb2.Model()
    spec.specificationVersion = 4
    nms = spec.nonMaximumSuppression
    nms.iouThreshold = iou_threshold
    nms.confidenceThreshold = confidence_threshold
    nms.pickTop.perClass = per_class
    for label in labels:
        nms.stringClassLabels.vector.append(label)
    return spec
