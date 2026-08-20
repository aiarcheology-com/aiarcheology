"""Can the ROI stage be chunked, and does chunking actually buy the memory back?

This is the measurement M3a's go/no-go leans on hardest without having made. Criterion 2 established
that a static graph must crop every ROI at every FPN level — per-ROI level assignment is data
dependent and a data-dependent gather has no fixed output shape — which at the measured K of 723
costs 553.5 MiB of 14x14 crops. Chunking into a fixed number of fixed-size batches is the obvious
lever, and "obvious lever" was doing a lot of work in a document that otherwise refuses to assert
anything it has not measured.

Two questions, and the second is the one that can disappoint:

1. **Is it expressible?** A chunked stage is `slice_static` → `crop_resize` → pool, repeated, then
   `concat_nd`. Every one of those has a fixed output shape, so nothing here needs a dynamic gather.
2. **Does the peak actually drop?** Not automatic. All chunks feed a concatenate, so the *pooled*
   outputs accumulate whatever the chunking — the saving is only on the transient 14x14 crops, and
   only if Core ML frees each chunk's crop before building the next. That is a scheduler behaviour,
   not a guarantee, so it is measured rather than assumed.

Peak memory is measured **one configuration per process**. `ru_maxrss` is a high-water mark that
never falls, so measuring several configurations in one process reports the largest of them for all
of them — which would make chunking look useless no matter how well it worked.
"""

from __future__ import annotations

import hashlib
import json
import resource
import subprocess
import sys
from pathlib import Path

import numpy as np

import coremltools as ct
from coremltools.models import datatypes
from coremltools.models.neural_network import NeuralNetworkBuilder

from probes import CPU_ONLY, pack_rois

MEBIBYTE = 2 ** 20


def build_roi_stage(*, channels: int, height: int, width: int, roi_count: int, chunks: int,
                    output_size: int = 7, spatial_scale: float = 1.0) -> ct.models.MLModel:
    """The ROI stage as one NN-spec model, in `chunks` fixed-size batches.

    `chunks == 1` is the unchunked stage and is the reference the others are compared against. The
    ROI count must divide evenly; a real emitter would pad K up to a multiple of the chunk size,
    which is why the caller rounds rather than this function guessing.
    """
    if roi_count % chunks:
        raise ValueError(f"roi_count {roi_count} is not divisible into {chunks} chunks")
    per_chunk = roi_count // chunks

    inputs = [
        ("features", datatypes.Array(1, 1, channels, height, width)),
        ("rois", datatypes.Array(roi_count, 1, 4, 1, 1)),
    ]
    builder = NeuralNetworkBuilder(inputs, [("pooled", None)], disable_rank5_shape_mapping=True)

    pooled_names = []
    for index in range(chunks):
        roi_name = "rois"
        if chunks > 1:
            roi_name = f"rois_{index}"
            builder.add_slice_static(
                name=f"slice_{index}", input_name="rois", output_name=roi_name,
                begin_ids=[index * per_chunk, 0, 0, 0, 0],
                end_ids=[(index + 1) * per_chunk, 1, 4, 1, 1],
                strides=[1] * 5, begin_masks=[False] * 5, end_masks=[False] * 5,
            )
        builder.add_crop_resize(
            name=f"crop_{index}", input_names=["features", roi_name],
            output_name=f"crop_out_{index}",
            target_height=output_size * 2, target_width=output_size * 2,
            mode="ROI_ALIGN_MODE", normalized_roi=False,
            box_indices_mode="CORNERS_HEIGHT_FIRST", spatial_scale=spatial_scale,
        )
        pooled_name = f"pooled_{index}" if chunks > 1 else "pooled"
        builder.add_pooling(
            name=f"pool_{index}", height=2, width=2, stride_height=2, stride_width=2,
            layer_type="AVERAGE", padding_type="VALID",
            input_name=f"crop_out_{index}", output_name=pooled_name, exclude_pad_area=True,
        )
        pooled_names.append(pooled_name)

    if chunks > 1:
        builder.add_concat_nd(name="concat", input_names=pooled_names, output_name="pooled", axis=0)
    return ct.models.MLModel(builder.spec, compute_units=CPU_ONLY)


