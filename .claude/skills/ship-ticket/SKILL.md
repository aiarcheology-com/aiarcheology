---
name: ship-ticket
description: >
  Autonomously drive a GitHub ticket (or an inline description) to a green, locally-verified PR
  for the ML Browser iOS app — plan, adversarial plan review, implement with frequent commits,
  local verify (objective sweep + advisory agentic check), code review, open PR, address
  Copilot/CodeRabbit comments, poll CI to green — pausing only at a short upfront Q&A and the two
  irreversible/cost gates (every push, every merge). Use when the user says "ship this ticket",
  "take AIA-0XXX to a PR", "/ship-ticket <issue#>", or hands you a ticket to implement end-to-end.
allowed-tools: [Bash, Read, Edit, Write, Grep, Glob, Task, AskUserQuestion]
---

# ship-ticket — autonomous ticket → testable PR

You are a **thin orchestrator + fixer**. You compose existing skills (`agent-skills:code-review`,
`grill-yourself`, CodeRabbit, codex) and drive the ML Browser ship workflow deterministically.
The single guiding invariant: **zero unapproved irreversible or paid side effects.** Everything
local is autonomous; every push and every merge is human-gated because Xcode Cloud CI is paid.

## When to activate
- `/ship-ticket <issue#>` or `/ship-ticket "<inline description>"`.
- "ship this ticket", "implement AIA-0XXX end to end", "take this to a green PR".

Do **not** activate for a one-line fix the user is watching you make — that's just normal editing.

## Flags
- `--plan-gate` — force the plan-approval stop on (G1) regardless of risk tier.
- `--no-ui-tests` — skip the UI suite for speed. **Forces a mandatory
  "⚠️ UI-unverified (UI suite skipped)" banner** in the PR body and the G2 prompt. Never silently
  weakens the gate.
- (There is intentionally **no** `--auto-push`. Every push is always gated.)

## Project conventions (baked in — do not re-derive)
- **Xcode toolchain:** validate `DEVELOPER_DIR` by discovery, never assume:
  `xcode-select -p`, else probe `/Applications/Xcode*.app/Contents/Developer` (prefer the
  versioned `Xcode-26.6.0.app`). Export it for **every** `xcodebuild`/`xcrun`/git-with-hooks call —
  background shells lose the selection and fall back to CommandLineTools. Fail loudly if none.
- **Build/test dir:** always `cd` to `ios/` (the workspace lives there, not the repo root).
- **Sims:** run tests on the **non-disrupting** sim `AB795324-BC67-4A1D-A275-8E5A84829060`
  (iPhone Air). Never launch on the user's active sim `F1C04808-8017-43B4-AC58-275A8152429B`.
  The P3b advisory verifier uses its **own** dedicated `simctl erase`'d sim.
- **UI tests:** require `-testPlan MLBrowserUITests` (the scheme default excludes them).
  `SIMCTL_CHILD_UI_TESTING=1` activates the DEBUG mock auth/subscription providers (bypasses
  auth/paywall) — it also wipes the Caches Core Data store, so it is a *different* path than
  production; only use it when a flow is otherwise unreachable, and label it in evidence.
- **Commits:** no co-author footnote. If 1Password is locked (signing/SSH fail), fall back to
  `git -c commit.gpgsign=false commit …` and push via the `gh`-credentialed HTTPS remote.
- **Branch/issue:** `feature/AIA-XXXX/<slug>`, base `develop`. Title issues `AIA-0XXX: …`.
  Add to project board #1 (owner `aiarcheology-com`); Status field `PVTSSF_lADODw8uZM4BMCyNzg7cGQI`,
  options: In Review `ce9bc762`, Done `98236657`.
- **Pre-push gate mirrors CI:** `./scripts/swiftlint.sh` + `./scripts/harmonize.sh` (both run
  **from the repo root**, not `ios/`) + unit + UI tests.
- **Tool resolution:** repo tools are resolved via their `scripts/*.sh` wrappers
  (`swiftgen.sh`, `swiftlint.sh`, `harmonize.sh`), which probe bundled locations
  (e.g. SwiftGen at `~/.local/lib/swiftgen/bin`). **Never conclude a tool is missing from a bare
  `which <bin>`** — run the wrapper's `--verify`/`--help` first. (This produced a false blocker on
  the first run.)
- **Localization:** adding/changing L10n strings has a strict recipe and a file-reformat trap —
  see `references/localization.md`. Do **not** hand-edit `L10n.swift`; regenerate it.

