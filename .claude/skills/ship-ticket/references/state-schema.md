# ship-ticket state

Source of truth = one **updatable** comment on the ticket, tagged so resume can find and update it
(never duplicate). Post/refresh it as a fenced json block inside an HTML-comment marker (shown here
with a 4-backtick outer fence so the inner 3-backtick block renders literally):

````
<!-- ship-ticket:state -->
```json
{ ...state... }
```
<!-- /ship-ticket:state -->
````

On every run: `gh issue view <#> --json comments` → find the marker → parse → continue. Update the
**same** comment id (`gh api …/comments/<id> -X PATCH`). A local
`scratchpad/<ticket>-ship-state.json` mirror is a cache only and must be gitignored.

## Schema

```json
{
  "version": 2,
  "ticket": 362,
  "branch": "feature/AIA-0362/finding-save-validation",
  "base": "develop",
  "pr": 371,
  "phase": "P6",
  "risk_high": false,
  "g1_waived": true,
  "fix_count": 3,
  "fix_cap": 6,
  "in_flight": null,
  "steps": [
    { "id": "s1", "desc": "FeatureFlags + gate flash", "status": "done",        "executor_attempts": 1 },
    { "id": "s2", "desc": "unit tests",                "status": "in_executor", "executor_attempts": 2 }
  ],
  "lock": { "owner_sha": "e8e1ddb…", "ts": "2026-07-01T00:29:29Z", "ttl_min": 45 },
  "verification": {
    "last_verified":         "e8e1ddb…",
    "last_pushed":           "e8e1ddb…",
    "last_ci_green":         "e8e1ddb…",
    "last_verifier_evidence":"95936bd…"
  },
  "notes": "banned-diff false-positive acked: git -c commit.gpgsign=false (1Password locked)"
}
```

## Field rules
- **`in_flight`** — set to the intended action (`"push"` / `"commit"` / `"executor:<step-id>"`)
  *and persist* **before** the action — a push, a commit, an executor dispatch **or a SendMessage
  retry**; clear it after the action + its post-state are recorded. On resume a non-null
  `in_flight` is treated as **consumed** (the counter/attempt already incremented — no free
  retry). For `executor:<step-id>`: uncommitted worktree dirt is executor debris — inspect, then
  `git stash push -u -m "ship-ticket:<step-id> resume-debris"`.
- **`steps[]`** — one entry per plan step: `status` ∈
  `pending | in_executor | done | escalated | halted`, `executor_attempts` (max 2, bumped
  write-before-act, including before a SendMessage retry). A halt records the killing step's id in
  the halt reason. Cleanup stashes are machine-local — durable state never references one.
- **`fix_count`** — incremented on every orchestrator fix→re-verify cycle across
  P2(inline escalations)/P3a/P4/P6, write-before-act; **executor attempts are excluded** (see
  `steps[]`). An increment that would exceed `fix_cap` (or a per-phase sub-cap: 2 implement→verify,
  3 PR loop) **halts instead of acting**. Re-planning never resets it.
- **`verification.*`** — commit SHAs. **Any new commit invalidates every record whose SHA is now an
  ancestor-not-tip**: re-verify before treating a downstream claim (CI-green, verifier evidence) as
  current. Never present `last_ci_green` as valid for a newer HEAD.
- **`lock`** — reclaim only if `owner_sha` is in your commit lineage or `ts` is older than
  `ttl_min`. Otherwise a second run must stop and ask.
- **`g1_waived`** — true only when the human acknowledged both the acceptance criteria and the
  stated risk classification at P0 (and `risk_high` is false).
