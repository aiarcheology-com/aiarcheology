#!/usr/bin/env python3
"""Detection-set parity gate for the emitted ADAF Faster R-CNN detector.

This is deliberately an oracle test, not a second Faster R-CNN implementation. The reference calls
torchvision's transform to establish the resize boundary, then its backbone, RPN, RoI heads and
postprocess, followed by ADAF's own final NMS function from ``oracle.py``. The runner dumps the exact
8-bit ImageIO/resized canvas sent to Core ML and torchvision consumes those bytes after the native
affine; the report retains the transform reconstruction's byte mismatch count for auditability.

Run only with dense checkpoints and the M3a interpreter:

    PYTHONPATH=scripts/m3a_parity_spike .venv-m3a/bin/python \
      scripts/test_adaf_fasterrcnn_parity.py --report /private/tmp/adaf-parity.json
"""

from __future__ import annotations

import argparse
import gc
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
import torch
from PIL import Image
from torchvision.models.detection.image_list import ImageList

import decision_rule
import oracle


REPOSITORY = Path(__file__).resolve().parents[1]
FIGURES = REPOSITORY / "scripts/m3a_parity_spike/results/figures"
RUNNER = "adaf-detector-parity-runner"
FIXED_CANVAS = 1344
def figures_for(
    model_id: str, temporary: Path, *, include_empty_tile: bool
) -> tuple[tuple[Path, bool], ...]:
    in_class = oracle.IN_CLASS_FIGURE[model_id]
    if in_class:
        figures = ((FIGURES / in_class, False),)
    else:
        # The all-archaeology checkpoint must exercise every committed in-class figure. Selecting only
        # Ringfort leaves its one strong detection underpowered and would turn a convenient fixture into
        # a misleading verified claim.
        figures = tuple((figure, False) for figure in sorted(FIGURES.glob("*.jpg")))
    if include_empty_tile and model_id == "OD_ringfort":
        # An out-of-class archaeological figure is not necessarily empty: the oracle may produce
        # a real false positive, so it cannot prove the zero-survivor mask. This deterministic blank
        # is intentionally created for that contract and is read by ImageIO and Pillow alike.
        blank = temporary / "empty-tile.png"
        Image.fromarray(np.zeros((400, 400, 3), dtype=np.uint8)).save(blank)
        figures += ((blank, True),)
    return figures


def converted_weight_oracle(model: torch.nn.Module) -> None:
    """Make torchvision consume the exact fp16 values emitted into the Core ML weight blob.

    The checkpoint stores fp32 tensors, while the converter deliberately rounds every floating-point
    parameter and BatchNorm buffer to IEEE-754 binary16. Comparing the emitted graph to full-fp32
    torchvision would conflate that declared storage-format choice with graph semantics. This only
    changes the model's constants; transform, backbone, RPN, RoI heads and postprocess remain
    torchvision's implementations.
    """
    with torch.no_grad():
        for tensor in list(model.parameters()) + list(model.buffers()):
            if tensor.is_floating_point():
                tensor.copy_(tensor.to(torch.float16).to(torch.float32))


