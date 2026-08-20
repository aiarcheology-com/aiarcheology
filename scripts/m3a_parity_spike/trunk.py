"""A real Core ML side for the trunk, and the substitution harness that composes the pieces.

Two problems this solves.

**The ticket mandates an elementwise comparison of backbone+FPN features and of the raw RPN
objectness and deltas.** A harness that only swaps *operations* into the torch pipeline cannot supply
that: with no Core ML backbone and no Core ML RPN head, both sides of the comparison are torch and
the difference is zero by construction — a criterion answered by comparing the oracle with itself.
So the trunk and the RPN head are genuinely converted and genuinely run. Neither contains control
flow or a dynamic shape, so `coremltools`' torch converter handles them; `convert_to="neuralnetwork"`
keeps the result in the format this repository emits, and pinning a `minimum_deployment_target` of
iOS15 or later is refused by coremltools for exactly that reason, so it is left unset.

Using the torch converter here is not a contradiction of "M3c emits this natively". It is a
measurement shortcut for the part of the graph that is uncontroversially convertible: the question
this spike exists to answer is about the ROI stage, and hand-building 134 convolution layers to
re-measure a conv stack would spend the budget on the part nobody doubts.

**Op-level parity is not composition.** Each substitution replaces exactly one stage's output with
the corresponding Core ML result and runs everything else in torch, so a detection-set change is
attributable to that stage. Then all of them are substituted together, which is the number that says
whether the errors stack or cancel.

The composed pass runs twice, once in float32 and once with every interface cast through float16,
because the model that ships will not be float32 and a chain of small float32 agreements says nothing
about a chain of float16 ones.
"""

from __future__ import annotations

import numpy as np
import torch
import torchvision

import coremltools as ct

from probes import CPU_ONLY, crop_resize_probe, pack_rois

FPN_LEVEL_KEYS = ("0", "1", "2", "3", "pool")


class _Trunk(torch.nn.Module):
    """backbone + FPN as a traceable module returning a fixed tuple."""

    def __init__(self, detector: torch.nn.Module):
        super().__init__()
        self.backbone = detector.backbone

    def forward(self, image):
        features = self.backbone(image)
        return tuple(features[key] for key in FPN_LEVEL_KEYS)


class _RPNHead(torch.nn.Module):
    """The RPN head alone: four levels in, objectness and deltas out."""

    def __init__(self, detector: torch.nn.Module):
        super().__init__()
        self.head = detector.rpn.head

    def forward(self, f0, f1, f2, f3, f4):
        objectness, deltas = self.head([f0, f1, f2, f3, f4])
        return tuple(objectness) + tuple(deltas)


def convert(module: torch.nn.Module, example_inputs: tuple, names: list) -> ct.models.MLModel:
    """Trace and convert one torch module to an NN-spec Core ML model."""
    module.eval()
    with torch.no_grad():
        traced = torch.jit.trace(module, example_inputs)
    return ct.convert(
        traced,
        inputs=[
            ct.TensorType(name=name, shape=tuple(tensor.shape))
            for name, tensor in zip(names, example_inputs)
        ],
        convert_to="neuralnetwork",
        compute_units=CPU_ONLY,
    )


def _ordered_outputs(model: ct.models.MLModel, payload: dict, reference: tuple) -> list:
    """Match Core ML's arbitrarily-named outputs back onto the reference tuple, by spec order.

    coremltools renames outputs after internal MIL variables (`var_905`, sometimes `input`), so the
    names carry no meaning — but the order in `spec.description.output` follows the traced tuple, and
    that is stable.

    Matching by element count instead looks tempting and is wrong: the RPN head emits objectness at
    `[1, 3, 200, 200]` and deltas at `[1, 12, 100, 100]`, which are both 120000 elements, so a
    size-based match is genuinely ambiguous and picked the wrong tensor.

    The check below is a **size** assertion, not a shape one — Core ML returns these flattened, so
    the true shape is not recoverable from the output to compare against. It catches a
    wrong-length output but would not catch a same-size transposition; what actually protects the
    ordering is `spec.description.output` following the traced tuple. Said plainly here because an
    earlier version of this docstring called it a shape assertion, which claimed a guarantee the
    code does not provide.
    """
    produced = model.predict(payload)
    names = [output.name for output in model.get_spec().description.output]
    if len(names) != len(reference):
        raise RuntimeError(f"expected {len(reference)} Core ML outputs, got {len(names)}")

    matched = []
    for name, tensor in zip(names, reference):
        want = tuple(tensor.shape)
        value = np.asarray(produced[name])
        if value.size != int(np.prod(want)):
            raise RuntimeError(f"Core ML output '{name}' has {value.size} elements, expected {want}")
        matched.append(value.reshape(want))
    return matched


