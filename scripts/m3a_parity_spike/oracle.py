"""The oracle: ADAF's detector, built the way the vendored aitlas wheel builds it.

Everything in this spike is measured against what comes out of here, so this module's job is to be
faithful *and* to refuse to run when it cannot be.

Two things earn their length.

**The density gate.** `scripts/fetch_adaf_checkpoints.sh` writes sparse checkpoints by default: a
file of the true length whose middle is a hole. That is deliberate and good for the Swift reader,
whose entire read set is the end records, the central directory and `data.pkl`. It is fatal here,
because a hole reads back as *zeros* rather than as an error — `torch.load` happens to fail on the
first weight record, but nothing guarantees a partially-populated file would, and a model of zeros
produces confident, meaningless numbers. So the gate refuses to proceed unless the file is provably
dense. Note the manifest records `md5` for whole files and `sha256` only for the head/tail slice
fixtures, so md5 is the digest that can verify a whole checkpoint here.

**Wheel fidelity.** The wheel (`aitlas-0.0.1-py3-none-any.whl`,
sha256 `be2dbb7e3c39c30a91a79b00f7dc3365320cbc57584a8601e286a8b9c91ab69a`) cannot be imported without
dragging in rasterio, albumentations, opencv and segmentation-models-pytorch. The two functions that
are numerically load-bearing are three lines between them, so they are reproduced verbatim below with
their file:line, and `describe_oracle_provenance()` records which route was taken. Everything else
about the model is plain torchvision, which the wheel confirms by passing no overrides at all.
"""

from __future__ import annotations

import hashlib
import json
import platform
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import torch
import torchvision
from torchvision.models.detection import fasterrcnn_resnet50_fpn_v2
from torchvision.models.detection.faster_rcnn import FastRCNNPredictor

REPOSITORY = Path(__file__).resolve().parents[2]
CHECKPOINT_DIR = REPOSITORY / ".adaf-checkpoints"
MANIFEST = REPOSITORY / "Tests/NativeModelConverterTests/Fixtures/ADAF/ADAFCheckpointFixtures.json"

# The vendored wheel, pinned by digest. Recorded in every result file so a later run can tell whether
# ADAF replaced their copy — the ticket asks for exactly this.
WHEEL_SHA256 = "be2dbb7e3c39c30a91a79b00f7dc3365320cbc57584a8601e286a8b9c91ab69a"
WHEEL_PATH_UPSTREAM = "installation/aitlas-0.0.1-py3-none-any.whl"

# `aitlas/base/object_detection.py:31` — `def get_predicted(self, outputs, threshold=0.2)`.
# Not overridden at ADAF's call site: `adaf/adaf_utils.py:137` calls `detect_objects_v2(...)`, and
# `aitlas/base/models.py:687` is `self.get_predicted(outputs)[0]` with no threshold argument.
WHEEL_GET_PREDICTED_THRESHOLD = 0.2

# The four detection checkpoints. Their tensor tables are identical in name, shape and dtype
# (ADAFCheckpointCatalog.swift:92-95) but their *weights* are not, which is why every empirical
# criterion runs on all four rather than on one.
OD_MODEL_IDS = ("OD_ringfort", "OD_barrow", "OD_enclosure", "OD_AO")

# Which ADAF figure is in-class for which checkpoint. On an out-of-class image zero detections is the
# expected result, so it cannot discriminate between input scalings.
IN_CLASS_FIGURE = {
    "OD_ringfort": "ringfort.jpg",
    "OD_barrow": "barrows.jpg",
    "OD_enclosure": "enclosure.jpg",
    "OD_AO": None,  # "all archaeology" — every figure is in-class
}


class OracleError(RuntimeError):
    """Raised when the oracle cannot be built faithfully. Never downgraded to a warning."""


# --------------------------------------------------------------------------------------------
# Provenance and the density gate
# --------------------------------------------------------------------------------------------


def _manifest_entries() -> dict:
    return {entry["id"]: entry for entry in json.loads(MANIFEST.read_text())["models"]}


def _digest(path: Path, algorithm: str) -> str:
    accumulator = hashlib.new(algorithm)
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(4 * 1024 * 1024), b""):
            accumulator.update(chunk)
    return accumulator.hexdigest()


@dataclass
class CheckpointProvenance:
    model_id: str
    file_name: str
    logical_bytes: int
    on_disk_bytes: int
    md5: str
    sha256: str
    sparse_marker_present: bool

    @property
    def dense(self) -> bool:
        # A sparse copy carries the true length with a hole in the middle, so length proves nothing;
        # allocated blocks do.
        return self.on_disk_bytes > self.logical_bytes * 0.9