## Durable state & resumability
Keep the source of truth in a single **updatable, idempotency-marked ticket comment** (see
`references/state-schema.md`) — a JSON code block tagged `<!-- ship-ticket:state -->`.
Reload it at the start of every run so `/clear`, a crash, or another machine reads the real state.
On resume: find the branch/PR, read the state comment, and **continue** — never duplicate a branch,
PR, or comment. Update the existing comment (match the marker); never spam new ones.

**The scratchpad is session-scoped — never a durable home.** A fresh session gets a *different*
scratchpad dir and cannot read another session's files. So anything needed for resume — the state
JSON **and the full plan** (see P1) — lives in **ticket comments**, not scratchpad. A
`scratchpad/<ticket>-ship-state.json` mirror is a local cache only. (On the first run the plan was
written only to scratchpad and nearly lost on hand-off — post it to the ticket.)

**Checkpoint discipline (not just crash-resume):** refresh the `<!-- ship-ticket:state -->` comment
**after every committed slice** — new `last_verified` SHA, what's done, what remains. Then *any*
pause (planned hand-off, long run, `/clear`, crash) resumes cleanly from the latest checkpoint, not
just from a crash.

**Per-ticket lock:** the state comment carries `lock: {owner_sha, ts}`. Reclaim a lock only if you
can prove you own it (matching commit lineage) or it exceeds the TTL (default 45 min). No naked
"acquire" — a dead agent must never deadlock the resume.

## The fix counter (cost control)
One **per-ticket** counter (default cap **6**), incremented on **every** fix attempt across
P2/P3a/P4/P6. **Write-before-act:** increment and persist to the state comment *before* the costly
action it guards (commit/push), with an `in_flight` marker; on resume treat `in_flight` as
**consumed** (never a free retry). On hitting the cap **or** a per-phase sub-cap (2 for
implement→verify, 3 for the PR loop): **halt auto-fixing**, write the reason + last-good commit to
the state comment, and hand off to the human. No "try harder."

---

## Phases