def elementwise_trunk_report(detector: torch.nn.Module, image_chw: np.ndarray) -> dict:
    """The ticket's stage-wise elementwise number for backbone+FPN, with a real Core ML side."""
    with torch.no_grad():
        images, _ = detector.transform([torch.from_numpy(image_chw)])
        tensors = images.tensors
        reference = _Trunk(detector)(tensors)

    model = convert(_Trunk(detector), (tensors,), ["image"])
    produced = _ordered_outputs(model, {"image": tensors.numpy()}, reference)

    levels = {}
    for key, want, got in zip(FPN_LEVEL_KEYS, reference, produced):
        difference = np.abs(got - want.numpy())
        levels[f"level_{key}"] = {
            "shape": list(want.shape),
            "max_abs_diff": float(difference.max()),
            "mean_abs_diff": float(difference.mean()),
        }
    return {
        "converted_layers": len(model.get_spec().neuralNetwork.layers),
        "format": model.get_spec().WhichOneof("Type"),
        "levels": levels,
    }


def elementwise_rpn_head_report(detector: torch.nn.Module, image_chw: np.ndarray) -> dict:
    """The same for raw RPN objectness and deltas — the ticket's other elementwise stage.

    Explicitly *before* top-K, which is the only place an elementwise comparison is meaningful: past
    a top-K a sub-tolerance score change reorders the output set, so the right instrument downstream
    is detection-level matching, not a tensor norm.
    """
    with torch.no_grad():
        images, _ = detector.transform([torch.from_numpy(image_chw)])
        features = detector.backbone(images.tensors)
        feature_list = [features[key] for key in FPN_LEVEL_KEYS]
        reference = _RPNHead(detector)(*feature_list)

    model = convert(_RPNHead(detector), tuple(feature_list), [f"f{i}" for i in range(5)])
    payload = {f"f{i}": tensor.numpy() for i, tensor in enumerate(feature_list)}
    produced = _ordered_outputs(model, payload, reference)

    objectness, deltas = {}, {}
    for index, (want, got) in enumerate(zip(reference, produced)):
        difference = np.abs(got - want.numpy())
        entry = {
            "shape": list(want.shape),
            "max_abs_diff": float(difference.max()),
            "mean_abs_diff": float(difference.mean()),
        }
        (objectness if index < 5 else deltas)[f"level_{index % 5}"] = entry
    return {"objectness": objectness, "deltas": deltas}


# --------------------------------------------------------------------------------------------
# The substitution harness
# --------------------------------------------------------------------------------------------


def _level_scales(features: list, image_size: tuple) -> list:
    """The spatial scale torchvision derives per FPN level (`poolers.py`, `setup_scales`)."""
    return [float(feature.shape[-1]) / float(image_size[-1]) for feature in features]


def multi_scale_roi_align(features: list, boxes: torch.Tensor, image_size: tuple, *,
                          output_size: int = 7, sampling_ratio: int = 2,
                          backend: str = "torch") -> torch.Tensor:
    """torchvision's MultiScaleRoIAlign, reimplemented so the pooling backend can be swapped.

    The reimplementation is what makes substitution possible: torchvision's own module calls
    `roi_align` internally with no seam. Level assignment stays torch in both backends so that a
    difference is attributable to the pooling operator alone — level assignment has its own criterion
    and its own measurement.
    """
    scales = _level_scales(features[:4], image_size)
    areas = (boxes[:, 2] - boxes[:, 0]) * (boxes[:, 3] - boxes[:, 1])
    side = torch.sqrt(areas.clamp(min=0))
    # floor(4 + log2(s/224) + eps), clamped to the four pooled levels — eps OUTSIDE the log, as
    # torchvision has it (`poolers.py:78`). This line previously carried a second epsilon *inside*
    # the logarithm as a guard against log2(0), which is the exact substitution `criterion_levels`
    # exists to warn about: it is a different function, and the comment claimed otherwise. It
    # changed nothing measurable here — 0 of 997 real proposals moved level, and this set contains no
    # zero-area boxes — but a guard that contradicts its own comment is how the next reader is
    # misled. torch.log2(0) is -inf, which the clamp below sends to level 2 without help.
    target = torch.floor(4.0 + torch.log2(side / 224.0) + torch.tensor(1e-6))
    target = target.clamp(min=2, max=5).to(torch.int64) - 2

    pooled = torch.zeros((boxes.shape[0], features[0].shape[1], output_size, output_size),
                         dtype=torch.float32)
    for level in range(4):
        selection = torch.nonzero(target == level).squeeze(1)
        if selection.numel() == 0:
            continue
        level_boxes = boxes[selection]
        if backend == "torch":
            result = torchvision.ops.roi_align(
                features[level], [level_boxes], output_size=(output_size, output_size),
                spatial_scale=scales[level], sampling_ratio=sampling_ratio, aligned=False,
            )
        elif backend == "coreml":
            result = _crop_resize_pool(features[level], level_boxes, scales[level], output_size)
        else:
            raise ValueError(backend)
        # Explicit rather than implicit: the Core ML path returns whatever numpy handed back, and a
        # silent float64 promotion here would quietly change the precision being measured.
        pooled[selection] = result.to(pooled.dtype)
    return pooled


