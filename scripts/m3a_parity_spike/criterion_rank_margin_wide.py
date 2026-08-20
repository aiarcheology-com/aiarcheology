"""Is K = 723 the tail's real shape, or one detection in one picture?

`criterion_topk` measured the quantity a fixed top-K actually threatens — for each surviving
detection, the *position* of the proposal it came from in the RPN's score-ordered list — and the
answer it produced was 723. That number is now a module constant in `criterion_host_chunking` and the
ROI budget the whole memory argument is priced against, and it rests on this:

    OD_ringfort   2 detections, worst contributing position  11
    OD_barrow     3 detections, worst contributing position   4
    OD_enclosure  8 detections, worst contributing position 722
    OD_AO         1 detection,  worst contributing position   0

Fourteen detections. Thirteen of them came from the first sixteen proposals, and one — the eighth
detection of one checkpoint on one figure — came from 722. A budget set by a single observation
sixty times further out than every other observation is either a genuine heavy tail or an artefact,
and the two have opposite consequences: a heavy tail means no cut below 1000 is safe and the ROI
stage has to be sized for the worst case, while an artefact means K can drop by an order of magnitude
and the memory question changes shape.

Fourteen observations cannot tell those apart, so this file widens n instead of arguing about it. The
same measurement — `criterion_topk.rank_margin`, unchanged, on the same detector — is run over many
more inputs, built by tiling the spike's three figures at three offsets per axis and three rescales.
**The metric is not re-invented**: K stays "the smallest prefix of the RPN's ordered proposals that
still contains every proposal a surviving detection came from", exactly as criterion 2 defined it.
Only the input population grows.

Three things are worth saying plainly about that population:

- **Tiles overlap and rescales are interpolated.** Overlapping crops of three pictures are not 81
  independent scenes, and a rescaled figure is not a figure ADAF ever produced. For a *maximum*
  statistic that is mostly harmless — a correlated observation cannot lower the max, it just fails to
  raise it — but it does mean the distribution below describes this corpus and not the world.
- **A rank cannot exceed the proposals that exist.** `rpn_post_nms_top_n` is 1000, so 1000 is the
  ceiling for both the observed ranks and any K derived from them. A tail that reaches the ceiling is
  not a large K, it is the finding that no cut is safe.
- **Attribution is by score identity** (`criterion_topk.rank_margin`), so a score collision would
  mis-attribute a rank. Collisions are counted and reported rather than assumed away.
"""

from __future__ import annotations

import json
import time
from pathlib import Path

import numpy as np
from PIL import Image

import torch

import criterion_topk
import inputs
import oracle
from decision_rule import Verdict

RESULTS = Path(__file__).resolve().parent / "results"

# 256 with three offsets per axis, against 400-pixel figures. `inputs.PATCH_PX` is 512, which on a
# 400-pixel figure is one edge-replicated tile — no offsets, no widening, and a margin of invented
# pixels the detector can find boxes in. The point of this file is offsets, so the tile has to be
# smaller than the figure.
TILE_PX = 256
OFFSETS_PER_AXIS = 3

# Object-to-tile size is what reorders proposals, and it is the one property a pure offset sweep
# cannot vary. Both rescales are exact on a 400-pixel figure (300 and 600), so no rounding enters.
SCALES = (0.75, 1.0, 1.5)

# The K this is testing, from `criterion_topk` via `criterion_host_chunking.ROI_COUNT`.
M3A_K = 723

# Ten times M3a's 14 detections. Below this the re-estimate is reported as UNDERPOWERED, because a
# tail estimated from a handful of detections is exactly the failure mode this file exists to fix and
# reproducing it with a bigger harness would be worse than not running.
MIN_WIDENED_DETECTIONS = 140

# Buckets for the rank histogram: powers of two, because the question is which order of magnitude the
# contributing ranks live in, not their exact values.
BUCKET_EDGES = (0, 16, 64, 128, 256, 512, 1024)

# The two populations the same ranks are read at. 0.05 is torchvision's own `box_score_thresh`, which
# is what criterion 2 measured and therefore the number comparable to 723. 0.5 is ADAF's
# vectorisation cut and this app's default (`decision_rule.MAX_SCORE_DELTA`'s reasoning) — the
# detections a user ever sees. A K sized for detections nobody is shown is a K sized for nothing, so
# both are reported and neither is allowed to stand alone.
SCORE_CUTS = (0.05, 0.5)


