"""If the graph will not give the memory back, will the *host* — one small model called N times?

`criterion_chunking` closed the in-graph door: slicing the ROI stage into fixed-size batches inside a
single Core ML graph saved nothing, because Core ML keeps every layer's output alive for the whole
prediction, so the chunks' crops accumulate exactly as the unchunked crop did. The lever that
survives is the one Core ML cannot defeat by scheduling: **host-side** chunking. Build one small
model that takes B ROIs, run it N times from a host loop, and let the *process* boundary between
predictions do the freeing the graph refused to do.

That only helps if the chunk unit is compact at its boundary, which fixes the design:

- **The chunk runs through the ROI head to boxes and scores** (owner's ruling). A chunk that stopped
  at pooled 7x7 features would hand the host 36 MiB per 723 ROIs to hold across the loop, and the
  host would be re-accumulating what the graph used to. Ending at `[B, 5]` scores and `[B, 20]` boxes
  makes the retained-across-chunks state ~100 bytes per ROI, so nothing pooled outlives its chunk.
- **Four FPN levels, not one.** `criterion_chunking` measured one level and projected the other three
  by arithmetic, which is the projection this probe exists to stop trusting. Every ROI is cropped at
  every level (criterion 2: per-ROI level assignment is data dependent, and a data-dependent gather
  has no fixed output shape), and the four 7x7x256 crops are combined by a per-ROI **one-hot level
  weight supplied as a fourth input** — an elementwise multiply and add, never a gather. The level
  arithmetic itself runs on the host, where data dependence is free.
- **The FC1 weight is 49 MiB and stays in the model.** 12544x1024 float32 is the head's real size. A
  probe that shrank it would measure a load floor no shipping model could reproduce.

**The protocol is the measurement.** Building a model and predicting with it in the same process
conflates the builder's footprint with the model's, and `ru_maxrss` is a high-water mark that never
falls, so the build would be charged to the run forever. Every model here is therefore built and
compiled **once**, out of band, into a `.mlmodelc` cached by config hash; the measured process is a
fresh subprocess that only ever loads that `.mlmodelc` and predicts. Two measured modes per config:

- **load-only** — load, never predict. The floor: what having this model resident costs.
- **full-run** — load, allocate the four feature maps, run all N predictions, keep only the compact
  outputs. The number the decision rule is about.

Both are reported above a baseline sampled at the top of the measured process. That baseline includes
torch, which `import coremltools` drags in whether or not anything here wants it; measuring above
baseline is what makes that irrelevant rather than something to apologise for.

The monolithic reference (B=723, N=1) is measured **under this same protocol**. The earlier
in-process smoke run is not a comparison partner for anything here — its monolithic number was paid
for by a builder that this protocol removes, and quoting the two side by side would credit host-side
chunking with a saving the protocol change produced.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import resource
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import numpy as np

import coremltools as ct
from coremltools.models import CompiledMLModel, datatypes
from coremltools.models.neural_network import NeuralNetworkBuilder
from coremltools.models.utils import compile_model

from decision_rule import Verdict
from probes import CPU_ONLY

MEBIBYTE = 2 ** 20
RESULTS = Path(__file__).resolve().parent / "results"

# The FPN levels of an 800x800 input, as (stride, side). P2..P5 at strides 4/8/16/32.
LEVELS = ((4, 200), (8, 100), (16, 50), (32, 25))
CHANNELS = 256
OUTPUT_SIZE = 7
HIDDEN = 1024
CLASS_COUNT = 5           # four ADAF classes plus background
BOX_COORDS = CLASS_COUNT * 4
IMAGE_SIDE = 800

# The K this run is about. criterion_topk's 723 rested on 14 detections; criterion_rank_margin_wide
# widened n to 912 and watched the contributing-rank tail reach 988 against the 1000-proposal
# ceiling, so the frozen budget is the ceiling itself — a fitted 989 would be a magic constant one
# tile away from invalidation. A module constant rather than a flag nobody would remember to set
# consistently.
ROI_COUNT = 1000

# Weights are random and this seed pins them, so every configuration runs the *same* model with only
# its batch dimension changed. Comparing peaks across models that differed in their weights would be
# comparing two things at once.
WEIGHT_SEED = 20260820
INPUT_SEED = 7

# --------------------------------------------------------------------------------------------
# Decision rule, preregistered
# --------------------------------------------------------------------------------------------

# Set in the S0 plan before this probe ran; this file records it rather than deriving it. For scale:
# `criterion_chunking` measured the in-graph stage at 443 MiB above baseline for a *single* level and
# projected 697 MiB for four, so the budget is a demand that host-side chunking beat the in-graph
# stage by more than a factor of two, not a rounding of whatever came out.
MAX_FULL_RUN_PEAK_MIB = 300.0

# Latency is allowed to get worse, because a stage that fits is worth paying for and one that does
# not is worth nothing. 3x is the point past which N invocations stop being a cost and start being a
# different product decision.
MAX_LATENCY_MULTIPLE = 3.0


def _peak_mib() -> float:
    peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    # macOS reports ru_maxrss in bytes; Linux in kibibytes. Detected by magnitude rather than
    # platform string, since a wrong unit would silently rescale the whole finding.
    return peak / MEBIBYTE if peak > 10 ** 7 else peak / 1024


# --------------------------------------------------------------------------------------------
# The chunk unit
# --------------------------------------------------------------------------------------------


def build_chunk_model(batch: int, seed: int = WEIGHT_SEED):
    """One host-invocable chunk: B ROIs plus all four FPN levels in, B boxes and B scores out.

    ROIs arrive **once**, in 800x800 image coordinates, and each level's `CropResize` carries
    `spatial_scale = 1/stride` to express them in that level's own frame — which is how torchvision's
    pooler does it (`trunk.py:212`) and avoids four near-identical ROI inputs that could drift apart.

    The level weights are `[B, 1, 4, 1, 1]`: the `[B, 4]` the design calls for, laid out rank-5 so a
    per-level slice is `[B, 1, 1, 1, 1]` and broadcasts against the `[B, 1, 256, 7, 7]` pooled tensor
    with no reshape. One-hot rows select a level; the multiply-and-add is a fixed-shape computation on
    every level, which is the whole point — a gather on a host-computed index would reintroduce the
    dynamic shape criterion 2 ruled out.
    """
    inputs = [
        ("rois", datatypes.Array(batch, 1, 4, 1, 1)),
        ("level_weights", datatypes.Array(batch, 1, len(LEVELS), 1, 1)),
    ]
    for index, (_, side) in enumerate(LEVELS):
        inputs.append((f"features_{index}", datatypes.Array(1, 1, CHANNELS, side, side)))

    builder = NeuralNetworkBuilder(inputs, [("scores", None), ("boxes", None)],
                                   disable_rank5_shape_mapping=True)

    weighted = []
    for index, (stride, _) in enumerate(LEVELS):
        builder.add_crop_resize(
            name=f"crop_{index}", input_names=[f"features_{index}", "rois"],
            output_name=f"crop_out_{index}",
            target_height=OUTPUT_SIZE * 2, target_width=OUTPUT_SIZE * 2,
            mode="ROI_ALIGN_MODE", normalized_roi=False,
            box_indices_mode="CORNERS_HEIGHT_FIRST", spatial_scale=1.0 / stride,
        )
        # CropResize at 2x then a 2x2 average pool is the construction `add_crop_resize` documents for
        # RoIAlign with sampling_ratio=2 (see `probes.crop_resize_probe`).
        builder.add_pooling(
            name=f"pool_{index}", height=2, width=2, stride_height=2, stride_width=2,
            layer_type="AVERAGE", padding_type="VALID",
            input_name=f"crop_out_{index}", output_name=f"pooled_{index}", exclude_pad_area=True,
        )
        builder.add_slice_static(
            name=f"level_weight_{index}", input_name="level_weights",
            output_name=f"weight_{index}",
            begin_ids=[0, 0, index, 0, 0], end_ids=[batch, 1, index + 1, 1, 1],
            strides=[1] * 5, begin_masks=[False] * 5, end_masks=[False] * 5,
        )
        builder.add_multiply_broadcastable(
            name=f"select_{index}", input_names=[f"pooled_{index}", f"weight_{index}"],
            output_name=f"selected_{index}",
        )
        weighted.append(f"selected_{index}")

    builder.add_add_broadcastable(name="sum_low", input_names=weighted[:2], output_name="sum_low_out")
    builder.add_add_broadcastable(name="sum_high", input_names=weighted[2:], output_name="sum_high_out")
    builder.add_add_broadcastable(name="combine", input_names=["sum_low_out", "sum_high_out"],
                                  output_name="combined")

    flat = CHANNELS * OUTPUT_SIZE * OUTPUT_SIZE
    builder.add_reshape_static(name="flatten", input_name="combined", output_name="flat",
                               output_shape=[batch, flat])

    rng = np.random.default_rng(seed)

    def dense(name: str, fan_in: int, fan_out: int, source: str, target: str) -> None:
        # He-ish scaling. The values do not matter to a memory measurement, but weights that make the
        # activations explode to inf would make a "did it run" check meaningless.
        weight = (rng.standard_normal((fan_out, fan_in)) * math.sqrt(2.0 / fan_in)).astype(np.float32)
        builder.add_inner_product(name=name, W=weight, b=np.zeros(fan_out, dtype=np.float32),
                                  input_channels=fan_in, output_channels=fan_out, has_bias=True,
                                  input_name=source, output_name=target)

    dense("fc1", flat, HIDDEN, "flat", "fc1_out")
    builder.add_activation(name="fc1_relu", non_linearity="RELU",
                           input_name="fc1_out", output_name="fc1_act")
    dense("fc2", HIDDEN, HIDDEN, "fc1_act", "fc2_out")
    builder.add_activation(name="fc2_relu", non_linearity="RELU",
                           input_name="fc2_out", output_name="fc2_act")
    dense("cls_head", HIDDEN, CLASS_COUNT, "fc2_act", "scores")
    dense("bbox_head", HIDDEN, BOX_COORDS, "fc2_act", "boxes")

    return builder.spec


def config_hash(batch: int, seed: int = WEIGHT_SEED) -> str:
    """Everything that changes the compiled artefact, and nothing that does not.

    The invocation count is deliberately absent: B=723/N=1 and B=723/N=8 are the same model called a
    different number of times, so they share a cache entry and the control costs no second build.
    """
    payload = json.dumps({
        "batch": batch, "levels": LEVELS, "channels": CHANNELS, "output_size": OUTPUT_SIZE,
        "hidden": HIDDEN, "classes": CLASS_COUNT, "seed": seed,
    }, sort_keys=True)
    return hashlib.sha256(payload.encode()).hexdigest()[:16]


def compiled_model_path(batch: int, cache_root: Path) -> Path:
    """Build and compile once; every later process only loads.

    Cached outside the repository: a `.mlmodelc` for B=723 is ~56 MiB of random weights, and results/
    holds findings, not binaries.
    """
    destination = cache_root / f"chunk_b{batch}_{config_hash(batch)}.mlmodelc"
    if not destination.exists():
        cache_root.mkdir(parents=True, exist_ok=True)
        compile_model(build_chunk_model(batch), str(destination))
    return destination


# --------------------------------------------------------------------------------------------
# The measured process
# --------------------------------------------------------------------------------------------


def host_inputs(count: int, seed: int) -> tuple:
    """The four feature maps, K ROIs in image coordinates, and their one-hot level assignment.

    The level arithmetic is torchvision's — `floor(4 + log2(sqrt(area)/224))` clamped to [2, 5]
    (`trunk.py:199`) — and it runs *here*, on the host, because that is the concession that lets the
    graph stay static. What crosses into Core ML is its one-hot result, not the boxes' areas.
    """
    rng = np.random.default_rng(seed)
    # `dtype=np.float32`, not `.astype(np.float32)`. The convenient spelling draws float64 first and
    # casts, and 52 MiB of feature maps arrive as a 104 MiB float64 transient that ru_maxrss then
    # remembers forever — an artifact of how this probe invents its inputs, charged to the design
    # under test. A real FPN hands the stage float32.
    features = [rng.standard_normal((1, 1, CHANNELS, side, side), dtype=np.float32)
                for _, side in LEVELS]

    left = rng.uniform(0, IMAGE_SIDE * 0.6, count)
    top = rng.uniform(0, IMAGE_SIDE * 0.6, count)
    boxes = np.stack([
        left, top,
        left + rng.uniform(8, IMAGE_SIDE * 0.35, count),
        top + rng.uniform(8, IMAGE_SIDE * 0.35, count),
    ], axis=1).astype(np.float32)

    side_length = np.sqrt((boxes[:, 2] - boxes[:, 0]) * (boxes[:, 3] - boxes[:, 1]))
    level = np.clip(np.floor(4.0 + np.log2(side_length / 224.0)), 2, 5).astype(np.int64) - 2
    one_hot = np.zeros((count, 1, len(LEVELS), 1, 1), dtype=np.float32)
    one_hot[np.arange(count), 0, level, 0, 0] = 1.0

    # CORNERS_HEIGHT_FIRST, matching every other ROI probe here (`probes.pack_rois`).
    packed = np.zeros((count, 1, 4, 1, 1), dtype=np.float32)
    for slot, column in enumerate((1, 0, 3, 2)):
        packed[:, 0, slot, 0, 0] = boxes[:, column]
    return features, packed, one_hot


def _run_measured(model_path: str, batch: int, invocations: int, mode: str, seed: int) -> dict:
    """One configuration in one mode, in this process. Never builds. Invoked as a subprocess."""
    baseline_mib = _peak_mib()

    started = time.perf_counter()
    model = CompiledMLModel(model_path, compute_units=CPU_ONLY)
    load_seconds = time.perf_counter() - started
    load_peak_mib = _peak_mib()

    row = {
        "mode": mode,
        "baseline_rss_mib": baseline_mib,
        "load_peak_rss_mib": load_peak_mib,
        "load_peak_above_baseline_mib": load_peak_mib - baseline_mib,
        "load_seconds": load_seconds,
    }
    if mode == "load":
        return row

    features, rois, level_weights = host_inputs(ROI_COUNT, seed)
    feature_payload = {f"features_{index}": array for index, array in enumerate(features)}
    row["inputs_rss_above_baseline_mib"] = _peak_mib() - baseline_mib

    # One padding rule for all three roles. `index % ROI_COUNT` pads the tail of a chunked sweep by
    # repeating ROIs (a real emitter would pad K up to a multiple of B the same way) and, when
    # B == ROI_COUNT, hands every invocation the identical full ROI set — which is exactly the
    # repeated-monolithic control, with no second code path to get wrong.
    index = np.arange(batch * invocations) % ROI_COUNT

    accumulated_scores = []
    accumulated_boxes = []
    per_predict = []
    loop_started = time.perf_counter()
    for step in range(invocations):
        window = index[step * batch:(step + 1) * batch]
        payload = dict(feature_payload, rois=rois[window], level_weights=level_weights[window])
        predict_started = time.perf_counter()
        output = model.predict(payload)
        per_predict.append(time.perf_counter() - predict_started)
        # Only the compact outputs survive the iteration. Copying is deliberate: holding Core ML's
        # own buffers would keep whatever else they are attached to alive, which is the failure mode
        # this design exists to avoid.
        accumulated_scores.append(np.array(output["scores"], dtype=np.float32, copy=True))
        accumulated_boxes.append(np.array(output["boxes"], dtype=np.float32, copy=True))
    loop_seconds = time.perf_counter() - loop_started

    scores = np.concatenate(accumulated_scores, axis=0)[:ROI_COUNT]
    boxes = np.concatenate(accumulated_boxes, axis=0)[:ROI_COUNT]
    peak_mib = _peak_mib()

    row.update({
        "peak_rss_mib": peak_mib,
        "peak_above_baseline_mib": peak_mib - baseline_mib,
        "loop_seconds": loop_seconds,
        "seconds_per_predict_mean": loop_seconds / invocations,
        "seconds_per_predict": per_predict,
        "retained_output_mib": (scores.nbytes + boxes.nbytes) / MEBIBYTE,
        # hashlib, not hash(): hash() is salted per process and every configuration runs in its own
        # process, so a cross-process equality check on it silently always fails.
        "output_sha256": hashlib.sha256(
            np.ascontiguousarray(np.concatenate([scores, boxes], axis=1)).tobytes()).hexdigest(),
        "output_sum": float(scores.sum() + boxes.sum()),
        "output_abs_max": float(max(np.abs(scores).max(), np.abs(boxes).max())),
        "output_finite": bool(np.isfinite(scores).all() and np.isfinite(boxes).all()),
    })
    return row


# --------------------------------------------------------------------------------------------
# Orchestration
# --------------------------------------------------------------------------------------------

CHUNK_BATCHES = (52, 91, 182, 364)


def configurations() -> list:
    """The sweep. N is derived from K rather than written down, so K stays the one place to change."""
    configs = [{"name": f"b{batch}", "batch": batch,
                "invocations": math.ceil(ROI_COUNT / batch), "role": "chunked"}
               for batch in CHUNK_BATCHES]
    configs.append({"name": "monolithic", "batch": ROI_COUNT, "invocations": 1,
                    "role": "monolithic"})
    # Eight calls to the whole-batch model. If predictions accumulated, this would sit far above the
    # single-call peak; if they do not, it lands on top of it, and the chunked rows can be read as
    # measuring chunk size rather than measuring how many times `predict` was called.
    configs.append({"name": "monolithic_repeated", "batch": ROI_COUNT, "invocations": 8,
                    "role": "control"})
    return configs


def _worker(model_path: Path, batch: int, invocations: int, mode: str, seed: int) -> dict:
    completed = subprocess.run(
        [sys.executable, str(Path(__file__).resolve()), "--worker", str(model_path), str(batch),
         str(invocations), mode, str(seed)],
        capture_output=True, text=True, check=False,
        env={"PYTHONPATH": str(Path(__file__).resolve().parent), "PATH": "/usr/bin:/bin"},
    )
    if completed.returncode != 0:
        return {"mode": mode, "error": completed.stderr.strip()[-400:]}
    return json.loads(completed.stdout.strip().splitlines()[-1])


def measure(*, only: str = None, seed: int = INPUT_SEED, cache_root: Path = None) -> dict:
    cache_root = cache_root or Path(tempfile.gettempdir()) / "m3a_host_chunking"
    selected = [c for c in configurations() if only is None or c["name"] == only]
    if not selected:
        raise SystemExit(f"no configuration named {only!r}; have "
                         f"{[c['name'] for c in configurations()]}")

    results = []
    for config in selected:
        row = dict(config)
        row["rois_covered"] = config["batch"] * config["invocations"]
        row["config_hash"] = config_hash(config["batch"])
        try:
            model_path = compiled_model_path(config["batch"], cache_root)
        except Exception as exc:  # noqa: BLE001 - a build that fails IS a result
            row["error"] = f"{type(exc).__name__}: {exc}"
            results.append(row)
            continue
        row["compiled_bytes"] = sum(p.stat().st_size for p in model_path.rglob("*") if p.is_file())
        row["load"] = _worker(model_path, config["batch"], config["invocations"], "load", seed)
        row["full"] = _worker(model_path, config["batch"], config["invocations"], "full", seed)
        results.append(row)

    return {
        "protocol": {
            "description": "Each model is built and compiled to .mlmodelc once, out of band. Every "
                           "measured number comes from a fresh subprocess that only loads the "
                           ".mlmodelc (CompiledMLModel, CPU_ONLY) and predicts. Peaks are ru_maxrss "
                           "above a baseline sampled at the top of that process, one configuration "
                           "and one mode per process because ru_maxrss is a high-water mark.",
            "roi_count_k": ROI_COUNT,
            "levels": [{"stride": stride, "side": side} for stride, side in LEVELS],
            "channels": CHANNELS, "pooled_size": OUTPUT_SIZE, "hidden": HIDDEN,
            "chunk_outputs": {"scores": [None, CLASS_COUNT], "boxes": [None, BOX_COORDS]},
            "fc1_weight_mib": CHANNELS * OUTPUT_SIZE ** 2 * HIDDEN * 4 / MEBIBYTE,
            "feature_maps_mib": sum(CHANNELS * side ** 2 for _, side in LEVELS) * 4 / MEBIBYTE,
            "weight_seed": WEIGHT_SEED, "input_seed": seed,
            "not_comparable_to": "the earlier in-process host-chunking smoke run, whose monolithic "
                                 "figure included a builder this protocol removes",
            "coremltools": ct.__version__, "python": sys.version.split()[0],
        },
        "decision_rule": {
            "max_full_run_peak_above_baseline_mib": MAX_FULL_RUN_PEAK_MIB,
            "max_latency_multiple_vs_monolithic": MAX_LATENCY_MULTIPLE,
        },
        "results": results,
    }


def evaluate(report: dict) -> Verdict:
    """VIABLE iff some chunked B fits the memory budget *and* the latency multiple. Both, not either."""
    rows = report["results"]
    monolithic = next((r for r in rows if r.get("role") == "monolithic"
                       and "loop_seconds" in r.get("full", {})), None)
    if monolithic is None:
        return Verdict("host-side chunking", "UNMEASURED",
                       "the monolithic reference did not produce a number to compare against")

    reference_seconds = monolithic["full"]["loop_seconds"]
    reference_peak = monolithic["full"]["peak_above_baseline_mib"]
    passing = []
    for row in rows:
        if row.get("role") != "chunked" or "peak_above_baseline_mib" not in row.get("full", {}):
            continue
        peak = row["full"]["peak_above_baseline_mib"]
        multiple = row["full"]["loop_seconds"] / reference_seconds
        row["latency_multiple_vs_monolithic"] = multiple
        row["peak_saving_vs_monolithic_mib"] = reference_peak - peak
        if peak <= MAX_FULL_RUN_PEAK_MIB and multiple <= MAX_LATENCY_MULTIPLE:
            passing.append((peak, row["name"], multiple))

    if not passing:
        best = min((r["full"]["peak_above_baseline_mib"] for r in rows
                    if r.get("role") == "chunked" and "peak_above_baseline_mib" in r.get("full", {})),
                   default=float("nan"))
        return Verdict("host-side chunking", "FAIL",
                       f"no B met both budgets; lowest chunked peak {best:.1f} MiB "
                       f"(budget {MAX_FULL_RUN_PEAK_MIB:.0f} MiB), monolithic "
                       f"{reference_peak:.1f} MiB / {reference_seconds:.2f} s")

    peak, name, multiple = min(passing)
    return Verdict("host-side chunking", "PASS",
                   f"{len(passing)} of the chunked configurations fit; best is {name} at "
                   f"{peak:.1f} MiB above baseline (budget {MAX_FULL_RUN_PEAK_MIB:.0f}) and "
                   f"{multiple:.2f}x the monolithic wall time (budget {MAX_LATENCY_MULTIPLE:.1f}x)")


def render(report: dict) -> str:
    header = (f"{'config':<21}{'B':>6}{'N':>4}{'load MiB':>11}{'run MiB':>10}"
              f"{'total s':>10}{'ms/call':>10}")
    lines = [header, "-" * len(header)]
    for row in report["results"]:
        if "error" in row:
            lines.append(f"{row['name']:<21}{row['batch']:>6}{row['invocations']:>4}  "
                         f"BUILD FAILED: {row['error'][:60]}")
            continue
        load, full = row.get("load", {}), row.get("full", {})
        if "error" in load or "error" in full:
            failure = load.get("error") or full.get("error")
            lines.append(f"{row['name']:<21}{row['batch']:>6}{row['invocations']:>4}  "
                         f"RUN FAILED: {failure[:60]}")
            continue
        lines.append(
            f"{row['name']:<21}{row['batch']:>6}{row['invocations']:>4}"
            f"{load['load_peak_above_baseline_mib']:>11.1f}"
            f"{full['peak_above_baseline_mib']:>10.1f}"
            f"{full['loop_seconds']:>10.2f}"
            f"{full['seconds_per_predict_mean'] * 1000:>10.1f}"
        )
    lines.append("")
    lines.append("MiB columns are ru_maxrss above each measured process's own baseline.")
    return "\n".join(lines)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--worker":
        path, batch_arg, invocations_arg, mode_arg, seed_arg = sys.argv[2:7]
        print(json.dumps(_run_measured(path, int(batch_arg), int(invocations_arg),
                                       mode_arg, int(seed_arg))))
    else:
        parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
        parser.add_argument("--config", default=None,
                            help="measure one configuration by name instead of the whole sweep")
        parser.add_argument("--seed", type=int, default=INPUT_SEED)
        arguments = parser.parse_args()

        report = measure(only=arguments.config, seed=arguments.seed)
        verdict = evaluate(report)          # annotates the rows it judges, so this runs before the write
        report["verdict"] = {"outcome": verdict.outcome, "detail": verdict.detail}
        print(render(report))
        print(verdict)
        if arguments.config is None:
            RESULTS.mkdir(parents=True, exist_ok=True)
            (RESULTS / "criterion_host_chunking.json").write_text(json.dumps(report, indent=2))
            print("wrote results/criterion_host_chunking.json")