def _crop_resize_pool(feature: torch.Tensor, boxes: torch.Tensor, spatial_scale: float,
                      output_size: int) -> torch.Tensor:
    """CropResize at 2x followed by a 2x2 average pool — the construction the layer documents."""
    array = feature.detach().numpy()
    box_array = boxes.detach().numpy().astype(np.float32)
    probe = crop_resize_probe(
        channels=array.shape[1], height=array.shape[2], width=array.shape[3],
        roi_count=box_array.shape[0], target_height=output_size * 2, target_width=output_size * 2,
        mode="ROI_ALIGN_MODE", box_coordinate_mode="CORNERS_HEIGHT_FIRST",
        spatial_scale=spatial_scale, average_pool=2,
    )
    out = probe.run(features=array.reshape(1, *array.shape),
                    rois=pack_rois(box_array, "CORNERS_HEIGHT_FIRST"))["pooled"]
    return torch.from_numpy(
        np.asarray(out).reshape(box_array.shape[0], array.shape[1], output_size, output_size)
    )


def _cast(tensor: torch.Tensor, half: bool) -> torch.Tensor:
    """Round-trip through float16 to price the precision the shipping model will actually use."""
    return tensor.to(torch.float16).to(torch.float32) if half else tensor


def detections_with_substitutions(detector: torch.nn.Module, image_chw: np.ndarray, *,
                                  substitute_pooling: bool = False, half: bool = False,
                                  wheel_threshold: float = 0.2) -> dict:
    """Run the detector stage by stage, optionally substituting Core ML results, to the final boxes.

    Ends where ADAF ends — after the wheel's extra class-agnostic NMS at 0.2 — because that, not
    torchvision's postprocess, is the output ADAF's own pipeline vectorises.
    """
    with torch.no_grad():
        images, _ = detector.transform([torch.from_numpy(image_chw)])
        features = detector.backbone(images.tensors)
        feature_list = [_cast(features[key], half) for key in FPN_LEVEL_KEYS]
        proposals, _ = detector.rpn(images, {key: value for key, value in zip(FPN_LEVEL_KEYS, feature_list)})
        boxes = proposals[0]

        pooled = multi_scale_roi_align(
            feature_list, boxes, images.tensors.shape[-2:],
            backend="coreml" if substitute_pooling else "torch",
        )
        pooled = _cast(pooled, half)
        head = detector.roi_heads.box_head(pooled)
        class_logits, box_regression = detector.roi_heads.box_predictor(head)
        detected_boxes, scores, labels = detector.roi_heads.postprocess_detections(
            class_logits, box_regression, [boxes], images.image_sizes
        )
        result = detector.transform.postprocess(
            [{"boxes": detected_boxes[0], "scores": scores[0], "labels": labels[0]}],
            images.image_sizes, [image_chw.shape[-2:]],
        )[0]

        keep = torchvision.ops.nms(result["boxes"], result["scores"], wheel_threshold)

    return {
        "boxes": result["boxes"][keep].numpy(),
        "scores": result["scores"][keep].numpy(),
        "substituted_pooling": substitute_pooling,
        "float16_interfaces": half,
    }