def rank_margin_with_scores(model, image_chw: np.ndarray) -> dict:
    """`criterion_topk.rank_margin`, with each detection's score carried beside its rank.

    This is not a second metric. The positions come from the same construction against the same
    RPN-ordered proposal list, and `reproduce_native` runs `criterion_topk.rank_margin` on the same
    inputs and refuses to publish if the two disagree — so the definition of K stays in criterion 2
    and this function cannot quietly drift away from it.

    The score is carried because the widened set puts detections at ranks in the 900s, and a rank
    that far out means one thing for a detection ADAF would vectorise and something else entirely for
    one that never crosses its 0.5 cut. Without the score there is no way to tell those apart, and the
    difference is the whole recommendation.
    """
    image = torch.from_numpy(image_chw)
    with torch.no_grad():
        images, _ = model.transform([image])
        features = model.backbone(images.tensors)
        proposals, _ = model.rpn(images, features)
        image_shapes = images.image_sizes

        pooled = model.roi_heads.box_roi_pool(features, proposals, image_shapes)
        head = model.roi_heads.box_head(pooled)
        class_logits, box_regression = model.roi_heads.box_predictor(head)
        _, scores, _ = model.roi_heads.postprocess_detections(
            class_logits, box_regression, proposals, image_shapes
        )
        probabilities = torch.nn.functional.softmax(class_logits, -1)
        proposal_count = proposals[0].shape[0]

    ranks: list = []
    kept: list = []
    ambiguous = 0
    kept_scores = scores[0].numpy()
    foreground = probabilities[:, 1:].max(dim=1).values.numpy()

    for score in kept_scores:
        matches = np.nonzero(np.isclose(foreground, score, rtol=1e-5, atol=1e-7))[0]
        if matches.size:
            ranks.append(int(matches[0]))
            kept.append(float(score))
            ambiguous += int(matches.size > 1)

    order = np.argsort(ranks) if ranks else []
    return {
        "proposals": int(proposal_count),
        "detections": int(len(kept_scores)),
        "contributing_proposal_positions": [ranks[i] for i in order],
        "contributing_scores": [kept[i] for i in order],
        "worst_contributing_position": max(ranks) if ranks else None,
        "safe_k": (max(ranks) + 1) if ranks else None,
        "ambiguous_attributions": ambiguous,
    }


def in_class_models() -> dict:
    """Invert `oracle.IN_CLASS_FIGURE`: for each figure, the checkpoints it is in-class for.

    `OD_AO` maps to `None` — "all archaeology", in-class for every figure — so it appears against
    every tile. Running an out-of-class checkpoint would add tiles and no detections, and zero
    detections contribute nothing to a rank distribution.
    """
    mapping = {name: [] for name in inputs.FIGURE_NAMES}
    for model_id in oracle.OD_MODEL_IDS:
        figure = oracle.IN_CLASS_FIGURE.get(model_id)
        for name in (inputs.FIGURE_NAMES if figure is None else (figure,)):
            mapping[name].append(model_id)
    return mapping


