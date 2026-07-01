---
name: grill-yourself
description: >
  Adversarial self-review: the main model submits its own plan/design to a grill-master
  subagent that interrogates it relentlessly over several rounds — a tough two-way
  discussion until genuine consensus is reached (or disputes are escalated to the human).
  Based on mattpocock's grill-me, inverted: the model, not the user, is on the grill.
  Use when hardening a plan before implementation ("grill yourself", "stress-test this
  plan"), and as the P1 adversarial-review step of /ship-ticket.
---

# grill-yourself — the model on the grill

You (the main model) have a plan, design, or approach. Before acting on it, you submit it
to a **grill-master** — a subagent whose only job is to tear it apart. You then defend,
concede, or revise across **several rounds of genuine discussion** until you both agree,
or you escalate what you can't settle.

The point is not theater. The grill-master must actually try to kill the plan, and you
must actually update it when a hit lands. **Sycophancy in either direction is failure.**

## Protocol

### 1. Prepare the grill packet
Assemble, verbatim, what the grill-master will see:
- The plan/design as currently drafted (numbered steps, assumptions, known risks).
- Verified context: relevant `file:line` facts, constraints from AGENTS.md/ARCHITECTURE.md,
  acceptance criteria. **Check claims in the codebase before writing them down** — the
  grill-master has read access and will catch bluffs.
- The round budget (default **5**).

### 2. Spawn the grill-master
Use the Agent tool with `subagent_type: "grill-master"` (persona in `.claude/agents/grill-master.md`;
if unavailable, use `general-purpose` and paste that persona file into the prompt).
Run it **synchronously** — the discussion is the task. Instruct it to reply in its
round format (numbered objections with severity, a recommended resolution per objection,
and a final `VERDICT: CONTINUE` or `VERDICT: CONSENSUS`).

### 3. Answer every objection — honestly
For each objection, exactly one of:
- **Concede** — the hit landed. Revise the plan and show the revision.
- **Rebut with evidence** — cite `file:line`, a command output, a doc. "I believe" is not
  evidence. If checking requires exploring the codebase, explore it *before* replying
  (grill-me rule: never ask/answer what the repo can answer).
- **Flag as human-owned** — a genuine product/scope decision neither of you owns. Park it
  for the escalation list; don't debate it further.

No bundling: address objections one by one, keeping the grill-master's numbering.

### 4. Continue the same discussion
Send your answers back via **SendMessage to the same agent** (never spawn a fresh one —
the discussion's context is the value). The grill-master drops settled objections,
presses unsettled ones deeper, and may open a *new* branch of the design tree only after
the current branch is resolved (one branch at a time, per the original grilling skill).

### 5. Terminate on one of exactly three conditions
- **`VERDICT: CONSENSUS`** — the grill-master states the plan is sound *and you agree
  with its residual-risk list*. Consensus requires reasons on both sides; "fine, whatever"
  from either side is a protocol violation.
- **Round budget exhausted** (default 5) — stop, do not grind.
- **Deadlock** — the same objection has survived two full exchanges unchanged.

### 6. Output (always, regardless of how it ended)
1. **Hardened plan** — the revised plan.
2. **Concession log** — what changed and which objection forced it.
3. **Accepted-risk register** — objections both sides agreed to accept, with reasons.
4. **Escalations** — unresolved disputes + human-owned decisions, each as a one-line
   question for the user. If this list is non-empty, present it before implementing.

## Rules of engagement
- The grill-master owes you zero deference; you owe it zero deference. Rank does not exist.
- Every factual claim by either side is checkable; the loser of a fact-check concedes the point.
- Concede fast when wrong — rounds are expensive; spend them on live disagreements.
- Never soften the grill-master's findings when reporting to the user.
- A plan that survives unchanged through 5 rounds is suspicious: either the grill-master
  went soft (re-run with a sharper packet) or the plan was already reviewed — say which.
