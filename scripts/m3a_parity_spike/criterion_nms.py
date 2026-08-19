"""Criterion 4: the suppression passes — all three of them.

The ticket names two: torchvision's postprocess (strict score > 0.05, per-class NMS at IoU 0.5,
top-100) and the vendored wheel's extra class-agnostic pass at IoU 0.2 in `get_predicted`. Those two
are the easy ones. Both are terminal, both operate on at most a few hundred boxes, per-class
semantics are vacuous for ADAF because `cls_score.weight` is `[2, 1024]`, and this repository already
emits a terminal suppression stage as a standalone NMS *model* in its detector pipeline
(`NativeModelDetectorPipeline.swift:93`) — so the 0.2 pass could even run outside the graph.

The hard one is not in the ticket: the **RPN's mid-graph NMS**. Its output is not a result, it is an
input — the proposals feed RoIAlign and everything downstream — so it must be a layer inside the
graph, with a fixed padded shape, and everything after it must cope with the padding. Two different
Core ML operators are therefore in play, and measuring one while reporting the other would be a
category error:

- the **NN layer** (`add_nms`), which has fixed padded outputs plus a `valid_count`, and takes boxes
  as `CENTER_SIZE_WIDTH_FIRST` where torchvision's are corners;
- the **standalone NMS model**, a Vision-facing pipeline stage with flexible outputs, which is what
  the repo emits today.

Static-shape feasibility is *executed* here rather than argued: the compiled layer is run with zero,
fewer-than-K, exactly-K and more-than-K surviving boxes, because "truncate a Python list" tells you
nothing about what the compiled operator does at those boundaries.
"""

from __future__ import annotations

import numpy as np
import torch
import torchvision

from probes import nms_layer_probe


def to_center_size(boxes_xyxy: np.ndarray) -> np.ndarray:
    """Corners to `CENTER_SIZE_WIDTH_FIRST` — the NN-layer NMS box convention."""
    x0, y0, x1, y1 = (boxes_xyxy[:, i] for i in range(4))
    return np.stack([(x0 + x1) / 2, (y0 + y1) / 2, x1 - x0, y1 - y0], axis=1).astype(np.float32)


def nn_layer_against_torchvision(boxes_xyxy: np.ndarray, scores: np.ndarray, *,
                                 iou_threshold: float, max_boxes: int,
                                 score_threshold: float = 0.0) -> dict:
    """Does the NN-layer NMS keep what torchvision keeps, in the same order?

    Order matters as much as membership: downstream the proposals are consumed positionally, so a
    permutation is not a cosmetic difference.
    """
    probe = nms_layer_probe(
        box_count=boxes_xyxy.shape[0], class_count=1, iou_threshold=iou_threshold,
        score_threshold=score_threshold, max_boxes=max_boxes, per_class_suppression=False,
    )
    out = probe.run(
        boxes=to_center_size(boxes_xyxy).reshape(1, -1, 4),
        scores=scores.reshape(1, -1, 1).astype(np.float32),
    )
    valid = int(np.asarray(out["valid_count"]).ravel()[0])
    kept = np.asarray(out["kept_indices"]).ravel()[:valid].astype(int)

    reference = torchvision.ops.nms(
        torch.from_numpy(boxes_xyxy), torch.from_numpy(scores.astype(np.float32)), iou_threshold
    ).numpy()
    truncated = reference[:max_boxes]

    return {
        "iou_threshold": iou_threshold,
        "max_boxes": max_boxes,
        "coreml_valid_count": valid,
        "torchvision_kept": int(len(reference)),
        "torchvision_kept_truncated": int(len(truncated)),
        "indices_identical": bool(len(kept) == len(truncated) and np.array_equal(kept, truncated)),
        "index_set_identical": bool(set(kept.tolist()) == set(truncated.tolist())),
        "padded_slots": int(max_boxes - valid),
    }


def static_shape_regimes(iou_threshold: float = 0.5, max_boxes: int = 8) -> list:
    """Run the compiled operator at the four boundaries a static graph must survive.

    Zero survivors is the one that tends to be special-cased in a format's documentation and forgotten
    in an implementation, so it is exercised rather than reasoned about — and it is the one that does
    not behave as written. With a score threshold above every input score, the layer reports
    `valid_count = 1` rather than 0: it emits a box nothing qualified for. `matches_expectation`
    records that per regime instead of letting a fixed output shape read as a pass, because a graph
    built on the assumption that an empty result is empty would surface a phantom detection on every
    tile containing nothing.
    """
    rng = np.random.default_rng(11)
    rows = []
    for label, count, score_threshold in (
        ("zero_survivors", 10, 1.1),       # threshold above every score: nothing can survive
        ("fewer_than_max", 4, 0.0),
        ("exactly_max", 8, 0.0),
        ("more_than_max", 40, 0.0),
    ):
        # Non-overlapping boxes, so suppression never reduces the count and the regime is the count.
        offsets = np.arange(count) * 100.0
        boxes = np.stack([offsets, offsets, offsets + 50, offsets + 50], axis=1).astype(np.float32)
        scores = rng.uniform(0.2, 1.0, count).astype(np.float32)
        try:
            probe = nms_layer_probe(
                box_count=count, class_count=1, iou_threshold=iou_threshold,
                score_threshold=score_threshold, max_boxes=max_boxes, per_class_suppression=False,
            )
            out = probe.run(
                boxes=to_center_size(boxes).reshape(1, -1, 4),
                scores=scores.reshape(1, -1, 1),
            )
            valid = int(np.asarray(out["valid_count"]).ravel()[0])
            kept_boxes = np.asarray(out["kept_boxes"]).reshape(max_boxes, 4)
            padded = kept_boxes[valid:]
            expected_survivors = 0 if score_threshold > 1.0 else min(count, max_boxes)
            rows.append({
                "regime": label,
                "input_boxes": count,
                "valid_count": valid,
                "expected_survivors": expected_survivors,
                "matches_expectation": valid == expected_survivors,
                "output_shape_fixed_at": max_boxes,
                "padding_slots": int(max_boxes - valid),
                "padding_is_all_zero": bool(padded.size == 0 or not padded.any()),
            })
        except Exception as exc:  # noqa: BLE001 - a failure at a boundary IS the finding
            rows.append({"regime": label, "error": f"{type(exc).__name__}: {str(exc)[:160]}"})
    return rows