### P0 — Intake & context (the only interactive step up front)
1. Load the ticket (`gh issue view <#> --json number,title,body,labels`). If inline, offer to create
   the ticket first (`AIA-0XXX` title, `bug`/`feature` label, add to board #1).
   **Umbrella/epic tickets** (an `epic` label + a `- [ ] #NNN` task-list): confirm the scope for
   *this* run (which children — ask in P0 if unclear), then treat it as multi-child — commit **one
   slice per child**, reference the child in each commit subject (e.g. `… (#331)`), and **tick the
   umbrella's task-list** as each child lands. The state comment tracks per-child done/pending.
2. Extract acceptance criteria. If absent, infer and **confirm in one line**.
3. **State the risk-category classification explicitly** — high-risk = security/privacy,
   persistence/Core Data, payments/auth, ATS/networking, entitlements, or broad-UI. Surface it for
   the human to acknowledge; never self-assert it (it gates G1).
4. Ask **≤3** clarifying questions — only for decisions the user owns. If specific, infer and state
   assumptions in one line.
5. Decide branch `feature/AIA-XXXX/<slug>`, base `develop`, blast radius, effort.

### P1 — Plan  (Gate **G1**, risk-tiered)
- Draft: steps → per-step verify check, assumptions, known risks.
- Adversarial review: spawn `grill-yourself:grill-master` and a codex second opinion
  (`codex exec -m gpt-5.5 -C <ios> --full-auto -o <out> "…" </dev/null` — redirect stdin or it
  hangs). Auto-apply **only mechanically-obvious** corrections; **surface scope/approach changes**
  for one-line confirmation before P2.
- **Post the full hardened plan as its own `<!-- ship-ticket:plan -->` ticket comment** (plus the
  auto-applied diff) — **not** to scratchpad. Scratchpad is session-scoped; a fresh session resuming
  this ticket must be able to read the plan from GitHub.
- **G1:** default **ON**. Goes **OFF only when, at P0, the human acknowledged BOTH the acceptance
  criteria AND the stated risk classification** (and it isn't a high-risk category). `--plan-gate`
  forces it on.

### P1.5 — Baseline & preflight (before any edit)
- **Baseline:** confirm `develop`/the workspace already builds and the objective sweep is green —
  so later failures aren't misattributed to your diff.
- Validate `DEVELOPER_DIR` (above). Detect a dirty worktree / existing branch / existing PR →
  resume or ask; never overwrite uncommitted user changes. Acquire/verify the lock.

### P2 — Implement (autonomous, commit frequently)
- Create the branch. **Read before editing; surgical changes; match existing style.**
- Commit at logical units (conventions above). Self-correct from build errors.
- **Banned-diff guard before every commit AND every push** — see `references/banned-diff.md`:
  the **deterministic grep block** (ATS keys, secrets, signing, entitlements, feature-flag flips,
  known auth-bypass tokens) **stops and asks**; **semantic** concerns (e.g. test-only behavior
  leaking to production) are raised as an **advisory P4 finding**, not on the hard rail.

### P3a — Objective sweep  ← **THE ONLY GATE**
Deterministic pass/fail, with `DEVELOPER_DIR` set: `build-for-testing` (from `ios/`) →
`./scripts/swiftlint.sh` → `./scripts/harmonize.sh` (both from the **repo root**) → unit tests →
UI tests (from `ios/`, `-testPlan MLBrowserUITests`, non-disrupting sim). Fix→re-verify counts
against the counter.
`--no-ui-tests` drops the UI suite here and triggers the UI-unverified banner (below).

### P3b — Agentic feature check  (ADVISORY — never gates)
Spawn a **code-frozen** verifier sub-agent (drives the app, edits no source). It installs on a
**dedicated `simctl erase`'d** sim (isolated — cannot pollute the P3a sim), drives the feature per
the acceptance criteria via `simctl`/XCUITest, screenshots the success state, and returns
`works | broken | uncertain` + evidence **for the PR body**. Prefer the non-`UI_TESTING` build for
fidelity; bypass-with-label only when a flow is otherwise unreachable. `uncertain` is never
reported as `broken`. Evidence is invalidated by any later commit touching the verified flow.

### P4 — Code review (after cheap checks, before repeating the expensive UI sweep)
- `agent-skills:code-review` (branch mode) + CodeRabbit CLI + codex review.
- **Triage, don't rubberstamp. Classify findings:** correctness / security / test-failure →
  auto-fix; architecture / product / API / scope-expanding → **surface for human approval**.
- Then run the full P3a once.

### P5 — Open PR  ← **GATE G2 (every push = one paid Xcode Cloud build)**
- **Always stop for explicit OK** before the first push/PR. The prompt states "this triggers one
  paid Xcode Cloud build".
- Surface a suggested `ios/TestFlight/WhatToTest.en-US.txt` stanza for the human to apply at PR
  time — do **not** auto-mutate that shared file mid-flow (it conflicts across parallel branches).
- PR body: acceptance criteria + P3b evidence + P3a results + the exact local env
  (Xcode/sim/OS), labeled **"locally verified"** — never presented as CI-green. Include the
  UI-unverified banner if `--no-ui-tests`.

### P6 — PR feedback loop (every push re-gated)
- Poll Copilot + CodeRabbit + CI checks (`gh pr checks`, `gh api …/comments`).
- Address comments **classified as in P4**: fix real issues, reply with the resolution, update the
  PR description for stale claims, decline out-of-scope refactors.
- **Batch** all pending fixes (review + bot comments + CI failures) into **one push per round**;
  **each push is G2-gated** with the paid-build warning. The "push ready fixes rather than idle-poll
  CI" tip applies **only** when the fix is locally verified *and* the CI failure is fully explained
  locally — otherwise batch. Poll CI to green; loop against the counter.

### P7 — Handoff (no autonomous merge)
- Report: PR # state, CI green, P3b evidence, local env, board status → set **In Review**
  (`gh project item-edit … --single-select-option-id ce9bc762`).
- **G3 merge is a separate hard gate — never autonomous.** The merge prompt warns: **"merge into
  `develop` triggers the FULL CI test set — more expensive than a push."** After a human-approved
  merge: close the issue if it didn't auto-close (merging to `develop` doesn't auto-close a
  `Closes #` reference), and set board **Done** (`98236657`).

## Human gates (the whole point)
- **G0** intake questions — only if genuinely ambiguous.
- **G1** plan approval — risk-tiered per P1.
- **G2** every push / PR — **always** (paid CI).
- **G3** merge — **always** (never autonomous).

## Guardrails recap
- Never weaken ATS; never commit secrets; surgical diffs only.
- Two-tier banned-diff guard on every commit and push.
- One per-ticket fix counter (cap 6), write-before-act, on-trip halt+handoff.
- Structured resumable state in the ticket; SHA-scoped verification records
  (`last_verified` / `last_pushed` / `last_ci_green` / `last_verifier_evidence`) invalidated by any
  new commit; idempotency markers; lock with TTL reclaim.
- If a phase fails twice, stop and re-plan — don't grind (mirrors the global CLAUDE.md).
