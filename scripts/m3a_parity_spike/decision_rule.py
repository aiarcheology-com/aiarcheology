"""The rule that turns numbers into a verdict, written down before the verdict is read off them.

"Closely enough to be worth shipping" is not a measurement, and a spike that picks its tolerances
after seeing its results has not measured anything — it has rationalised. So the thresholds live here,
each with the reason it has the value it has, and `evaluate()` applies them mechanically.

**Disclosure, because the alternative is a lie of omission.** This file was written after exploratory
probes had already run, so this is not preregistration in the clinical sense. What protects it is
that every threshold below is derived from a property of ADAF's pipeline or of the app, not from an
observed value: the box budget comes from what ADAF does with a box downstream, the score budget from
the distance to its own vectorisation cut, the unmatched budget from what a detection set is for. The
observed numbers are recorded beside each threshold in FINDINGS.md so a reader can see the margin and
judge for themselves whether the rule was bent to fit.

The rule deliberately does **not** cover cost. A model can pass every numeric threshold here and
still be unshippable on memory or latency; that is a separate judgement with its own numbers, and
flattening the two would let a beautiful parity number carry an unshippable model.
"""

from __future__ import annotations

from dataclasses import dataclass

# A detection whose box moves by less than a pixel cannot change what ADAF does with it: the
# vectorisation step rasterises boxes to polygons at raster resolution, so sub-pixel motion is below
# the quantisation of the consumer. One pixel is therefore a real budget, not a round number.
MAX_BOX_SHIFT_PX = 1.0

# ADAF thresholds detections at 0.5 and this app defaults to the same. A score perturbation only
# matters if it can carry a detection across that line; 0.01 is 2% of the cut, and detections
# clustering within 0.01 of 0.5 are ambiguous to the model itself, not just to Core ML.
MAX_SCORE_DELTA = 0.01

# Detection-set membership is the product. One unmatched detection in a set is a visible error to a
# user reviewing findings, so the budget is zero rather than a percentage.
MAX_UNMATCHED_DETECTIONS = 0

# Boxes are matched one-to-one at this IoU before their shift and score are compared. Below this the
# "same" detection is not the same detection.
MATCH_IOU = 0.5

# Elementwise stages sit before any top-K, so they can be judged as tensors. Float32 accumulation
# over a 134-layer conv stack is the floor; 1e-4 is well above it and well below anything that could
# reorder a proposal.
MAX_ELEMENTWISE_ABS = 1e-4

# A criterion measured on fewer than this many confident detections is reported as UNDERPOWERED
# rather than PASS: a threshold met by one detection is met by one detection.
MIN_EXERCISED_DETECTIONS = 1


@dataclass
class Verdict:
    criterion: str
    outcome: str          # PASS | FAIL | UNDERPOWERED | UNMEASURED
    detail: str

    def __str__(self) -> str:
        return f"{self.outcome:12s} {self.criterion}: {self.detail}"


def judge_elementwise(criterion: str, max_abs: float | None) -> Verdict:
    if max_abs is None:
        return Verdict(criterion, "UNMEASURED", "no Core ML side was run")
    if max_abs <= MAX_ELEMENTWISE_ABS:
        return Verdict(criterion, "PASS", f"max |delta| {max_abs:.2e} <= {MAX_ELEMENTWISE_ABS:.0e}")
    return Verdict(criterion, "FAIL", f"max |delta| {max_abs:.2e} > {MAX_ELEMENTWISE_ABS:.0e}")


def judge_detection_set(criterion: str, *, matched: int, unmatched_reference: int,
                        unmatched_candidate: int, max_box_shift: float | None,
                        max_score_delta: float | None) -> Verdict:
    unmatched = unmatched_reference + unmatched_candidate
    if matched == 0 and unmatched == 0:
        return Verdict(criterion, "UNMEASURED", "no detections on either side")
    if unmatched > MAX_UNMATCHED_DETECTIONS:
        return Verdict(criterion, "FAIL", f"{unmatched} unmatched detections (budget {MAX_UNMATCHED_DETECTIONS})")
    if max_box_shift is not None and max_box_shift > MAX_BOX_SHIFT_PX:
        return Verdict(criterion, "FAIL", f"box shift {max_box_shift:.4f} px > {MAX_BOX_SHIFT_PX} px")
    if max_score_delta is not None and max_score_delta > MAX_SCORE_DELTA:
        return Verdict(criterion, "FAIL", f"score delta {max_score_delta:.5f} > {MAX_SCORE_DELTA}")
    if matched < MIN_EXERCISED_DETECTIONS:
        return Verdict(criterion, "UNDERPOWERED", f"only {matched} detections exercised")
    detail = (f"{matched} matched, 0 unmatched, box shift "
              f"{(max_box_shift if max_box_shift is not None else float('nan')):.5f} px, score delta "
              f"{(max_score_delta if max_score_delta is not None else float('nan')):.6f}")
    return Verdict(criterion, "PASS", detail)


def judge_boolean(criterion: str, ok: bool, detail: str) -> Verdict:
    return Verdict(criterion, "PASS" if ok else "FAIL", detail)
