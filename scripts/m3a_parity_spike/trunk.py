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
    """Match Core ML's arbitrarily-named outputs back onto the reference tuple, by shape.

    coremltools names outputs after internal MIL variables (`var_905`, and sometimes `input`), so
    positional recovery has to go through shape. Every FPN level here has a distinct spatial size, so
    the mapping is unambiguous; the assertion makes that a checked property rather than a hope.
    """
    produced = {name: np.asarray(value) for name, value in model.predict(payload).items()}
    matched, used = [], set()
    for tensor in reference:
        want = tuple(tensor.shape)
        candidates = [
            name for name, value in produced.items()
            if name not in used and value.size == int(np.prod(want))
        ]
        if not candidates:
            raise RuntimeError(f"no Core ML output matches shape {want}")
        if len(candidates) > 1:
            raise RuntimeError(f"ambiguous Core ML output for shape {want}: {candidates}")
        used.add(candidates[0])
        matched.append(produced[candidates[0]].reshape(want))
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
    # floor(4 + log2(s/224) + eps), clamped to the four pooled levels — eps OUTSIDE the log.
    target = torch.floor(4.0 + torch.log2(side / 224.0 + 1e-12) + torch.tensor(1e-6))
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