def tiles_for(figure: np.ndarray, scale: float) -> list:
    """Rescale, then tile with a stride that lands exactly `OFFSETS_PER_AXIS` origins per axis.

    `inputs.tile` snaps its last origin back to the edge when the stride does not divide evenly,
    which is right for coverage and wrong here: the snapped tile can sit a handful of pixels from its
    neighbour and count as a second observation of the same crop. Choosing the stride so the origins
    come out evenly avoids manufacturing near-duplicates.
    """
    side = int(round(figure.shape[0] * scale)), int(round(figure.shape[1] * scale))
    if scale != 1.0:
        resized = np.asarray(Image.fromarray(figure).resize((side[1], side[0]), Image.BILINEAR))
    else:
        resized = figure
    stride = max(1, (min(resized.shape[0], resized.shape[1]) - TILE_PX) // (OFFSETS_PER_AXIS - 1))
    return [crop for crop in inputs.tile(resized, TILE_PX, stride) if not crop.edge_padded]


def histogram(ranks: list) -> dict:
    counts = {}
    for low, high in zip(BUCKET_EDGES, BUCKET_EDGES[1:]):
        counts[f"{low}-{high - 1}"] = int(sum(low <= r < high for r in ranks))
    return counts


def percentiles(ranks: list) -> dict:
    if not ranks:
        return {}
    array = np.asarray(ranks)
    return {f"p{q}": float(np.percentile(array, q)) for q in (50, 75, 90, 95, 99)}


def _stratum(observations: list, cut: float) -> dict:
    """The same rank distribution, restricted to detections scoring above `cut` (strictly).

    Strict `>` matches `roi_heads.py:711` and ADAF's own vectorisation cut, both of which are strict;
    a `>=` here would quietly admit a detection neither of them keeps.
    """
    ranks = sorted(rank for rank, score in observations if score > cut)
    if not ranks:
        return {"score_cut": cut, "detections": 0, "max_rank": None, "k": None,
                "detections_at_or_above_m3a_k": 0}
    return {
        "score_cut": cut,
        "detections": len(ranks),
        "max_rank": int(ranks[-1]),
        "k": int(ranks[-1]) + 1,
        "percentiles": percentiles(ranks),
        "histogram": histogram(ranks),
        "detections_at_or_above_m3a_k": int(sum(rank >= M3A_K for rank in ranks)),
    }


def reproduce_native(oracles: dict) -> dict:
    """Re-run criterion 2's own measurement on the whole figures, and check it two ways.

    A widened estimate is worth nothing if the harness no longer reproduces the narrow one, so this
    runs `criterion_topk.rank_margin` itself — not this file's variant — against
    `results/criterion_2_static_shapes.json`. The comparison is against the published file rather
    than against numbers copied into this module, so a rerun of the spike moves both sides together.

    It also checks the variant against the original on the same inputs. That is the drift guard: the
    moment `rank_margin_with_scores` disagrees about a position, every number in this file is
    describing a different metric from the one it claims to extend, and `evaluate` refuses to
    publish.
    """
    published = {}
    path = RESULTS / "criterion_2_static_shapes.json"
    if path.exists():
        record = json.loads(path.read_text())
        published = {model_id: record[model_id]["rank_margin"]
                     for model_id in oracle.OD_MODEL_IDS if model_id in record}

    rows = {}
    for model_id, built in oracles.items():
        name = oracle.IN_CLASS_FIGURE.get(model_id) or "ringfort.jpg"
        figure = np.asarray(Image.open(RESULTS / "figures" / name).convert("RGB"))
        chw = inputs.scaling_candidates(figure)["divide_255"].numpy().astype(np.float32)
        measured = criterion_topk.rank_margin(built.model, chw)
        variant = rank_margin_with_scores(built.model, chw)
        expected = published.get(model_id)
        rows[model_id] = {
            "figure": name,
            "measured": measured,
            "published": expected,
            "matches_published": bool(
                expected is not None
                and expected["detections"] == measured["detections"]
                and expected["worst_contributing_position"] == measured["worst_contributing_position"]
            ),
            "variant_agrees_with_criterion_topk": bool(
                variant["contributing_proposal_positions"]
                == measured["contributing_proposal_positions"]
            ),
        }
    return rows


def measure() -> dict:
    started = time.time()
    oracles = {model_id: oracle.build_oracle(model_id) for model_id in oracle.OD_MODEL_IDS}
    figures = {name: np.asarray(Image.open(RESULTS / "figures" / name).convert("RGB"))
               for name in inputs.FIGURE_NAMES}
    assignment = in_class_models()

    runs = []
    tile_count = 0
    for name, figure in figures.items():
        for scale in SCALES:
            for crop in tiles_for(figure, scale):
                tile_count += 1
                chw = inputs.scaling_candidates(crop.array)["divide_255"].numpy().astype(np.float32)
                for model_id in assignment[name]:
                    margin = rank_margin_with_scores(oracles[model_id].model, chw)
                    runs.append({
                        "figure": name, "scale": scale, "model_id": model_id,
                        "tile_y0": crop.y0, "tile_x0": crop.x0,
                        "proposals": margin["proposals"],
                        "detections": margin["detections"],
                        "contributing_proposal_positions": margin["contributing_proposal_positions"],
                        "contributing_scores": margin["contributing_scores"],
                        "worst_contributing_position": margin["worst_contributing_position"],
                        "ambiguous_attributions": margin["ambiguous_attributions"],
                    })

    observations = [(rank, score) for run in runs
                    for rank, score in zip(run["contributing_proposal_positions"],
                                           run["contributing_scores"])]
    ranks = [rank for rank, _ in observations]
    worst_per_run = [run["worst_contributing_position"] for run in runs
                     if run["worst_contributing_position"] is not None]
    ceiling = max((run["proposals"] for run in runs), default=0)

    report = {
        "corpus": {
            "figures": list(figures),
            "figure_pixels": {name: list(figure.shape[:2]) for name, figure in figures.items()},
            "tile_px": TILE_PX, "offsets_per_axis": OFFSETS_PER_AXIS, "scales": list(SCALES),
            "tiles": tile_count,
            "runs": len(runs),
            "models_per_figure": {name: sorted(ids) for name, ids in assignment.items()},
            "caveat": "overlapping crops of three figures, two of the three scales interpolated; a "
                      "maximum statistic tolerates correlated observations, a rate would not",
        },
        "metric": {
            "definition": "criterion_topk.rank_margin, unchanged: the position of the RPN proposal "
                          "that produced each surviving detection, in the RPN's own score order",
            "proposal_ceiling": ceiling,
            "ceiling_note": "rpn_post_nms_top_n bounds both the ranks and any K read off them; a "
                            "tail at the ceiling means no cut is safe, not that K is large",
        },
        "reproduction_at_native_scale": reproduce_native(oracles),
        "distribution": {
            "detections": len(ranks),
            "runs_with_detections": int(sum(1 for run in runs if run["detections"])),
            "max_rank": int(max(ranks)) if ranks else None,
            "mean_rank": float(np.mean(ranks)) if ranks else None,
            "percentiles": percentiles(ranks),
            "histogram": histogram(ranks),
            "worst_per_run_percentiles": percentiles(worst_per_run),
            "detections_at_or_above_m3a_k": int(sum(rank >= M3A_K for rank in ranks)),
            "detections_above_16": int(sum(rank >= 16 for rank in ranks)),
            "ambiguous_attributions": int(sum(run["ambiguous_attributions"] for run in runs)),
            "all_ranks_sorted": sorted(int(rank) for rank in ranks),
            "by_score_cut": {str(cut): _stratum(observations, cut) for cut in SCORE_CUTS},
        },
        "runs": runs,
        "seconds": time.time() - started,
    }
    report["estimate"] = _estimate(report)
    return report


def _estimate(report: dict) -> dict:
    """Apply criterion 2's own rule to the widened set, and say what it means about 722.

    The rule is not re-derived: `criterion_topk.rank_margin` reports `safe_k = max(rank) + 1`, and
    `run_spike` takes the maximum of that across checkpoints. Applied to the widened set it is the
    same arithmetic over more observations, which is the only thing that changed.
    """
    distribution = report["distribution"]
    ranks = distribution["all_ranks_sorted"]
    if not ranks:
        return {"k": None, "reasoning": "no detections were observed; nothing to estimate from"}

    widened_k = max(ranks) + 1
    ceiling = report["metric"]["proposal_ceiling"]
    above = distribution["detections_at_or_above_m3a_k"]
    p99 = distribution["percentiles"]["p99"]
    second = sorted(ranks)[-2] if len(ranks) > 1 else None

    if widened_k > M3A_K:
        verdict = (f"722 was not the tail's edge: {above} detection(s) in the widened set came from "
                   f"rank {M3A_K} or beyond, so K = {M3A_K} would drop them.")
    elif above:
        verdict = f"{above} detection(s) sit exactly at rank {M3A_K} or beyond."
    else:
        verdict = (f"no detection in the widened set came from rank {M3A_K} or beyond, so 722 "
                   f"remains the single most extreme observation on record.")

    vectorised = distribution["by_score_cut"][str(max(SCORE_CUTS))]
    if vectorised["detections"]:
        stratum = (f" Restricted to the {vectorised['detections']} detections above the "
                   f"{vectorised['score_cut']} vectorisation cut — the ones a user is ever shown — "
                   f"the max rank is {vectorised['max_rank']} and the rule gives K = "
                   f"{vectorised['k']}, with {vectorised['detections_at_or_above_m3a_k']} of them at "
                   f"or beyond {M3A_K}.")
    else:
        stratum = (f" No detection cleared the {vectorised['score_cut']} vectorisation cut, so the "
                   f"widened set says nothing about the K a user-visible detection needs.")

    return {
        "k": int(widened_k),
        "rule": "max(contributing proposal position) + 1, as criterion_topk.rank_margin defines safe_k",
        "m3a_k": M3A_K,
        "proposal_ceiling": ceiling,
        "second_largest_rank": int(second) if second is not None else None,
        "p99_rank": p99,
        "k_above_vectorisation_cut": vectorised["k"],
        "reasoning": (
            f"{distribution['detections']} detections over {report['corpus']['runs']} tile x model "
            f"runs. The 99th percentile of contributing ranks is {p99:.0f} and the second largest is "
            f"{second}, against a maximum of {max(ranks)}. {verdict} Applying criterion 2's own rule "
            f"to the widened set gives K = {widened_k}"
            + (f", which is within {ceiling - widened_k} of the {ceiling}-proposal ceiling — the "
               f"honest reading is that no cut meaningfully below rpn_post_nms_top_n is safe on this "
               f"corpus."
               if widened_k >= ceiling - 0.05 * ceiling else
               f", against {M3A_K} from 14 detections.")
            + stratum
        ),
    }


def evaluate(report: dict) -> Verdict:
    """Does M3a's K survive the widened set? PASS means 723 still covers every observed detection."""
    distribution = report["distribution"]
    estimate = report["estimate"]
    if not distribution["detections"]:
        return Verdict("K re-estimate", "UNMEASURED", "the widened corpus produced no detections")

    reproduced = report["reproduction_at_native_scale"]
    unmatched = [model_id for model_id, row in reproduced.items() if not row["matches_published"]]
    if unmatched:
        return Verdict("K re-estimate", "UNMEASURED",
                       f"the harness no longer reproduces criterion 2 at native scale for "
                       f"{unmatched}; a widened number from it would not be comparable")
    drifted = [model_id for model_id, row in reproduced.items()
               if not row["variant_agrees_with_criterion_topk"]]
    if drifted:
        return Verdict("K re-estimate", "UNMEASURED",
                       f"rank_margin_with_scores disagrees with criterion_topk.rank_margin on "
                       f"{drifted}; the widened numbers would describe a different metric")

    if distribution["detections"] < MIN_WIDENED_DETECTIONS:
        return Verdict("K re-estimate", "UNDERPOWERED",
                       f"{distribution['detections']} detections is below the {MIN_WIDENED_DETECTIONS} "
                       f"this file set as ten times M3a's 14; K = {estimate['k']} from them is the "
                       f"same kind of estimate it was meant to replace")

    if estimate["k"] <= M3A_K:
        return Verdict("K re-estimate", "PASS",
                       f"{distribution['detections']} detections, max rank "
                       f"{distribution['max_rank']}; K = {estimate['k']} <= M3a's {M3A_K}")
    return Verdict("K re-estimate", "FAIL",
                   f"{distribution['detections']} detections, max rank {distribution['max_rank']}: "
                   f"K = {estimate['k']} exceeds M3a's {M3A_K}, and "
                   f"{distribution['detections_at_or_above_m3a_k']} detection(s) would be dropped by it")


def render(report: dict) -> str:
    distribution = report["distribution"]
    lines = [
        f"corpus: {report['corpus']['tiles']} tiles ({TILE_PX}px, {OFFSETS_PER_AXIS} offsets/axis, "
        f"scales {SCALES}) x in-class checkpoints = {report['corpus']['runs']} runs "
        f"in {report['seconds']:.0f}s",
        "",
        "reproduction at native scale (whole figure, as criterion 2 ran it):",
    ]
    for model_id, row in report["reproduction_at_native_scale"].items():
        published = row["published"]
        lines.append(
            f"  {model_id:<14}{row['measured']['detections']:>3} detections, worst position "
            f"{str(row['measured']['worst_contributing_position']):>4}"
            + (f"  (published {published['detections']}/"
               f"{published['worst_contributing_position']}, "
               f"{'matches' if row['matches_published'] else 'DIFFERS'})" if published else
               "  (no published record to compare against)")
        )
    lines += [
        "",
        f"contributing proposal ranks: n = {distribution['detections']} detections over "
        f"{distribution['runs_with_detections']} productive runs",
        "  " + "  ".join(f"{label}: {count}" for label, count in distribution["histogram"].items()),
        f"  percentiles " + ", ".join(f"{k}={v:.0f}" for k, v in distribution["percentiles"].items())
        + f", max={distribution['max_rank']}",
        f"  {distribution['detections_above_16']} of {distribution['detections']} came from rank 16 "
        f"or beyond; {distribution['detections_at_or_above_m3a_k']} from rank {M3A_K} or beyond",
        f"  ambiguous attributions: {distribution['ambiguous_attributions']}",
        "",
        "the same ranks, read at each score cut:",
    ]
    for label, stratum in distribution["by_score_cut"].items():
        lines.append(
            f"  score > {label:<5} n = {stratum['detections']:>4}, max rank "
            f"{str(stratum['max_rank']):>5}, K = {str(stratum['k']):>5}, "
            f"{stratum['detections_at_or_above_m3a_k']} at or beyond {M3A_K}"
        )
    lines += [
        "",
        f"K = {report['estimate']['k']} ({report['estimate']['rule']})",
        f"  {report['estimate']['reasoning']}",
    ]
    return "\n".join(lines)


if __name__ == "__main__":
    measured = measure()
    verdict = evaluate(measured)
    measured["verdict"] = {"outcome": verdict.outcome, "detail": verdict.detail}
    print(render(measured))
    print(verdict)
    RESULTS.mkdir(parents=True, exist_ok=True)
    (RESULTS / "criterion_rank_margin_wide.json").write_text(json.dumps(measured, indent=2))
    print("wrote results/criterion_rank_margin_wide.json")
