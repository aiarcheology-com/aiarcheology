"""Run the whole M3a spike and write the numbers the go/no-go is read off.

Usage, from the repository root:

    PYTHONPATH=scripts/m3a_parity_spike .venv-m3a/bin/python scripts/m3a_parity_spike/run_spike.py

Everything it writes lands in `results/`, one JSON per criterion plus `environment.json`. Nothing
here decides anything: the thresholds live in `decision_rule.py` and are applied mechanically, so a
reader can disagree with a threshold without having to re-derive a number.

The empirical criteria run over all four `OD_*` checkpoints. Their tensor tables are identical in
name, shape and dtype, but their weights are not — and weights are exactly what set feature
distributions, proposal ranks and suppression incidence, so one checkpoint cannot certify four
detectors.
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

import numpy as np
import torch
from PIL import Image

import criterion_levels
import criterion_nms
import criterion_roi_align
import criterion_topk
import criterion_transform
import decision_rule
import inputs
import oracle
import trunk

RESULTS = Path(__file__).resolve().parent / "results"
TILE_PX = 512


def _write(name: str, payload) -> None:
    RESULTS.mkdir(parents=True, exist_ok=True)
    (RESULTS / f"{name}.json").write_text(json.dumps(payload, indent=2, default=str))
    print(f"    wrote results/{name}.json")


def _figure_for(model_id: str) -> Path:
    name = oracle.IN_CLASS_FIGURE.get(model_id) or "ringfort.jpg"
    return RESULTS / "figures" / name


def main() -> int:
    started = time.time()
    verdicts: list[decision_rule.Verdict] = []

    print("S1  provenance and the density gate")
    figures = inputs.fetch_figures(RESULTS / "figures")
    environment = oracle.describe_environment()
    environment["checkpoints"] = {}
    for model_id in oracle.OD_MODEL_IDS:
        provenance = oracle.gate_checkpoint(model_id)
        environment["checkpoints"][model_id] = {
            "md5": provenance.md5, "sha256": provenance.sha256,
            "logical_bytes": provenance.logical_bytes, "dense": provenance.dense,
        }
        print(f"    {model_id}: dense, md5 verified")
    environment["figures"] = {name: {"sha256": meta["sha256"], "pixels": meta["pixels"]}
                              for name, meta in figures.items()}

    print("S2  oracle construction")
    oracles = {model_id: oracle.build_oracle(model_id) for model_id in oracle.OD_MODEL_IDS}
    reference = oracles["OD_ringfort"]
    environment["constants"] = reference.constants
    environment["anchor_geometry"] = oracle.anchor_geometry(reference.model, TILE_PX)
    _write("environment", environment)

    print("S3  corpus: contamination, scaling, quantisation")
    # The contamination screen has to run here rather than in a note somewhere: these are README
    # figures, and one carrying its own predictions painted on would poison every number below.
    contamination = {
        name: inputs.inspect_for_contamination(meta["path"]) for name, meta in figures.items()
    }
    for name, report in contamination.items():
        print(f"    {name}: likely_annotated={report['likely_annotated']}")
    _write("corpus_contamination", contamination)

    # Quantisation, priced on paired renderings of ONE array so the difference is bit depth and
    # nothing else. A synthetic float raster against a real JPEG would vary content, relief,
    # rendering and bit depth at once.
    synthetic = inputs.synthetic_slrm(TILE_PX, 0)
    float_input, quantised_input = inputs.paired_quantization(synthetic)
    quantisation = {"max_abs_difference": float(np.abs(float_input - quantised_input).max()),
                    "note": "prices bit depth only; JPEG's other losses are not reproduced here"}
    for model_id, built in oracles.items():
        rows = {}
        for label, array in (("float", float_input), ("8bit_roundtrip", quantised_input)):
            with torch.no_grad():
                out = built.model([oracle.resize_v2(array).float()])[0]
            got = out["scores"].numpy()
            rows[label] = {"detections_above_0_05": int((got > 0.05).sum()),
                           "max_score": float(got.max()) if got.size else 0.0}
        quantisation[model_id] = rows
    _write("criterion_quantisation", quantisation)

    print("S3b input domain: which scaling reproduces the trained domain")
    scaling = {}
    for model_id, built in oracles.items():
        figure = _figure_for(model_id)
        if not figure.exists():
            continue
        image = np.asarray(Image.open(figure).convert("RGB"))
        rows = {}
        for name, tensor in inputs.scaling_candidates(image).items():
            with torch.no_grad():
                out = built.model([tensor.float()])[0]
            scores = out["scores"].numpy()
            rows[name] = {
                "detections_above_0_05": int((scores > 0.05).sum()),
                "detections_above_0_5": int((scores > 0.5).sum()),
                "max_score": float(scores.max()) if scores.size else 0.0,
            }
        scaling[model_id] = {"figure": figure.name, "candidates": rows}
        best = max(rows.items(), key=lambda item: item[1]["max_score"])
        print(f"    {model_id} on {figure.name}: best '{best[0]}' max {best[1]['max_score']:.4f}")
    _write("criterion_input_domain", scaling)

    print("S4  criterion 0: the transform")
    image = np.asarray(Image.open(_figure_for("OD_ringfort")).convert("RGB"))
    chw = inputs.scaling_candidates(image)["divide_255"].numpy().astype(np.float32)
    transform_report = {
        "resize": criterion_transform.compare_resize(chw, 800),
        "pinned_min_size": criterion_transform.transform_is_identity(reference.model, TILE_PX),
        "detection_cost_of_pinning": criterion_transform.detection_cost_of_pinning(
            reference.model, chw, TILE_PX
        ),
    }
    _write("criterion_0_transform", transform_report)

    print("S5  criterion 1: RoIAlign")
    calibration = criterion_roi_align.calibrate(spatial_scale=1.0)
    best_key, best_offset = criterion_roi_align.best_grid_configuration(calibration)
    calibration["best_grid_configuration"] = {
        "configuration": best_key, "max_grid_offset_px": best_offset,
        "caveat": "the grid metric is blind to sampling_ratio, so it cannot choose the construction",
    }
    # Prove the calibration can see a coordinate-layout error, rather than asserting it was checked.
    calibration["axis_swap_sensitivity"] = criterion_roi_align.axis_swap_sensitivity()
    print(f"    axis-swap sensitivity: honest "
          f"{calibration['axis_swap_sensitivity']['honest_packing_max_grid_offset_px']:.2e} px vs "
          f"swapped {calibration['axis_swap_sensitivity']['swapped_packing_max_grid_offset_px']:.2f} px")

    # The value test the grid metric cannot do: real FPN features, real proposals.
    with torch.no_grad():
        ref_images, _ = reference.model.transform([torch.from_numpy(chw)])
        ref_features = reference.model.backbone(ref_images.tensors)
        ref_proposals, _ = reference.model.rpn(ref_images, ref_features)
    level0 = ref_features["0"].numpy()
    level0_scale = level0.shape[-1] / ref_images.tensors.shape[-1]
    calibration["construction_on_real_features"] = criterion_roi_align.choose_construction(
        level0, ref_proposals[0].numpy()[:64], level0_scale,
    )
    chosen = calibration["construction_on_real_features"]
    print(f"    construction on real features: {chosen['chosen']} "
          f"(relative mean |delta| {chosen['chosen_relative_mean_abs_diff']:.4f})")
    _write("criterion_1_roi_align", calibration)

    verdicts.append(decision_rule.judge_boolean(
        "criterion 1 sampling grid",
        best_offset <= 1e-3,
        f"{best_key} reproduces torchvision's grid to {best_offset:.2e} feature px",
    ))
    verdicts.append(decision_rule.judge_boolean(
        "criterion 1 harness sees an axis swap",
        calibration["axis_swap_sensitivity"]["harness_can_detect_a_swap"],
        f"swapped packing moves the grid "
        f"{calibration['axis_swap_sensitivity']['swapped_packing_max_grid_offset_px']:.2f} px",
    ))
    verdicts.append(decision_rule.judge_boolean(
        "criterion 1 construction",
        chosen["chosen"] == "crop14_pool2",
        f"crop-at-2x + 2x2 average pool wins on real features "
        f"({chosen['constructions']['crop14_pool2']['relative_mean_abs_diff']:.4f} relative) against "
        f"a bare 7x7 crop ({chosen['constructions']['direct_7x7']['relative_mean_abs_diff']:.4f})",
    ))

    print("S6  criteria 2 and 3: static shapes, rank margin, level assignment")
    topk = {"memory": criterion_topk.memory_table()}
    for model_id, built in oracles.items():
        figure = _figure_for(model_id)
        if not figure.exists():
            continue
        pixels = np.asarray(Image.open(figure).convert("RGB"))
        model_chw = inputs.scaling_candidates(pixels)["divide_255"].numpy().astype(np.float32)
        topk[model_id] = {
            "proposals": criterion_topk.proposal_statistics(built.model, model_chw),
            "rank_margin": criterion_topk.rank_margin(built.model, model_chw),
            "padding_false_positives": criterion_topk.padding_false_positives(
                built.model, model_chw, pad_to=1200
            ),
            "pre_nms_sweep": criterion_topk.sweep_cut(built.model, model_chw, which="pre_nms"),
            "post_nms_sweep": criterion_topk.sweep_cut(built.model, model_chw, which="post_nms"),
        }
        margin = topk[model_id]["rank_margin"]
        print(f"    {model_id}: {margin['detections']} detections, worst contributing proposal "
              f"position {margin['worst_contributing_position']} of {margin['proposals']} "
              f"(safe K {margin['safe_k']})")
        invented = [row for row in topk[model_id]["pre_nms_sweep"] if row["invented_detections"]]
        if invented:
            print(f"      invented detections at K={[row['value'] for row in invented]}")
    _write("criterion_2_static_shapes", topk)

    # The smallest K that keeps every contributing proposal across every model — the number
    # condition 2 rests on, computed rather than eyeballed from a table.
    safe_ks = [topk[m]["rank_margin"]["safe_k"] for m in oracles if m in topk
               and topk[m]["rank_margin"]["safe_k"] is not None]
    required_k = max(safe_ks) if safe_ks else None
    topk["required_k_across_models"] = required_k
    print(f"    smallest K containing every contributing proposal: {required_k}")
    _write("criterion_2_static_shapes", topk)

    print("S6b criterion 3: level assignment")
    levels = {
        "real_proposals": criterion_levels.real_proposals(reference.model, chw),
        "adversarial": criterion_levels.adversarial_set(),
        "fp16_margin": criterion_levels.fp16_margin(reference.model, chw),
    }
    _write("criterion_3_level_assignment", levels)
    print(f"    real proposals: {levels['real_proposals']['mismatches']} mismatches of "
          f"{levels['real_proposals']['count']}; adversarial: "
          f"{levels['adversarial']['mismatches']} of {levels['adversarial']['count']}; "
          f"fp16 flip rate {levels['fp16_margin']['fp16_level_flip_rate']:.5f}")
    verdicts.append(decision_rule.judge_boolean(
        "criterion 3 level assignment (real proposals)",
        levels["real_proposals"]["agrees"],
        f"{levels['real_proposals']['count']} real proposal areas, "
        f"{levels['real_proposals']['mismatches']} mismatches",
    ))
    verdicts.append(decision_rule.judge_boolean(
        "criterion 3 level assignment (adversarial)",
        levels["adversarial"]["agrees"],
        f"{levels['adversarial']['count']} boundary and degenerate areas, "
        f"{levels['adversarial']['mismatches']} mismatches",
    ))

    print("S7  criterion 4: the three suppression passes")
    rng = np.random.default_rng(5)
    count = 40
    x0, y0 = rng.uniform(0, 300, count), rng.uniform(0, 300, count)
    boxes = np.stack([x0, y0, x0 + rng.uniform(20, 80, count), y0 + rng.uniform(20, 80, count)], 1)
    nms_report = {
        "mid_graph_vs_torchvision": criterion_nms.nn_layer_against_torchvision(
            boxes.astype(np.float32), rng.uniform(0.1, 1.0, count).astype(np.float32),
            iou_threshold=0.7, max_boxes=20,
        ),
        "static_shape_regimes": criterion_nms.static_shape_regimes(),
        "per_class_suppression": criterion_nms.per_class_suppression_expressible(),
        "non_composition": criterion_nms.non_composition(),
    }
    _write("criterion_4_nms", nms_report)
    verdicts.append(decision_rule.judge_boolean(
        "criterion 4 mid-graph NMS",
        nms_report["mid_graph_vs_torchvision"]["indices_identical"],
        "NN-layer NMS returns torchvision's kept indices in torchvision's order",
    ))

    print("S8  elementwise stages, with a real Core ML side")
    elementwise = {
        "backbone_fpn": trunk.elementwise_trunk_report(reference.model, chw),
        "rpn_head": trunk.elementwise_rpn_head_report(reference.model, chw),
    }
    _write("stagewise_elementwise", elementwise)
    worst_trunk = max(v["max_abs_diff"] for v in elementwise["backbone_fpn"]["levels"].values())
    verdicts.append(decision_rule.judge_elementwise("backbone+FPN elementwise", worst_trunk))
    worst_rpn = max(
        v["max_abs_diff"]
        for group in ("objectness", "deltas")
        for v in elementwise["rpn_head"][group].values()
    )
    verdicts.append(decision_rule.judge_elementwise("RPN head elementwise", worst_rpn))

    print("S9  composition by substitution, float32 and float16")
    composition = {}
    for model_id, built in oracles.items():
        figure = _figure_for(model_id)
        if not figure.exists():
            continue
        pixels = np.asarray(Image.open(figure).convert("RGB"))
        model_chw = inputs.scaling_candidates(pixels)["divide_255"].numpy().astype(np.float32)
        base = trunk.detections_with_substitutions(built.model, model_chw)
        rows = {}
        for label, kwargs in (("coreml_pooling", {"substitute_pooling": True}),
                              ("coreml_pooling_fp16", {"substitute_pooling": True, "half": True}),
                              ("torch_fp16", {"half": True})):
            candidate = trunk.detections_with_substitutions(built.model, model_chw, **kwargs)
            match = criterion_transform._match_detections(
                base["boxes"], base["scores"], candidate["boxes"], candidate["scores"],
                iou_threshold=decision_rule.MATCH_IOU,
            )
            rows[label] = {"detections": int(len(candidate["boxes"])), **match}
            verdicts.append(decision_rule.judge_detection_set(
                f"composition {label} [{model_id}]",
                matched=match["matched"], unmatched_reference=match["unmatched_a"],
                unmatched_candidate=match["unmatched_b"],
                max_box_shift=match["max_box_shift_px"], max_score_delta=match["max_score_delta"],
            ))
        composition[model_id] = {"baseline_detections": int(len(base["boxes"])), "runs": rows}
        print(f"    {model_id}: baseline {len(base['boxes'])} detections")
    _write("composition", composition)

    print("S10 cost")
    parameters = sum(t.numel() for t in reference.model.state_dict().values())
    cost = {
        "parameters": int(parameters),
        "weight_mib_fp32": parameters * 4 / 2 ** 20,
        "weight_mib_fp16": parameters * 2 / 2 ** 20,
        "roi_activation_mib": criterion_topk.memory_table(),
        "note": "peak activation is dominated by the 800x800 backbone pass and the ROI stage, which "
                "a static graph must run at every FPN level because level assignment is data "
                "dependent",
    }
    _write("cost", cost)

    print("\nverdicts")
    for verdict in verdicts:
        print(f"  {verdict}")
    _write("verdicts", [{"criterion": v.criterion, "outcome": v.outcome, "detail": v.detail}
                        for v in verdicts])

    failures = [v for v in verdicts if v.outcome == "FAIL"]
    print(f"\n{len(verdicts)} verdicts, {len(failures)} FAIL, "
          f"{sum(1 for v in verdicts if v.outcome == 'UNDERPOWERED')} UNDERPOWERED "
          f"({time.time() - started:.0f}s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