def source_oracle(built: oracle.Oracle, path: Path, canvas_path: Path) -> tuple[list[dict], int]:
    """Run torchvision itself with the emitted graph's fixed-canvas boundary.

    `GeneralizedRCNNTransform` remains the authority on source image sizing, normalisation and its
    initial stride padding. `path` is the runner's post-ImageIO PPM dump, so both sides start with
    precisely the source RGB bytes production used. The transform reconstruction provides the content
    rectangle and an independent byte-for-byte input audit. Torchvision's detector then consumes the
    exact dumped 8-bit fixed canvas after the emitted affine, rather than an almost-identical float
    reconstruction; no detector logic is duplicated here.
    """
    image = np.asarray(Image.open(path).convert("RGB"), dtype=np.float32) / 255.0
    tensor = oracle.resize_v2(image).float()
    original_size = tuple(tensor.shape[-2:])
    model = built.model
    converted_weight_oracle(model)
    with torch.no_grad():
        transformed, _ = model.transform([tensor], None)
        content_height, content_width = transformed.image_sizes[0]
        if content_width > FIXED_CANVAS or content_height > FIXED_CANVAS:
            raise RuntimeError(f"{path.name}: transformed content exceeds {FIXED_CANVAS}px canvas")
        mean = torch.tensor(model.transform.image_mean, dtype=transformed.tensors.dtype)[:, None, None]
        std = torch.tensor(model.transform.image_std, dtype=transformed.tensors.dtype)[:, None, None]
        content = transformed.tensors[0]
        # `NativeModelImageSizing.byte` is Swift `Float.rounded()` (ties away from zero), whereas
        # `torch.round` is bankers' rounding. Upscaling a 400px figure to 800px creates many exact
        # half-code values, so using Torch's default would feed a different 8-bit image to the oracle.
        quantised_pixels = torch.floor((content * std + mean) * 255 + 0.5).clamp(0, 255)
        quantised_content = (quantised_pixels / 255 - mean) / std
        # `NativeModelImageSizing.canvas` writes mean pixels before the graph's scale layer. The
        # image feature can store only whole bytes, so this is intentionally a tiny non-zero residual,
        # not torchvision's exact float zero padding.
        padding = ((torch.floor(mean * 255 + 0.5) / 255) - mean) / std
        fixed_tensor = padding.expand(3, FIXED_CANVAS, FIXED_CANVAS).clone()
        fixed_tensor[:, :content_height, :content_width] = quantised_content
        expected_bytes = torch.floor((fixed_tensor * std + mean) * 255 + 0.5).clamp(0, 255)
        observed_bytes = torch.from_numpy(
            np.asarray(Image.open(canvas_path).convert("RGB"), dtype=np.uint8).transpose(2, 0, 1).copy()
        )
        byte_mismatches = int(torch.count_nonzero(expected_bytes.to(torch.uint8) != observed_bytes).item())
        # The model received the dumped canvas, not the float tensor above. Use those exact bytes for
        # the prediction while retaining GeneralizedRCNNTransform above as the authority that proves
        # its sizing/normalisation boundary and defines the source-space inverse mapping.
        exact_tensor = (observed_bytes.float() / 255 - mean) / std
        fixed = ImageList(exact_tensor.unsqueeze(0), [(FIXED_CANVAS, FIXED_CANVAS)])
        features = model.backbone(fixed.tensors)
        proposals, _ = model.rpn(fixed, features, None)
        detections, _ = model.roi_heads(features, proposals, fixed.image_sizes, None)
        detections = oracle.wheel_get_predicted(detections)[0]

    # `sourceBox(fromCanvasBox:)` clips to the transformed content before inverse scaling. This is
    # its top-left-coordinate equivalent, applied to torchvision's real postprocessed output.
    scale_x = original_size[1] / content_width
    scale_y = original_size[0] / content_height
    result = []
    for box, score in zip(detections["boxes"].cpu().numpy(), detections["scores"].cpu().numpy()):
        x0, y0, x1, y1 = box
        x0, x1 = np.clip([x0, x1], 0, content_width)
        y0, y1 = np.clip([y0, y1], 0, content_height)
        if x1 > x0 and y1 > y0:
            result.append({"box": [float(x0 * scale_x), float(y0 * scale_y),
                                   float(x1 * scale_x), float(y1 * scale_y)], "score": float(score)})
    return result, byte_mismatches


def iou(left: list[float], right: list[float]) -> float:
    x0, y0 = max(left[0], right[0]), max(left[1], right[1])
    x1, y1 = min(left[2], right[2]), min(left[3], right[3])
    intersection = max(0.0, x1 - x0) * max(0.0, y1 - y0)
    left_area = max(0.0, left[2] - left[0]) * max(0.0, left[3] - left[1])
    right_area = max(0.0, right[2] - right[0]) * max(0.0, right[3] - right[1])
    union = left_area + right_area - intersection
    return intersection / union if union else 0.0


