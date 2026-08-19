"""Criterion 2: what a fixed top-K costs, and what static shapes cost besides recall.

Three things make the obvious version of this experiment useless, and each is worked around here.

**A retention curve would be flat.** torchvision's own pipeline is already capped — 1000 proposals
per level before RPN NMS, 1000 after, and 100 final detections — so an "unbounded oracle" does not
exist to compare against, and on imagery with a handful of features every K in a plausible sweep
retains 100% of a very small set. The curve would be a horizontal line through two points. So the
reported quantity is the **rank margin**: for each surviving detection, the rank of the proposal it
came from. "The worst kept detection came from proposal 37 of 1000" says how much headroom a cut has;
"retention was 100%" does not. Retention is still reported, but as oracle-set agreement, not as
recall — there are no labels here, so nothing in this file can measure recall and nothing claims to.

**Changing both cuts at once cannot attribute the loss.** The pre-NMS and post-NMS cuts are swept
independently, holding the other at its default, before any joint grid.

**Retention need not be monotone in K**, so a monotonicity check is not a valid harness self-test. A
proposal admitted by a larger K can win a high score at the box head and then suppress or displace a
detection that a smaller K had kept. An earlier draft of this plan verified monotonicity and would
have flagged correct behaviour as a bug.

And the part the ticket does not ask for but a go/no-go needs: static shapes do not only *lose*
detections, they can *invent* them, and they cost memory that may decide the question outright.
"""

from __future__ import annotations

import numpy as np
import torch

MEBIBYTE = 2 ** 20


def static_roi_memory(k: int, *, channels: int = 256, crop: int = 14, pooled: int = 7,
                      levels: int = 4, dtype_bytes: int = 4) -> dict:
    """The memory a statically-shaped ROI stage needs, which is not a detail.

    Per-ROI level assignment is data dependent, and a data-dependent gather has no fixed output
    shape. The static workaround is to crop every ROI at *every* level and select afterwards — so the
    ROI tensors are `levels` times larger than a dynamic implementation would allocate. At
    torchvision's default K of 1000 that is three quarters of a gigabyte before a single weight is
    loaded, which on iOS is a jetsam question rather than an accuracy one.
    """
    crop_bytes = k * channels * crop * crop * dtype_bytes * levels
    pooled_bytes = k * channels * pooled * pooled * dtype_bytes * levels
    return {
        "k": k,
        "levels_cropped": levels,
        "crop_tensor_mib": crop_bytes / MEBIBYTE,
        "pooled_tensor_mib": pooled_bytes / MEBIBYTE,
        "dtype_bytes": dtype_bytes,
    }


def memory_table(ks=(1000, 512, 256, 128, 100, 64), **kwargs) -> list:
    return [static_roi_memory(k, **kwargs) for k in ks]


def proposal_statistics(model: torch.nn.Module, image_chw: np.ndarray) -> dict:
    """Where the proposals actually are, per level, before and after RPN NMS.

    Measured rather than assumed because the per-level pre-NMS cut is `min(pre_nms_top_n, anchors)`
    (`rpn.py:236` via `det_utils._topk_min`) — the topmost level holds fewer anchors than the cut, so
    a harness that pads every level to 1000 mismeasures both the margin and the padding cost.
    """
    image = torch.from_numpy(image_chw)
    with torch.no_grad():
        images, _ = model.transform([image])
        features = model.backbone(images.tensors)
        feature_list = list(features.values())
        objectness, deltas = model.rpn.head(feature_list)
        anchors = model.rpn.anchor_generator(images, feature_list)
        counts = [o[0].numel() for o in objectness]
        # RPN.forward returns (boxes, losses) — the second value is a losses dict and is empty in
        # eval, so proposal scores are not available from it. The objectness logits are, and they
        # are the raw pre-top-K signal the ticket's elementwise regime names.
        proposals, _ = model.rpn(images, features)
        flat_objectness = torch.cat([o.flatten() for o in objectness])

    return {
        "padded_input_shape": list(images.tensors.shape),
        "objectness_per_level": [int(c) for c in counts],
        "total_anchors": int(sum(counts)),
        "proposals_after_rpn": int(proposals[0].shape[0]),
        "objectness_logit_min": float(flat_objectness.min()),
        "objectness_logit_max": float(flat_objectness.max()),
    }


