---
name: ship-ticket
description: >
  Autonomously drive a GitHub ticket (or an inline description) to a green, locally-verified PR
  for the ML Browser iOS app — plan, adversarial plan review, implement with frequent commits,
  local verify (objective sweep, code review, advisory agentic check), open PR, address
  Copilot/CodeRabbit comments, poll CI to green — pausing only at a short upfront Q&A and the two
  irreversible/cost gates (every push, every merge). Use when the user says "ship this ticket",
  "take AIA-0XXX to a PR", "/ship-ticket <issue#>", or hands you a ticket to implement end-to-end.
allowed-tools: [Bash, Read, Edit, Write, Grep, Glob, Task, Agent, SendMessage, AskUserQuestion]
---

# ship-ticket — autonomous ticket → testable PR

You are a **thin orchestrator + fixer**. You compose existing skills (the native `/code-review`,
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
- **Sims (discover by name — never hardcode UDIDs; they are machine-specific):** tests run on a
  dedicated sim named **`ship-ticket-runner`**; the P3b advisory verifier uses its **own**
  **`ship-ticket-verifier`** (`simctl erase`'d each run). Resolve each at runtime:
  `xcrun simctl list devices available -j` → device with that exact name on the **newest** iOS
  runtime; if absent, create it (`xcrun simctl create <name> <newest iPhone devicetype>
  <newest iOS runtime>`). **"Newest iPhone devicetype" = the supported iPhone with the highest
  `minRuntimeVersion`** — neither `simctl list devicetypes` order nor a runtime's
  `supportedDeviceTypes` order is recency-sorted (learned on AIA-0374: naive "last item"
  picks iPhone 6s Plus / iPhone 11). Durable state (the ticket comment) records only the sim **name +
  runtime** — never a UDID (machine-specific; goes stale on resume). Re-resolve the UDID
  fresh at runtime on every run/resume.
  **Never launch on any other `Booted` sim** — a booted sim you didn't create is the user's.
  If no iOS simulator runtime is installed, **stop and tell the user**
  (`xcodebuild -downloadPlatform iOS`) — don't improvise a destination.
- **UI tests:** require `-testPlan MLBrowserUITests` (the scheme default excludes them).
  `SIMCTL_CHILD_UI_TESTING=1` activates the DEBUG mock auth/subscription providers (bypasses
  auth/paywall) — it also wipes the Caches Core Data store, so it is a *different* path than
  production; only use it when a flow is otherwise unreachable, and label it in evidence.
- **Commits:** subject prefixed `[AIA-XXXX]` (or `[AIA-XXXX, AIA-YYYY]`), imperative summary,
  short why-body — ios/AGENTS.md §13; no co-author footnote. If 1Password is locked (signing/SSH fail), fall back to
  `git -c commit.gpgsign=false commit …` and push via the `gh`-credentialed HTTPS remote.
- **Branch/issue:** `<type>/AIA-XXXX/<slug>` with `<type>` ∈ `feature|fix|doc|test` chosen by
  change type (ios/AGENTS.md §13), base `develop`. Title issues `AIA-0XXX: …`.
  Add to project board #1 (owner `aiarcheology-com`); Status field `PVTSSF_lADODw8uZM4BMCyNzg7cGQI`,
  options: In Review `ce9bc762`, Done `98236657`.
- **Pre-push gate mirrors CI:** `./scripts/swiftlint.sh` + `./scripts/harmonize.sh` (both run
  **from the repo root**, not `ios/`) + unit + UI tests.
- **Tool resolution:** before concluding a tool is missing from a bare `which <bin>`, check how the
  repo's wrapper resolves it. `scripts/swiftgen.sh` in particular probes **bundled** locations
  (SwiftGen at `~/.local/lib/swiftgen/bin`, also `/tmp/swiftgen/bin`, `/opt/homebrew/bin`, then PATH)
  and supports `--verify` — so `which swiftgen` returns nothing yet it's installed (a false blocker
  on the first run). (`swiftlint.sh` / `harmonize.sh` expect their tool on PATH via `command -v`.)
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
One **per-ticket** counter (default cap **6**), incremented on **every** fix→re-verify cycle
across P2 (inline escalations)/P3a/P4/P6 — **regardless of whether the orchestrator or an `opus`
executor writes the fix** (model-independent accounting). The only spend outside the counter is
the P2 per-step *implementation* budget (see Model routing). The counter is persisted as two
named buckets of **spent** cycles — `fix_buckets.implement_verify` (P2 escalations + P3a + P4,
sub-cap **2**) and `fix_buckets.pr_loop` (P6, sub-cap **3**); remaining budget = sub-cap − spent,
and `fix_count` always equals the sum of the buckets. The global cap 6 is a defensive backstop
above them (buckets bind first; normal spend maxes at 5).
**Write-before-act:** exactly **one increment per fix→re-verify cycle — never per commit**;
persist it to the state comment *before* the cycle's guarded action (its commit/push), with an
`in_flight` marker; on resume treat `in_flight` as **consumed**
(never a free retry) and **reconcile against reality before retrying** (`git log` /
`git ls-remote`: if the action already landed, record its post-state and clear the marker —
never blind-retry). **Trip semantics: an increment that would exceed its bucket's sub-cap or the
global cap halts instead of acting** — write the reason + killing step + last-good commit to the
state comment and hand off to the human. Re-planning never resets any counter. No "try harder."

## Model routing — capable orchestrator, cheap executors
This skill assumes the session runs a top-tier model (e.g. Fable) as the **orchestrator**: it keeps
the whole-ticket context and owns every judgment call — plan, triage, diff review, gates, git, the
state comment. Token-heavy mechanical work goes to **executor subagents on a cheaper model**:
spawn via the Agent tool **with an explicit `model: opus` override** — an omitted `model` silently
inherits the session model and the delegation saves nothing. (The skill cannot change the session
model itself — that's the user's `/model` choice; if the session already runs a cheaper model, the
override is harmless.)

**Routing decision per edit, in order:** (1) security or subtle-correctness work → orchestrator
inline; (2) trivial mechanical edit (single file, no logic — a contract-conformant spawn costs
more than the edit) → orchestrator inline, *even when it is a plan step*; (3) everything else →
`opus` executor. Executors are always `opus`, never `haiku`. **Accounting is model-independent** —
a repair cycle costs the same fix-counter increment whether the orchestrator or an executor
writes it.

| Work | Runs as | Model |
|-|-|-|
| P0/P1 intake, plan, assumptions | orchestrator | session |
| P1 grill-master review | subagent | inherit session (adversarial review needs the capable model) |
| P2 write code (one executor per plan step) | executor | `opus` |
| P2 diff review, banned-diff guard, commits | orchestrator | session |
| P3a sweep | orchestrator Bash (background) | — |
| P3a/P4/P6 **mechanical** fix attempts | executor | `opus` |
| P4 security / subtle-correctness fixes | orchestrator | session |
| P4 `/code-review` skill | orchestrator (a Skill invocation can't be model-overridden) | session |
| P3b sim-driving verifier | subagent | `opus` |
| P4 review triage, P5–P7 gates/PR/state | orchestrator | session |

**Mechanical** = lint/format autocorrect, deterministic test failures with an obvious local cause,
renames/moves. Security findings and subtle-correctness fixes stay orchestrator-inline (the
capable model owns judgment) and count against the fix counter as before.

**Implementation/repair executor contract** — applies to P2 plan-step and P3a/P4/P6
mechanical-fix executors only; the P3b verifier (code-frozen) and grill-master (read-only review)
are *not* executors and follow their own phase contracts:
- One executor per **plan step/slice**, clustered by domain — never one per file. The ~5–10 cap
  applies to P2 implementation executors (fix executors are bounded by the fix counter, the
  verifier by P3b occurrences).
- **Sequential, always.** Executors share one worktree/branch; concurrent runs collide on
  DerivedData, `project.pbxproj` (any file-adding step edits it), and the test sim — and parallel
  edits destroy per-step `git diff` attribution.
- Self-contained prompt =
  1. the step's goal + acceptance check, plus any plan context only the orchestrator knows;
  2. exact files/areas;
  3. a fixed **environment preamble**: the resolved `DEVELOPER_DIR` value (with export
     instruction), `cd ios/`, and the exact build/test command incl. the runtime-resolved
     `ship-ticket-runner` destination (a resolved UDID is fine *within* one run — only durable
     state bans UDIDs);
  4. conventions **by reference, not by value** — name the paths/sections (`ios/AGENTS.md`
     relevant sections; this skill's "Project conventions" block) and require the executor to
     Read them. Never hand-copy them: opus input tokens are cheap, orchestrator output tokens
     are not;
  5. output rules: "final response < 2000 chars; outcomes not process; list files touched,
     verify result, anything surprising".
- Executors **edit, build, and run the step's scoped unit tests** (`-only-testing:…`) — never the
  UI suite, never any sim other than the one in the preamble; never commit, push, edit the state
  comment, or spawn sub-subagents.
- **Per-step attempt budget: 2** (initial + one retry), tracked as `steps[].executor_attempts` in
  the state comment, **write-before-act** — persist the bump before the dispatch *or* the
  SendMessage retry; a crash mid-attempt must never grant a free retry. Only P2
  **implementation** attempts live outside the fix counter (first attempts are never "fix
  attempts"); a P3a/P4/P6 **repair** dispatch is a fix→re-verify cycle and increments the counter
  like any other — otherwise cheap executors would make the cost cap unreachable-by-loop.
- **Two retry paths — never resume an executor across a worktree reset:**
  - *build/test failure, worktree intact* → **SendMessage the same executor** with the exact
    error output (its context already holds the files — cheapest); if it can't be resumed,
    dispatch a fresh one whose prompt adds the error output and the prior attempt's diff;
  - *drift rejection* → the orchestrator stashes the debris
    (`git stash push -u -m "ship-ticket:<step-id> rejected"` — full-tree, recoverable) and
    dispatches a **fresh** executor whose prompt carries the rejection reason + "worktree was
    reset — re-read files before editing". (Stashes are machine-local; acceptable — by the
    commit-per-accepted-step invariant a stash only ever holds rejected debris, and durable
    state never references one.)
- The orchestrator reviews every result (`git diff`) against the plan step before committing;
  an accepted step is **committed immediately** (per-step attribution + a free checkpoint).
- **Escalation:** a step that exhausts its 2 executor attempts goes orchestrator-inline; each
  inline fix cycle increments the fix counter (write-before-act). **Trip semantics: an increment
  that would exceed the sub-cap halts instead of acting.** Worked example: step fails 2 executor
  attempts (per-step budget, outside `fix_count`) → inline attempt #1 = `fix_count` 1 → fails →
  inline attempt #2 = `fix_count` 2 → fails → the would-be third increment exceeds sub-cap 2 →
  halt + handoff; state records the killing step. Escalated steps share the phase budget (step A
  inline = 1, step B inline = 2, any further escalation halts). Re-planning **never** resets the
  counter.

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
5. Decide branch `<type>/AIA-XXXX/<slug>` (type per conventions), base `develop`, blast radius,
   effort.

### P1 — Plan  (Gate **G1**, risk-tiered)
- Draft: steps → per-step verify check, assumptions, known risks.
- Adversarial review: run the local `grill-yourself` skill (grill-master subagent, multi-round
  to consensus; escalations land in the G1 prompt) and a codex second opinion
  (`codex exec -m gpt-5.6-terra -c model_reasoning_effort="xhigh" -C <ios> --full-auto -o <out> "…" </dev/null`
  — redirect stdin or it
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
  resume or ask; never overwrite uncommitted user changes. **Read the state comment before judging
  dirt:** if `in_flight` is `executor:<step-id>`, the uncommitted diff is executor debris —
  inspect, then `git stash push -u -m "ship-ticket:<step-id> resume-debris"`; only unexplained
  dirt is treated as user work (stop and ask). Acquire/verify the lock.

### P2 — Implement (orchestrated, commit frequently)
- Create the branch. **Delegate each plan step to an `opus` executor per the executor contract
  in "Model routing"** (steps caught by the inline routing rules — security/subtle-correctness or
  trivial mechanical — stay orchestrator-inline). The executor prompt carries "read before editing;
  surgical changes; match existing style", the step's verify check, and the environment preamble.
- The orchestrator reviews each returned diff against the plan step, runs the banned-diff guard,
  and **commits each accepted step immediately** (conventions above). Failures and rejections
  follow the contract's two retry paths; a step that exhausts its 2 executor attempts escalates
  inline per the contract's trip semantics.
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
- **Run the build/test steps SEQUENTIALLY — never two `xcodebuild` invocations against the same
  DerivedData at once.** Concurrent builds race the SPM `SourcePackages/artifacts` and corrupt
  them; the loser fails with `error: There is no XCFramework found at
  …/sentry-cocoa/Sentry.xcframework` and **exit 65 with 0 tests run**. That is a *toolchain*
  failure, **not** a diff failure — never misattribute it to your change and never spend a
  fix-counter cycle on it. It bites most easily when `harmonize.sh` (which builds) runs in the
  foreground while a background `build-for-testing`/`test` hits the **default** DerivedData at the
  same time — so serialize them, or give each its own `-derivedDataPath`. Recovery once corrupted:
  re-run the failed build **alone** into a **fresh pinned `-derivedDataPath`** (e.g. under scratch)
  so package resolution + build share one clean location. A bare `-resolvePackageDependencies` may
  resolve into a *different* DerivedData folder and leave the corrupted one untouched, so it is not
  a reliable fix on its own.

### P4 — Code review (after the objective sweep; P3b and any repeat UI sweep come after)
- Native `/code-review` skill (review the branch diff) + CodeRabbit CLI (if installed;
  skip with a note in the PR body if not) + codex review (same model/effort as P1:
  `-m gpt-5.6-terra -c model_reasoning_effort="xhigh"`).
- **Triage, don't rubberstamp. Classify findings:** correctness / security / test-failure →
  auto-fix; architecture / product / API / scope-expanding → **surface for human approval**.
- Then re-run the full P3a **only if P4 changed HEAD** — an unchanged HEAD keeps its green (the
  UI suite is the most expensive local step; never repeat it for a no-op review).
- Finally, write the tester-facing `ios/TestFlight/WhatToTest.en-US.txt` stanza — **mandatory**
  (ios/AGENTS.md §13: "no PR without it"); scoped to this change, concrete steps, no dev jargon —
  and **commit it as the final slice**. HEAD is now final: P3b evidence and the G2 OK both bind
  to it (a WhatToTest commit *after* P3b would invalidate the evidence it just minted).
  Conflicts in this small shared file resolve normally at rebase; never exempt it.

### P3b — Agentic feature check  (ADVISORY — never gates; runs here, after P4, right before P5)
Spawn a **code-frozen** verifier sub-agent (`model: opus` — advisory work doesn't need the session
model; drives the app, edits no source). It installs on a
**dedicated `simctl erase`'d** sim (isolated — cannot pollute the P3a sim), drives the feature per
the acceptance criteria via `simctl`/XCUITest, screenshots the success state, and returns
`works | broken | uncertain` + evidence **for the PR body**. Prefer the non-`UI_TESTING` build for
fidelity; bypass-with-label only when a flow is otherwise unreachable. `uncertain` is never
reported as `broken`. Evidence is **SHA-scoped like every verification record: any later commit
invalidates it** (one rule, matching the state schema — no flow-scoped judgment calls). That is
why P3b sits *after* P4 and its conditional P3a rerun, immediately before P5: evidence is minted
at the PR HEAD. In P6, re-runs stay bounded to one per push round.

### P5 — Open PR  ← **GATE G2 (every push = one paid Xcode Cloud build)**
- HEAD is already final here: the WhatToTest slice was committed at the end of P4 and P3b
  evidence is minted on it. **Stop for explicit OK** before the first push/PR. The prompt states "this triggers one
  paid Xcode Cloud build". Record the OK as `g2_ok: {sha, ts}` in the state comment — an approval
  binds to that exact HEAD SHA; any new commit voids it and requires a fresh OK (G2 re-asks
  before every push regardless; the record exists so a resumed run never pushes on a stale
  approval).
- PR body: acceptance criteria + P3b evidence + P3a results + the exact local env
  (Xcode/sim/OS), labeled **"locally verified"** — never presented as CI-green. Include the
  UI-unverified banner if `--no-ui-tests`.

### P6 — PR feedback loop (every push re-gated)
- Poll Copilot + CodeRabbit + CI checks (`gh pr checks`, `gh api …/comments`).
- Address comments **classified as in P4**: fix real issues, reply with the resolution, update the
  PR description for stale claims, decline out-of-scope refactors.
- At most **one P3b re-run per push round** (advisory evidence, not a gate — don't let cheap
  re-runs become unbounded). Update WhatToTest in the same round when the materially changed PR
  needs new tester instructions — commit it *before* that round's P3b re-run and G2 OK.
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
- Executors (cheap-model subagents) never commit, push, or touch the state comment; every
  executor diff is orchestrator-reviewed before commit.
- One per-ticket fix counter (cap 6), write-before-act, on-trip halt+handoff.
- Structured resumable state in the ticket; SHA-scoped verification records
  (`last_verified` / `last_pushed` / `last_ci_green` / `last_verifier_evidence`) invalidated by any
  new commit; idempotency markers; lock with TTL reclaim.
- Prefer re-planning over grinding when a phase keeps failing — but a bucket/cap trip always
  halts + hands off, and re-planning never resets counters (mirrors the global CLAUDE.md).