def compare(reference: list[dict], candidate: list[dict], *, requires_empty_tile: bool) -> dict:
    """One-to-one IoU matching exposes appeared/disappeared detections instead of hiding them."""
    if requires_empty_tile:
        verdict = decision_rule.judge_boolean(
            "converted detector empty tile", not reference and not candidate,
            f"torchvision={len(reference)} CoreML={len(candidate)} detections",
        )
        return {
            "verdict": {"outcome": verdict.outcome, "detail": verdict.detail},
            "matched": 0,
            "appeared": candidate,
            "disappeared": reference,
            "max_box_shift_px": None,
            "max_score_delta": None,
            "pairs": [],
        }
    available = set(range(len(candidate)))
    pairs: list[tuple[int, int, float]] = []
    for reference_index, detection in enumerate(reference):
        choices = [(iou(detection["box"], candidate[index]["box"]), index) for index in available]
        if not choices:
            continue
        overlap, candidate_index = max(choices)
        if overlap >= decision_rule.MATCH_IOU:
            available.remove(candidate_index)
            pairs.append((reference_index, candidate_index, overlap))
    shifts = []
    score_deltas = []
    for reference_index, candidate_index, overlap in pairs:
        ref = np.asarray(reference[reference_index]["box"])
        actual = np.asarray(candidate[candidate_index]["box"])
        shifts.append(float(np.abs(ref - actual).max()))
        score_deltas.append(abs(reference[reference_index]["score"] - candidate[candidate_index]["score"]))
    verdict = decision_rule.judge_detection_set(
        "converted detector detection set",
        matched=len(pairs),
        unmatched_reference=len(reference) - len(pairs),
        unmatched_candidate=len(candidate) - len(pairs),
        max_box_shift=max(shifts, default=None),
        max_score_delta=max(score_deltas, default=None),
    )
    return {
        "verdict": {"outcome": verdict.outcome, "detail": verdict.detail},
        "matched": len(pairs),
        "appeared": [candidate[index] for index in sorted(available)],
        "disappeared": [reference[index] for index in range(len(reference)) if index not in {pair[0] for pair in pairs}],
        "max_box_shift_px": max(shifts, default=None),
        "max_score_delta": max(score_deltas, default=None),
        "pairs": [{"reference": reference[index], "candidate": candidate[candidate_index], "iou": overlap}
                  for index, candidate_index, overlap in pairs],
    }


def model_coverage(rows: list[dict]) -> list[dict]:
    """Judge exercised-detection coverage per checkpoint, not per arbitrary source tile.

    The all-archaeology checkpoint intentionally runs all committed in-class figures. Two of those
    figures have one true detection each: they remain visible as UNDERPOWERED row-level results, but
    are not independent model variants. Pooling the disjoint fixture results is the relevant question
    for whether that checkpoint exercised the box and score budgets at least twice.
    """
    coverage = []
    for model_id in sorted({row["model"] for row in rows}):
        model_rows = [row for row in rows if row["model"] == model_id and not row["expects_empty_tile"]]
        matched = sum(row["comparison"]["matched"] for row in model_rows)
        disappeared = sum(len(row["comparison"]["disappeared"]) for row in model_rows)
        appeared = sum(len(row["comparison"]["appeared"]) for row in model_rows)
        shifts = [row["comparison"]["max_box_shift_px"] for row in model_rows]
        score_deltas = [row["comparison"]["max_score_delta"] for row in model_rows]
        verdict = decision_rule.judge_detection_set(
            "converted detector detection-set coverage",
            matched=matched,
            unmatched_reference=disappeared,
            unmatched_candidate=appeared,
            max_box_shift=max((shift for shift in shifts if shift is not None), default=None),
            max_score_delta=max((delta for delta in score_deltas if delta is not None), default=None),
        )
        coverage.append({
            "model": model_id,
            "figures": [row["figure"] for row in model_rows],
            "matched": matched,
            "appeared": appeared,
            "disappeared": disappeared,
            "max_box_shift_px": max((shift for shift in shifts if shift is not None), default=None),
            "max_score_delta": max((delta for delta in score_deltas if delta is not None), default=None),
            "verdict": {"outcome": verdict.outcome, "detail": verdict.detail},
        })
    return coverage


def run_candidate(checkpoint: Path, image: Path, temporary: Path) -> tuple[dict, Path, Path]:
    output = temporary / f"{checkpoint.stem}-{image.stem}.json"
    source_pixels = temporary / f"{checkpoint.stem}-{image.stem}.ppm"
    canvas_pixels = temporary / f"{checkpoint.stem}-{image.stem}-canvas.ppm"
    subprocess.run(
        ["swift", "run", RUNNER, "--source-rgb", str(source_pixels), "--canvas-rgb", str(canvas_pixels),
         str(checkpoint), str(output), str(image)],
        check=True, cwd=REPOSITORY,
    )
    payload = json.loads(output.read_text())
    if payload["parityProvenance"] != "structurally-matched":
        raise RuntimeError("the runner must not claim verified parity before this oracle comparison")
    return payload["images"][0]["detections"], source_pixels, canvas_pixels