def gate_checkpoint(model_id: str) -> CheckpointProvenance:
    """Prove the checkpoint on disk is the published file, whole. Raises rather than warns."""
    entry = _manifest_entries()[model_id]
    path = CHECKPOINT_DIR / entry["fileName"]
    if not path.exists():
        raise OracleError(
            f"{model_id}: {path} is missing. Fetch it densely — a sparse copy cannot be measured."
        )

    stat = path.stat()
    provenance = CheckpointProvenance(
        model_id=model_id,
        file_name=entry["fileName"],
        logical_bytes=stat.st_size,
        on_disk_bytes=stat.st_blocks * 512,
        md5=_digest(path, "md5"),
        sha256=_digest(path, "sha256"),
        sparse_marker_present=(CHECKPOINT_DIR / f".{entry['fileName']}.sparse").exists(),
    )

    if provenance.sparse_marker_present:
        raise OracleError(f"{model_id}: the .sparse marker is present — this copy has a hole in it.")
    if not provenance.dense:
        raise OracleError(
            f"{model_id}: only {provenance.on_disk_bytes} bytes are allocated for a "
            f"{provenance.logical_bytes}-byte file. A hole reads back as zeros, not as an error."
        )
    if provenance.md5 != entry["md5"]:
        raise OracleError(
            f"{model_id}: md5 {provenance.md5} does not match the manifest's {entry['md5']}."
        )
    return provenance


def describe_environment() -> dict:
    """Everything a later run needs to reproduce these numbers, or to explain why it cannot."""
    return {
        "python": sys.version.split()[0],
        "torch": torch.__version__,
        "torchvision": torchvision.__version__,
        "numpy": np.__version__,
        "platform": platform.platform(),
        "machine": platform.machine(),
        "macos_build": subprocess.run(
            ["sw_vers", "-buildVersion"], capture_output=True, text=True, check=False
        ).stdout.strip(),
        "wheel": {"upstream_path": WHEEL_PATH_UPSTREAM, "sha256": WHEEL_SHA256},
        # torchvision is a *chosen* oracle: the wheel pins only `torch>=1.10.0, torchvision>=0.11.1`,
        # so this version is not recovered provenance and the write-up says so.
        "oracle_version_is_chosen_not_recovered": True,
    }


# --------------------------------------------------------------------------------------------
# The wheel's two numerically load-bearing functions, reproduced verbatim
# --------------------------------------------------------------------------------------------


def resize_v2(image_hwc: np.ndarray) -> torch.Tensor:
    """`aitlas/transforms/joint_transforms.py:163-170` — `A.Compose([ToTensorV2(p=1.0)])`.

    Despite the name there is no resize and no normalization: albumentations' `ToTensorV2` only moves
    HWC to CHW and wraps in a tensor. It does *not* divide by 255 (torchvision's `ToTensor` does, and
    conflating the two is the easiest way to feed this model a 0..255 tensor it was never trained
    on). All geometry and normalization happen later, inside `GeneralizedRCNNTransform`.
    """
    if image_hwc.ndim != 3:
        raise OracleError(f"expected HWC, got shape {image_hwc.shape}")
    return torch.from_numpy(np.ascontiguousarray(image_hwc.transpose(2, 0, 1)))


def wheel_get_predicted(outputs: list[dict], threshold: float = WHEEL_GET_PREDICTED_THRESHOLD) -> list[dict]:
    """`aitlas/base/object_detection.py:31-43`, reproduced exactly.

    This is the second, class-agnostic NMS pass that torchvision's own postprocess does not do, and
    it is why #654 requires both stages to be emitted: they do not compose into one.
    """
    final_predictions = []
    for output in outputs:
        keep = torchvision.ops.nms(output["boxes"], output["scores"], threshold)
        final_prediction = dict(output)
        final_prediction["boxes"] = final_prediction["boxes"][keep]
        final_prediction["scores"] = final_prediction["scores"][keep]
        final_prediction["labels"] = final_prediction["labels"][keep]
        final_predictions.append(final_prediction)
    return final_predictions


# --------------------------------------------------------------------------------------------
# The detector
# --------------------------------------------------------------------------------------------


@dataclass
class Oracle:
    model_id: str
    model: torch.nn.Module
    provenance: CheckpointProvenance
    training_id: str
    constants: dict = field(default_factory=dict)