def rank_margin(model: torch.nn.Module, image_chw: np.ndarray) -> dict:
    """For every final detection, the rank of the proposal it came from.

    This is the quantity a fixed K actually threatens. If the worst-ranked contributing proposal sits
    at 37 of 1000, K can drop to 64 with room to spare; if it sits at 900, it cannot. Retention
    percentages hide exactly that, which is why they are not the headline here.
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
        boxes, scores, labels = model.roi_heads.postprocess_detections(
            class_logits, box_regression, proposals, image_shapes
        )

        # Which proposal produced each surviving detection: torchvision flattens
        # (proposal, class) pairs, so the proposal index is recoverable by score identity.
        probabilities = torch.nn.functional.softmax(class_logits, -1)
        proposal_count = proposals[0].shape[0]

    ranks = []
    ambiguous = 0
    kept_scores = scores[0].numpy()
    foreground = probabilities[:, 1:].max(dim=1).values.numpy()

    for score in kept_scores:
        matches = np.nonzero(np.isclose(foreground, score, rtol=1e-5, atol=1e-7))[0]
        if matches.size:
            # The rank is the proposal's POSITION in the RPN-ordered list, because that is what a
            # fixed K truncates: `filter_proposals` emits proposals score-descending and a static
            # graph keeps the first K of them. An earlier version re-sorted by box-head foreground
            # score and reported that ordering instead — which answers a different question and
            # flattered the result badly. On OD_enclosure it reported a worst rank of 102 where the
            # true positions run to 722, so a K chosen from it would have silently dropped
            # detections the spike claimed were safe.
            ranks.append(int(matches[0]))
            ambiguous += int(matches.size > 1)

    return {
        "proposals": int(proposal_count),
        "detections": int(len(kept_scores)),
        "contributing_proposal_positions": sorted(ranks),
        "worst_contributing_position": max(ranks) if ranks else None,
        # The smallest K that still contains every contributing proposal, by position.
        "safe_k": (max(ranks) + 1) if ranks else None,
        # A score collision would make the position attribution unreliable; report it rather than
        # letting a silent mis-attribution look like a measurement.
        "ambiguous_attributions": ambiguous,
    }


def sweep_cut(model: torch.nn.Module, image_chw: np.ndarray, *, which: str,
              values=(1000, 512, 256, 128, 64)) -> list:
    """Sweep ONE cut at a time, holding the other at its default.

    Sweeping both together produces a surface on which no loss can be attributed to a cause, which is
    the whole reason to sweep at all.
    """
    if which not in ("pre_nms", "post_nms"):
        raise ValueError(which)

    original_pre = dict(model.rpn._pre_nms_top_n)
    original_post = dict(model.rpn._post_nms_top_n)
    baseline = None
    rows = []
    try:
        for value in values:
            if which == "pre_nms":
                model.rpn._pre_nms_top_n = {"training": value, "testing": value}
            else:
                model.rpn._post_nms_top_n = {"training": value, "testing": value}
            with torch.no_grad():
                out = model([torch.from_numpy(image_chw)])[0]
            boxes, scores = out["boxes"].numpy(), out["scores"].numpy()
            if baseline is None:
                baseline = (boxes, scores)
            retained, surplus = _agreement(baseline[0], boxes)
            rows.append({
                "cut": which,
                "value": value,
                "detections": int(len(boxes)),
                "max_score": float(scores.max()) if len(scores) else None,
                # Agreement with the DEFAULT-cut oracle set, not "recall": no labels exist here.
                "oracle_set_retained": retained,
                # And the other direction, which a one-sided metric hides. A smaller K can ADD a
                # detection the baseline never had — measured at K=128 on OD_enclosure, which
                # returned 9 boxes against a baseline of 8 while one-directional agreement still
                # read 1.0. Losing nothing is not the same as changing nothing.
                "surplus_detections": surplus,
                # The raw counts, so a reader can check the metric against them rather than trust it.
                "baseline_detections": int(len(baseline[0])),
            })
    finally:
        model.rpn._pre_nms_top_n = original_pre
        model.rpn._post_nms_top_n = original_post
    return rows


def _agreement(reference_boxes: np.ndarray, candidate_boxes: np.ndarray,
               iou_threshold: float = 0.5) -> tuple:
    """Both directions: the fraction of the baseline retained, and how many boxes are surplus.

    Matching is **one-to-one**, and that is the whole point. Asking only "does this candidate overlap
    *some* reference box" misses a duplicate — two candidates matching one reference — and a
    duplicate is a detection the graph produced that the baseline did not. Measured on OD_enclosure
    at K=128: the baseline returns 8 boxes and the cut returns 9, and the any-match version scored
    that as retained 1.0 with 0 surplus. One-to-one matching finds the extra box.

    This is the second time this metric has been too generous. The first version reported only
    retention, which hid the change entirely; the second counted surplus by any-match, which hid a
    duplicate. Both were caught by comparing the reported number against the raw detection counts,
    which is why those counts are also written to the results file.
    """
    if len(reference_boxes) == 0:
        return None, int(len(candidate_boxes))
    if len(candidate_boxes) == 0:
        return 0.0, 0
    from torchvision.ops import box_iou

    iou = box_iou(torch.from_numpy(reference_boxes), torch.from_numpy(candidate_boxes)).numpy()
    claimed: set = set()
    matched = 0
    # Greedy by best available overlap, so the strongest pairing wins before the weaker ones and a
    # second candidate cannot re-use a reference that is already spoken for.
    for reference_index in np.argsort(-iou.max(axis=1)):
        available = [(iou[reference_index, j], j) for j in range(len(candidate_boxes))
                     if j not in claimed]
        if not available:
            break
        best_iou, best_index = max(available)
        if best_iou >= iou_threshold:
            claimed.add(best_index)
            matched += 1

    retained = matched / len(reference_boxes)
    surplus = len(candidate_boxes) - matched
    return retained, surplus


def padding_false_positives(model: torch.nn.Module, image_chw: np.ndarray, *,
                            pad_to: int) -> dict:
    """Do the zero boxes that static NMS pads with become detections?

    This must be measured with torchvision's cleanup disabled or the answer is zero by construction:
    `rpn.py:277-285` runs `clip_boxes_to_image` then `remove_small_boxes(1e-3)` before NMS, and
    `roi_heads.py:694-716` runs `clip`, a score filter and `remove_small_boxes(1e-2)` before
    `batched_nms`. Feeding a padded proposal set into torch therefore hands the zero boxes straight to
    code that deletes them — while an emitted static graph has no such cleanup unless someone builds
    it, because a filter that removes a variable number of boxes has no fixed output shape.

    So the padded proposals go through the box head directly, and the question asked is the honest
    one: does the head assign a padded zero box a foreground score above the detector's own
    threshold?
    """
    image = torch.from_numpy(image_chw)
    with torch.no_grad():
        images, _ = model.transform([image])
        features = model.backbone(images.tensors)
        proposals, _ = model.rpn(images, features)

        real = proposals[0]
        padding = torch.zeros((max(0, pad_to - real.shape[0]), 4), dtype=real.dtype)
        padded = torch.cat([real, padding], dim=0)

        pooled = model.roi_heads.box_roi_pool(features, [padded], images.image_sizes)
        head = model.roi_heads.box_head(pooled)
        class_logits, _ = model.roi_heads.box_predictor(head)
        probabilities = torch.nn.functional.softmax(class_logits, -1)

    padded_start = real.shape[0]
    padded_scores = probabilities[padded_start:, 1:].max(dim=1).values.numpy()
    threshold = model.roi_heads.score_thresh
    return {
        "real_proposals": int(padded_start),
        "padded_boxes": int(padded.shape[0] - padded_start),
        "score_threshold": threshold,
        # Strict `>`, matching roi_heads.py:711.
        "padded_boxes_above_threshold": int((padded_scores > threshold).sum()),
        "max_padded_score": float(padded_scores.max()) if padded_scores.size else None,
        "note": "measured with torchvision's clip/remove_small_boxes cleanup bypassed, because an "
                "emitted static graph cannot contain a variable-length filter",
    }
