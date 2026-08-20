# M3a — Faster R-CNN to Core ML parity spike (AIA-0670)

Throwaway measurement code for one question: **can this app emit a Core ML model that reproduces
`fasterrcnn_resnet50_fpn_v2`'s detections closely enough to be worth shipping?**

No production code lives here. Nothing in `Sources/` or `ios/` imports any of it. The deliverable is
[`FINDINGS.md`](FINDINGS.md) plus the JSON under `results/`, and the go/no-go comment on
[#670](https://github.com/aiarcheology-com/aiarcheology/issues/670).

## Rebuilding the environment

The oracle needs Python with torch, torchvision and coremltools. Python 3.9 is deliberate: it is what
ADAF's own README targets, so the oracle runs on the interpreter series ADAF runs on.

```
python3 -m venv .venv-m3a                       # from the repository root
.venv-m3a/bin/python -m pip install --upgrade pip wheel
.venv-m3a/bin/python -m pip install torch torchvision coremltools numpy pillow
```

`.venv-m3a/` is gitignored. The exact versions these numbers were produced with are recorded in
`results/environment.json` — read them from there rather than assuming the resolver picks the same
ones twice.

The checkpoints must be **dense**. `scripts/fetch_adaf_checkpoints.sh` writes sparse copies by
default — true length, hole in the middle — which is correct for the Swift reader, whose entire read
set is the end records and `data.pkl`, and fatal here, because a hole reads back as zeros rather than
as an error. `oracle.gate_checkpoint` refuses to run on one; fetch with `--full`, or use
`scripts/m3a_parity_spike`'s own manifest-verified fetch.

## Running it

```
PYTHONPATH=scripts/m3a_parity_spike .venv-m3a/bin/python scripts/m3a_parity_spike/run_spike.py
```

Writes one JSON per criterion into `results/`, prints a verdict per criterion, and exits non-zero if
any threshold in `decision_rule.py` is breached.

## What each module is for

| File | Question it answers |
|-|-|
| `oracle.py` | ADAF's detector, built as the vendored aitlas wheel builds it — plus the density gate that refuses a checkpoint of holes |
| `inputs.py` | The corpus: ADAF's real SLRM figures, contamination checks, the input-scaling sweep, paired quantisation, the synthetic float control |
| `probes.py` | Single NN-spec operations, built and run in isolation |
| `criterion_transform.py` | Criterion 0 — the resize nobody listed, and the `min_size` pin that removes it |
| `criterion_roi_align.py` | Criterion 1 — RoIAlign, decomposed into sampling grid, coordinate layout and sampling ratio |
| `criterion_topk.py` | Criterion 2 — rank margin, invented detections from padding, and the memory bound |
| `criterion_nms.py` | Criterion 4 — all three suppression passes, including the mid-graph one the ticket does not list |
| `trunk.py` | A real Core ML backbone/FPN/RPN head, and the substitution harness that composes the pieces |
| `decision_rule.py` | The thresholds, with the reason each has its value |
| `run_spike.py` | The driver |
| `VisionReplay/` | A Swift harness that drives a model the way the app does — through Vision, not `MLModel.predict` |

## Two things to know before reading the numbers

**Probes target NN-spec, not MIL.** This repository emits the legacy neural-network protobuf
(`NATIVE_MODEL_CONVERSION.md`), so a measurement taken against ML Program would describe a format
M3c is not going to write. coremltools appears here only as a throwaway builder and as the `predict`
harness. Its torch converter is used in exactly one place — the trunk, where the alternative was
hand-building 134 convolution layers to re-measure a conv stack nobody doubts — and never as a
proposed shipping path. Worth recording on its own: **coremltools 9.0 ships no `roi_align` mapping at
all**, so there was never an upstream conversion route to inherit a choice from.

**Everything here runs on the Mac, CPU only.** That is a controlled semantic baseline for the
operators, and it is not what the app does: the app leaves `MLModelConfiguration` at its default
(`DeepDriver.swift:67`), so the shipping path may run on GPU or the Neural Engine, with float16 and
graph partitioning. Nothing in `results/` measures that. It is named as a residual risk in
`FINDINGS.md` and it is M3b's to retire, not this spike's to assume away.