def build_oracle(model_id: str) -> Oracle:
    """Construct exactly as `aitlas/models/fasterrcnn.py:13-22` and load ADAF's weights."""
    provenance = gate_checkpoint(model_id)

    # weights_only=True: the checkpoint is an untrusted third-party pickle, and this spike has no
    # business executing it. It is also what makes the read comparable to M2's Swift decoder.
    blob = torch.load(CHECKPOINT_DIR / provenance.file_name, map_location="cpu", weights_only=True)
    state_dict = blob["state_dict"]

    zeroed = [name for name, tensor in state_dict.items() if tensor.numel() and not tensor.any()]
    if zeroed:
        raise OracleError(
            f"{model_id}: {len(zeroed)} tensors are entirely zero (first: {zeroed[0]}). "
            "That is what a sparse checkpoint looks like once it parses."
        )

    # num_classes comes off the checkpoint rather than being hardcoded to ADAF's 2 — the umbrella's
    # "build the graph parameterised, register only ADAF" requirement applies to the spike too.
    num_classes = int(state_dict["roi_heads.box_predictor.cls_score.weight"].shape[0])

    model = fasterrcnn_resnet50_fpn_v2(weights=None)
    in_features = model.roi_heads.box_predictor.cls_score.in_features
    model.roi_heads.box_predictor = FastRCNNPredictor(in_features, num_classes)

    missing, unexpected = model.load_state_dict(state_dict, strict=False)
    if missing or unexpected:
        raise OracleError(
            f"{model_id}: state_dict does not fit the architecture — "
            f"{len(missing)} missing, {len(unexpected)} unexpected (first missing: {missing[:1]})."
        )
    model.eval()

    return Oracle(
        model_id=model_id,
        model=model,
        provenance=provenance,
        training_id=str(blob.get("id", "")),
        constants=read_constants(model),
    )


def read_constants(model: torch.nn.Module) -> dict:
    """Read the postprocess constants off the constructed object, never from the ticket.

    The ticket asserts 0.05 / 0.5 / 100, and it is right — but a spike that inherits its inputs from
    prose is how M1 and M2 each shipped a rule that no real file satisfied. Note `score_thresh` is
    applied as a **strict** `scores > score_thresh` (`roi_heads.py:711`); the same strictness applies
    to ADAF's own 0.5 vectorization cut.
    """
    return {
        "box_score_thresh": model.roi_heads.score_thresh,
        "box_score_thresh_is_strict_greater": True,
        "box_nms_thresh": model.roi_heads.nms_thresh,
        "box_detections_per_img": model.roi_heads.detections_per_img,
        "rpn_pre_nms_top_n_test": model.rpn._pre_nms_top_n["testing"],
        "rpn_post_nms_top_n_test": model.rpn._post_nms_top_n["testing"],
        "rpn_nms_thresh": model.rpn.nms_thresh,
        "rpn_score_thresh": model.rpn.score_thresh,
        "rpn_min_size": model.rpn.min_size,
        "transform_min_size": list(model.transform.min_size),
        "transform_max_size": model.transform.max_size,
        "transform_image_mean": list(model.transform.image_mean),
        "transform_image_std": list(model.transform.image_std),
        "box_roi_pool_output_size": list(model.roi_heads.box_roi_pool.output_size),
        "box_roi_pool_sampling_ratio": model.roi_heads.box_roi_pool.sampling_ratio,
        "box_roi_pool_featmap_names": list(model.roi_heads.box_roi_pool.featmap_names),
        "box_head_in_features": model.roi_heads.box_predictor.cls_score.in_features,
        "num_classes": model.roi_heads.box_predictor.cls_score.out_features,
        "wheel_get_predicted_threshold": WHEEL_GET_PREDICTED_THRESHOLD,
    }


def anchor_geometry(model: torch.nn.Module, tile_px: int) -> dict:
    """The static shape the emitted graph would have to declare, measured rather than assumed.

    Two things bite here. A `tile_px` tile does **not** run at `tile_px`: `GeneralizedRCNNTransform`
    resizes the short side to `min_size` (800) and pads to a multiple of 32. And the per-level
    pre-NMS cut is `min(pre_nms_top_n, anchors_at_level)` (`rpn.py:236` via `det_utils._topk_min`),
    not `pre_nms_top_n` everywhere — the topmost level holds fewer anchors than the cut, so a harness
    that pads every level to 1000 mismeasures both the rank margin and the padding cost.
    """
    with torch.no_grad():
        images, _ = model.transform([torch.zeros(3, tile_px, tile_px)])
        features = model.backbone(images.tensors)
        names = list(features.keys())
        shapes = [tuple(features[name].shape) for name in names]
        anchors_per_location = model.rpn.anchor_generator.num_anchors_per_location()

    per_level = [count * shape[2] * shape[3] for count, shape in zip(anchors_per_location, shapes)]
    pre_nms = model.rpn._pre_nms_top_n["testing"]
    return {
        "tile_px": tile_px,
        "padded_input_shape": list(images.tensors.shape),
        "feature_levels": names,
        "feature_shapes": [list(shape) for shape in shapes],
        "anchors_per_location": list(anchors_per_location),
        "anchors_per_level": per_level,
        "pre_nms_top_n_per_level": [min(pre_nms, count) for count in per_level],
        "static_pre_nms_candidates": sum(min(pre_nms, count) for count in per_level),
    }
