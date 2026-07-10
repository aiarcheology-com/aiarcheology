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
  "fix_buckets": { "implement_verify": 2, "pr_loop": 1 },
  "g2_ok": { "sha": "e8e1ddb…", "ts": "2026-07-01T00:25:00Z" },
  "in_flight": null,
  "halt": null,
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
  `git stash push -u -m "ship-ticket:<step-id> resume-debris"`. For `"push"` / `"commit"`:
  **reconcile before retrying** — check `git log` / `git ls-remote` for whether the action
  already landed; if it did, record its post-state and clear the marker instead of re-acting.
- **`steps[]`** — one entry per plan step: `status` ∈
  `pending | in_executor | done | escalated | halted`, `executor_attempts` (max 2, bumped
  write-before-act, including before a SendMessage retry). Cleanup stashes are machine-local —
  durable state never references one.
- **`halt`** — `null` while running. On any cap/bucket trip set `{reason, step_id, ts}` (the
  dedicated home of the halt reason + killing step). A non-null `halt` on resume means the run is
  handed off: do **not** auto-fix; report and wait for the human.
- **`fix_count` / `fix_buckets`** — every fix→re-verify cycle increments its bucket
  (`implement_verify`: P2 escalations + P3a + P4, sub-cap 2; `pr_loop`: P6, sub-cap 3) **and** the
  total, write-before-act, **whether the orchestrator or an executor writes the fix**. Buckets
  store **spent** cycles (remaining = sub-cap − value); invariant: `fix_count ==
  implement_verify + pr_loop`, maintained on every write and checked on resume. Only the P2
  per-step implementation budget (`steps[].executor_attempts`) is excluded. An increment that
  would exceed a bucket sub-cap or `fix_cap` **halts instead of acting**; `fix_cap` is a backstop
  above the buckets (they bind first). Re-planning never resets anything.
- **`g2_ok`** — the last G2 approval, `{sha, ts}`. An approval binds to that exact HEAD SHA; any
  new commit voids it. G2 re-asks before every push regardless — this field exists so a resumed
  run never pushes on a stale approval.
- **`verification.*`** — commit SHAs. **Any new commit invalidates every record whose SHA is now an
  ancestor-not-tip**: re-verify before treating a downstream claim (CI-green, verifier evidence) as
  current. Never present `last_ci_green` as valid for a newer HEAD.
- **`lock`** — reclaim only if `owner_sha` is in your commit lineage or `ts` is older than
  `ttl_min`. Otherwise a second run must stop and ask.
- **`g1_waived`** — true only when the human acknowledged both the acceptance criteria and the
  stated risk classification at P0 (and `risk_high` is false).

## Version migration
- **v1 → v2** (idempotent; run before any executor dispatch): reconstruct `steps[]` from the
  `<!-- ship-ticket:plan -->` comment — a step whose slice is already committed on the branch is
  `done`; anything uncertain is `pending` with `executor_attempts: 0` (conservative: a lost count
  costs one cheap re-dispatch, never a skipped verification). Split the v1 scalar `fix_count`
  into buckets by filling `implement_verify` first (up to its sub-cap), remainder to `pr_loop`.
  The remainder may exceed `pr_loop`'s sub-cap when the v1 run was already at/near the global
  cap — keep it, never clamp (the `fix_count == sum` invariant wins): trip semantics already
  guarantee the next increment halts + hands off.
  `g2_ok` starts `null` (forces a fresh G2 — never assume a stale approval). Persist the migrated
  comment (bump `version`) before continuing.
- **Version > 2:** stop and ask the human — never guess forward-compatibility.