def main(report: Path, model_ids: tuple[str, ...], *, include_empty_tile: bool) -> int:
    rows = []
    with tempfile.TemporaryDirectory(prefix="aiarcheology-adaf-parity-") as directory:
        temporary = Path(directory)
        for model_id in model_ids:
            checkpoint_provenance = oracle.gate_checkpoint(model_id)
            checkpoint = oracle.CHECKPOINT_DIR / checkpoint_provenance.file_name
            candidates = []
            for figure, requires_empty_tile in figures_for(model_id, temporary, include_empty_tile=include_empty_tile):
                if not figure.exists():
                    raise RuntimeError(f"missing committed parity figure: {figure}")
                # Run the compiled model first and retain the exact post-ImageIO RGB pixels it consumed.
                # Keeping Torch and a compiled Core ML detector resident together can exhaust a laptop.
                candidate, source_pixels, canvas_pixels = run_candidate(checkpoint, figure, temporary)
                candidates.append((figure, requires_empty_tile, candidate, source_pixels, canvas_pixels))
            built = oracle.build_oracle(model_id)
            provenance = built.provenance
            for figure, requires_empty_tile, candidate, source_pixels, canvas_pixels in candidates:
                reference, canvas_byte_mismatches = source_oracle(built, source_pixels, canvas_pixels)
                comparison = compare(reference, candidate, requires_empty_tile=requires_empty_tile)
                figure_name = (
                    str(figure.relative_to(REPOSITORY))
                    if figure.is_relative_to(REPOSITORY)
                    else "generated/empty-tile.png"
                )
                rows.append({
                    "model": model_id,
                    "figure": figure_name,
                    "expects_empty_tile": requires_empty_tile,
                    "checkpoint": {"md5": provenance.md5, "sha256": provenance.sha256},
                    "input_canvas_byte_mismatches": canvas_byte_mismatches,
                    "reference": reference,
                    "candidate": candidate,
                    "comparison": comparison,
                })
                print(f"{model_id} / {figure.name}: {comparison['verdict']['outcome']} — {comparison['verdict']['detail']}")
            del built
            gc.collect()

    coverage = model_coverage(rows)
    row_outcomes = [row["comparison"]["verdict"]["outcome"] for row in rows]
    passed = (
        not any(outcome in {"FAIL", "UNMEASURED"} for outcome in row_outcomes)
        and all(item["verdict"]["outcome"] == "PASS" for item in coverage)
    )
    payload = {
        "oracle": oracle.describe_environment(),
        "runner": {
            "swift": subprocess.run(["swift", "--version"], capture_output=True, text=True, check=False).stdout.strip(),
            "compute_units": "cpuOnly",
        },
        "source_weight_precision": "fp16-quantized checkpoint values widened to fp32 for Core ML and torchvision CPU execution",
        "fixed_canvas": FIXED_CANVAS,
        "rule": {
            "match_iou": decision_rule.MATCH_IOU,
            "max_box_shift_px": decision_rule.MAX_BOX_SHIFT_PX,
            "max_score_delta": decision_rule.MAX_SCORE_DELTA,
            "max_unmatched_detections": decision_rule.MAX_UNMATCHED_DETECTIONS,
        },
        "parity_provenance_entitled": "verified" if passed else "structurally-matched",
        "results": rows,
        "model_coverage": coverage,
    }
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps(payload, indent=2) + "\n")
    return 0 if passed else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument(
        "--model", choices=oracle.OD_MODEL_IDS, action="append", dest="models",
        help="checkpoint to certify; defaults to OD_ringfort, the full end-to-end fixture",
    )
    parser.add_argument(
        "--all-checkpoints", action="store_true",
        help="run the same diagnostic over every detector instead of the certified fixture",
    )
    parser.add_argument(
        "--empty-tile", action="store_true",
        help="also require a deterministic blank tile to have no Ringfort detections",
    )
    args = parser.parse_args()
    try:
        selected = tuple(oracle.OD_MODEL_IDS) if args.all_checkpoints else tuple(args.models or ("OD_ringfort",))
        raise SystemExit(main(args.report, selected, include_empty_tile=args.empty_tile))
    except (oracle.OracleError, OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"parity gate failed: {error}", file=sys.stderr)
        raise SystemExit(1)