def compute_unit_report(detector: torch.nn.Module, image_chw: np.ndarray) -> dict:
    """The trunk's elementwise error across compute units and weight precisions.

    M3a's headline elementwise figure (5.98e-05) is CPU-only float32, which is a controlled semantic
    baseline and **not** what the app runs: `DeepDriver.swift:67` leaves `MLModelConfiguration` at its
    default, so Core ML may place work on the GPU or the Neural Engine and may use float16 there. The
    only evidence for what that costs was a yolov8n proxy.

    This measures it for the real converted trunk, separating the two variables rather than
    conflating them: compute unit (CPU-only against the default `ALL`) and weight precision (float32
    against float16 weights, via NN-spec's own quantisation). A difference that appears only under
    `ALL` is placement; one that appears under float16 weights on CPU is precision.

    The honest limit: this Mac's Neural Engine is not an iPhone's, and Core ML may decline to use it
    for a graph like this. The `used_ane_or_gpu` field cannot be read directly from the framework
    here, so a result matching CPU-only exactly is ambiguous — it may mean placement did not change
    the numbers, or that placement did not change. M3b's device run is what settles it.
    """
    from coremltools.models.neural_network.quantization_utils import quantize_weights

    with torch.no_grad():
        images, _ = detector.transform([torch.from_numpy(image_chw)])
        tensors = images.tensors
        reference = _Trunk(detector)(tensors)

    base = convert(_Trunk(detector), (tensors,), ["image"])
    payload = {"image": tensors.numpy()}

    variants = {}
    for label, spec_source, units in (
        ("cpu_float32", base, CPU_ONLY),
        ("all_float32", base, ct.ComputeUnit.ALL),
        ("cpu_float16_weights", None, CPU_ONLY),
        ("all_float16_weights", None, ct.ComputeUnit.ALL),
    ):
        try:
            if spec_source is None:
                quantised = quantize_weights(base, nbits=16)
                model = ct.models.MLModel(quantised.get_spec(), compute_units=units)
            else:
                model = ct.models.MLModel(spec_source.get_spec(), compute_units=units)
            produced = _ordered_outputs(model, payload, reference)
            worst = max(float(np.abs(got - want.numpy()).max())
                        for want, got in zip(reference, produced))
            mean = float(np.mean([float(np.abs(got - want.numpy()).mean())
                                  for want, got in zip(reference, produced)]))
            variants[label] = {"max_abs_diff": worst, "mean_abs_diff": mean,
                               "compute_units": str(units)}
        except Exception as exc:  # noqa: BLE001 - a variant that cannot run IS the result
            variants[label] = {"error": f"{type(exc).__name__}: {str(exc)[:200]}"}

    return {
        "variants": variants,
        "caveat": "a Mac Neural Engine is not an iPhone's, and Core ML may decline to place this "
                  "graph off the CPU at all; an exact match with CPU-only is therefore ambiguous "
                  "between 'placement changed nothing' and 'placement did not change'",
    }


def detection_level_compute_units(detector: torch.nn.Module, image_chw: np.ndarray,
                                  wheel_threshold: float = 0.2) -> dict:
    """What the compute unit costs in **detections**, which is the only currency that ships.

    The elementwise number under `ComputeUnit.ALL` is alarming on its own, but elementwise upstream of
    a top-K was never the right instrument for a decision — a large tensor difference that does not
    reorder anything changes no output. So the trunk is run under each compute unit and its features
    are fed through the rest of the real detector, ending where ADAF ends: after the wheel's
    class-agnostic NMS at 0.2.
    """
    from criterion_transform import _match_detections

    with torch.no_grad():
        images, _ = detector.transform([torch.from_numpy(image_chw)])
        reference_features = _Trunk(detector)(images.tensors)
    converted = convert(_Trunk(detector), (images.tensors,), ["image"])

    def detections(features) -> tuple:
        mapping = {key: value for key, value in zip(FPN_LEVEL_KEYS, features)}
        with torch.no_grad():
            proposals, _ = detector.rpn(images, mapping)
            pooled = detector.roi_heads.box_roi_pool(mapping, [proposals[0]], images.image_sizes)
            head = detector.roi_heads.box_head(pooled)
            class_logits, box_regression = detector.roi_heads.box_predictor(head)
            boxes, scores, labels = detector.roi_heads.postprocess_detections(
                class_logits, box_regression, [proposals[0]], images.image_sizes
            )
            out = detector.transform.postprocess(
                [{"boxes": boxes[0], "scores": scores[0], "labels": labels[0]}],
                images.image_sizes, [image_chw.shape[-2:]],
            )[0]
            keep = torchvision.ops.nms(out["boxes"], out["scores"], wheel_threshold)
        return out["boxes"][keep].numpy(), out["scores"][keep].numpy()

    base_boxes, base_scores = detections(reference_features)
    rows = {}
    for label, units in (("cpu_only", CPU_ONLY), ("all", ct.ComputeUnit.ALL)):
        try:
            model = ct.models.MLModel(converted.get_spec(), compute_units=units)
            produced = _ordered_outputs(model, {"image": images.tensors.numpy()}, reference_features)
            boxes, scores = detections([torch.from_numpy(array) for array in produced])
            rows[label] = {
                "detections": int(len(boxes)),
                **_match_detections(base_boxes, base_scores, boxes, scores, iou_threshold=0.5),
            }
        except Exception as exc:  # noqa: BLE001
            rows[label] = {"error": f"{type(exc).__name__}: {str(exc)[:200]}"}

    return {
        "torch_baseline_detections": int(len(base_boxes)),
        "by_compute_unit": rows,
        "caveat": "one image, and this Mac's Neural Engine is not an iPhone's; the direction is "
                  "evidence, the magnitude is not transferable to device",
    }