def analytic_bytes(*, channels: int, roi_count: int, chunks: int, output_size: int = 7) -> dict:
    """What the shapes say, for the **single level** this probe actually runs.

    Reported per level rather than multiplied by four, because the measurement below runs one level
    and comparing a one-level measurement against a four-level prediction is how a table lies. The
    four-level projection is a separate field, clearly labelled as arithmetic rather than
    observation.
    """
    per_chunk = roi_count // chunks
    crop = per_chunk * channels * (output_size * 2) ** 2 * 4
    pooled = roi_count * channels * output_size ** 2 * 4
    return {
        "transient_crop_mib_one_level": crop / MEBIBYTE,
        "accumulated_pooled_mib_one_level": pooled / MEBIBYTE,
        "predicted_peak_mib_one_level": (crop + pooled) / MEBIBYTE,
        "predicted_peak_mib_four_levels_projected": 4 * (crop + pooled) / MEBIBYTE,
    }


def _peak_mib() -> float:
    peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    # macOS reports ru_maxrss in bytes; Linux in kibibytes. Detected by magnitude rather than
    # platform string, since a wrong unit would silently rescale the whole finding.
    return peak / MEBIBYTE if peak > 10 ** 7 else peak / 1024


def _run_one(channels: int, height: int, width: int, roi_count: int, chunks: int, seed: int) -> dict:
    """One configuration, in this process. Invoked as a subprocess by `measure`."""
    baseline_peak = _peak_mib()
    rng = np.random.default_rng(seed)
    features = rng.standard_normal((1, 1, channels, height, width)).astype(np.float32)
    left = rng.uniform(0, width * 0.6, roi_count)
    top = rng.uniform(0, height * 0.6, roi_count)
    boxes = np.stack([
        left, top,
        left + rng.uniform(4, width * 0.35, roi_count),
        top + rng.uniform(4, height * 0.35, roi_count),
    ], axis=1).astype(np.float32)

    model = build_roi_stage(channels=channels, height=height, width=width,
                            roi_count=roi_count, chunks=chunks)
    out = np.asarray(
        model.predict({"features": features, "rois": pack_rois(boxes, "CORNERS_HEIGHT_FIRST")})["pooled"]
    ).reshape(roi_count, channels, 7, 7)

    peak_mib = _peak_mib()
    return {
        "chunks": chunks,
        "rois_per_chunk": roi_count // chunks,
        "baseline_rss_mib": baseline_peak,
        "peak_rss_mib": peak_mib,
        "peak_above_baseline_mib": peak_mib - baseline_peak,
        # hashlib, not Python's hash(): hash() is salted per process and every configuration runs in
        # its own process, so it never matches and the equality check silently always failed.
        "output_sha256": hashlib.sha256(np.ascontiguousarray(out).tobytes()).hexdigest(),
        "output_sum": float(out.sum()),
        "output_shape": list(out.shape),
    }


def measure(*, channels: int = 256, height: int = 200, width: int = 200, roi_count: int = 728,
            chunk_counts=(1, 2, 4, 8, 14), seed: int = 0) -> dict:
    """Run each configuration in its own process and compare numerics and peak memory."""
    results = []
    for chunks in chunk_counts:
        if roi_count % chunks:
            continue
        completed = subprocess.run(
            [sys.executable, str(Path(__file__).resolve()), "--worker",
             str(channels), str(height), str(width), str(roi_count), str(chunks), str(seed)],
            capture_output=True, text=True, check=False,
            env={"PYTHONPATH": str(Path(__file__).resolve().parent), "PATH": "/usr/bin:/bin"},
        )
        if completed.returncode != 0:
            results.append({"chunks": chunks, "error": completed.stderr.strip()[-300:]})
            continue
        row = json.loads(completed.stdout.strip().splitlines()[-1])
        row.update(analytic_bytes(channels=channels, roi_count=roi_count, chunks=chunks))
        results.append(row)

    reference = next((r for r in results if r.get("chunks") == 1 and "error" not in r), None)
    for row in results:
        if "error" in row or reference is None:
            continue
        # Numerics must be identical, not merely close: chunking reorders nothing and changes no
        # arithmetic, so anything other than an exact match means the slicing is wrong.
        row["matches_unchunked_exactly"] = row["output_sha256"] == reference["output_sha256"]
        row["peak_saving_mib"] = (reference["peak_above_baseline_mib"]
                                  - row["peak_above_baseline_mib"])

    return {
        "configuration": {"channels": channels, "feature_map": [height, width],
                          "roi_count": roi_count, "levels_assumed_for_analytic": 4},
        "note": "peak measured one configuration per process, because ru_maxrss is a high-water "
                "mark and several configurations in one process would report the largest for all",
        "results": results,
    }


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--worker":
        channels, height, width, roi_count, chunks, seed = (int(v) for v in sys.argv[2:8])
        print(json.dumps(_run_one(channels, height, width, roi_count, chunks, seed)))
    else:
        print(json.dumps(measure(), indent=2))