def per_class_suppression_expressible(iou_threshold: float = 0.5) -> dict:
    """Is the per-class flag usable? Vacuous for ADAF, load-bearing for the umbrella's generality aim.

    ADAF's four detectors are single-class, so class-agnostic and per-class suppression coincide. But
    #654 asks M3 to build the graph parameterised and recognise structurally-matched checkpoints, and
    a multi-class one would need this flag. It is one boolean on the same layer, so measuring it now
    costs one model build and stops it becoming an unmeasured blocker later.
    """
    rng = np.random.default_rng(13)
    count = 12
    boxes = np.stack([
        rng.uniform(0, 40, count), rng.uniform(0, 40, count),
        rng.uniform(50, 90, count), rng.uniform(50, 90, count),
    ], axis=1).astype(np.float32)
    scores = rng.uniform(0.1, 1.0, (count, 3)).astype(np.float32)

    result = {}
    for per_class in (False, True):
        try:
            probe = nms_layer_probe(
                box_count=count, class_count=3, iou_threshold=iou_threshold,
                score_threshold=0.0, max_boxes=10, per_class_suppression=per_class,
            )
            out = probe.run(boxes=to_center_size(boxes).reshape(1, -1, 4),
                            scores=scores.reshape(1, count, 3))
            result[f"per_class_{per_class}"] = {
                "ok": True,
                "valid_count": int(np.asarray(out["valid_count"]).ravel()[0]),
            }
        except Exception as exc:  # noqa: BLE001
            result[f"per_class_{per_class}"] = {"ok": False, "error": str(exc)[:160]}
    return result


def non_composition(trials: int = 200, boxes_per_trial: int = 300, seed: int = 7) -> dict:
    """Measure what #654 asserts: the two terminal passes do not collapse into one.

    #654 carries a constructed counterexample. This makes it a measurement, on box fields at
    detector-like densities.

    Reported honestly: the two-pass pipeline includes torchvision's top-100 truncation *between* the
    passes, and that cap does much of the work. The claim being tested is that the emitted graph
    cannot replace the pair with a single NMS at 0.2 — which the numbers support — not the narrower
    claim that two NMS operations never compose.
    """
    rng = np.random.default_rng(seed)
    differing = 0
    two_pass_total = one_pass_total = 0
    worst_gap = 0

    for _ in range(trials):
        x0 = rng.uniform(0, 480, boxes_per_trial)
        y0 = rng.uniform(0, 480, boxes_per_trial)
        width = rng.uniform(10, 90, boxes_per_trial)
        height = rng.uniform(10, 90, boxes_per_trial)
        boxes = torch.tensor(np.stack([x0, y0, x0 + width, y0 + height], axis=1), dtype=torch.float32)
        scores = torch.tensor(rng.uniform(0.05, 1.0, boxes_per_trial), dtype=torch.float32)

        keep = torchvision.ops.nms(boxes, scores, 0.5)[:100]
        stage_one_boxes, stage_one_scores = boxes[keep], scores[keep]
        two_pass = stage_one_boxes[torchvision.ops.nms(stage_one_boxes, stage_one_scores, 0.2)]
        one_pass = boxes[torchvision.ops.nms(boxes, scores, 0.2)]

        two_pass_total += len(two_pass)
        one_pass_total += len(one_pass)
        if len(two_pass) != len(one_pass) or not torch.equal(two_pass, one_pass[: len(two_pass)]):
            differing += 1
            worst_gap = max(worst_gap, abs(len(two_pass) - len(one_pass)))

    return {
        "trials": trials,
        "trials_where_outputs_differ": differing,
        "mean_boxes_two_pass": two_pass_total / trials,
        "mean_boxes_single_pass_at_0_2": one_pass_total / trials,
        "largest_count_difference": worst_gap,
        "caveat": "the top-100 cap between the passes contributes much of the gap; the tested claim "
                  "is that a single NMS at 0.2 cannot replace the pair, not that NMS never composes",
    }
