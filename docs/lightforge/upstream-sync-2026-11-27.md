# Upstream sync plan — wavezync/durable 2.2.0 → lightforge-main (2026-11-27)

Policy: **downstream-only fork.** Lightforge changes are never sent upstream. Goal = smallest
permanent carry set + a sync that repeats as a plain `git merge upstream/main`.

## 1. Current state (verified 2026-11-27)

| Ref | Value |
|---|---|
| upstream `wavezync/durable` main | `a6e4467` — durable 2.2.0, monorepo (`durable/`, `durable_dashboard/`, `site/`) |
| fork `main` | July line; 45 ahead / 472 behind upstream; all content superseded by lightforge-main |
| fork `lightforge-main` | orphan history. `e600e57..a37f6c5` = rewritten projection; `a37f6c5` tree **==** upstream `ad60324:durable/` (2026-06-24). `b7114f7` = Lightforge package tree. +5 admission commits → `c34a7e5` |
| upstream drift since ad60324 | 448 commits, 311 touch `durable/` (1.3 → 2.2.0, includes **2.0.0 breaking**) |
| aegis-durable-engine main | `7c3e5cc`, pins durable `c34a7e5` |
| **Phoenix main mix.lock** | durable **`86aa946`** (only on `backup/lightforge-main-pre-upstream-rebase-20261006` and `feat/sqlite`, not on `lightforge-main`); engine **`64e18c3`** (#45 — before SQLite #46, admission #47/#48) |

Consequence of the Phoenix pin: **admission (`idempotency_key`) and SQLite are not deployed** anywhere
Phoenix runs. Phoenix's `baseline/schema.sql` has no `idempotency_key` column. A bare
`mix deps.update durable` in Phoenix today jumps from 86aa946 to the orphan c34a7e5 line.

## 2. Our delta vs upstream 2.2.0 — keep / adopt-upstream / verify

| Lightforge feature | Upstream 2.2.0 | Decision |
|---|---|---|
| Idempotent admission: `idempotency_key`, fingerprint, unique index (5fd99ac, 6fdf1dc, c34a7e5) | `:key`, `on_duplicate`, `key_scope`, `reuse:`, `return: :details`, `holds_key` index | **Drop ours, adopt upstream.** Not deployed (above) → no data migration. Engine #47 rewritten on `:key`/`key_scope` |
| `retry_count`, `last_retried_at` + `Durable.retry` in place | `retry/2`, `rerun`, `retried_at`, `trigger: :rerun` | **Adopt upstream.** Leave the two Phoenix columns in place (unused); stop writing them |
| `step_executions.session_id` (+ index) | absent | **Carry.** Phoenix `Aegis.Workflows` reads `durable.step_executions` |
| `pending_events.on_timeout` (`:resume`/`:fail`) | wait-group `on_timeout: :fail`, `timeout_value` semantics; no column | **Verify** engine approval/event waits against upstream semantics; carry the column only if a behaviour is missing |
| Pending-event uniqueness hardening (v20260723) | `:buffered` status + event buffering (send before wait) | **Verify**; likely superseded. Keep the applied index unless it conflicts with buffered events (two rows per workflow+event) — **high-risk check** |
| `Durable.pending_waits/1` | removed from public API | Move into engine (query `pending_events`/`pending_inputs`), or carry a 10-line fn |
| Wake poller on start/resume; context persisted on step failure / before wait; normalized errors; `Atom.to_string` module storage; child start gated on host registration | upstream: CommitWaker, attempt fencing, persisted engine_state; module stored as string | **Verify each by test** (our tests replayed on upstream); drop if green |
| SQLite: `Storage.Dialect`, `Migration.Dialect`, `Queue.Adapters.SQLite`, dialect edits in old migrations | absent | **Owner decision (D-1).** Largest carry: every upstream query/migration since June (claims, key holders, `FOR UPDATE`, claim/kept-lock indexes, node registry) needs a SQLite path, again on every sync |
| Elixir 1.20/OTP 29 type fixes | upstream `~> 1.15`, warnings-clean under credo strict | Re-run `--warnings-as-errors` on 1.20 after merge; keep only fixes still needed |

Target carry set if D-1 = drop SQLite: **session_id + pending_waits + whatever §2 verification
proves missing.** That's a few hundred lines rather than 15k.

## 3. Branch strategy (replaces the projection approach)

1. Back up: push `backup/main-20261127` (fork main), `backup/lightforge-main-20261127`.
2. Fork `main` := `upstream/main` (force). Pure mirror from now on; GitHub "Sync fork" works.
3. lightforge-main adopts upstream's **monorepo layout**, with our package under `durable/`:
   - one-time graft commit: parents `ad60324` (upstream) + `c34a7e5` (lightforge-main), tree =
     upstream `ad60324` with `durable/` = our tree. Merge base for later merges = upstream history.
   - `git merge upstream/main` → resolve (28 files in the trial; executor.ex 23 hunks).
   - every later sync is `git merge upstream/main`. No projection, no rewritten history.
4. Consumers add `sparse: "durable"`: Phoenix ×3 apps (`aegis_platform`, `aegis_company`,
   `aegis_web` mix.exs) and engine `durable_dep/0`. Pin by `ref:` (not `branch:`) so lock and
   branch can't drift apart again (the 86aa946 problem).
5. `durable_dashboard/` comes along unused; leave it out of deps.

## 4. Impact — aegis-durable-engine

| Area | Change |
|---|---|
| **Postgres DDL** | Engine hand-writes the `durable` schema (`AegisDurableEngine.Migration.up_postgres`) and doesn't use Durable's migrator. Port upstream's 11 migrations (v20261016 operator controls/nodes, deadlines+history/activity, workflow keys, schedule keys+tags, claim index, ready order+schedule source, root_workflow_id, engine_state, kept-lock index, node clock skew, key scopes) as idempotent `add_*` helpers + update `up_postgres` for fresh installs. **Biggest engine item.** Index builds on `workflow_executions` block inserts → `CONCURRENTLY` in Phoenix migrations |
| SQLite path | `Migration.SQLite` calls `Durable.Migration.up/0`. Breaks if D-1 drops SQLite; otherwise needs dialect for all new migrations |
| Admission (#47) | Rewrite `scoped_idempotency_key` → `key:` + `key_scope:` (org-scoped), map `{:error, {:key_taken, id}}` / `:key_contended`; drop `add_idempotent_workflow_start` (never shipped to Phoenix) |
| `pending_waits/2` | Reimplement (§2) |
| 2.0 breaking | read fns return `{:ok,_}`/`{:error,_}` + `!` twins; parallel blocks must be named (engine `helpers.ex` emits `parallel do`); **failed run no longer auto-compensates** — engine has 21 `compensate` references; callers must call `Durable.rollback/2` explicitly where they relied on it |
| New status values | step `:cancelled`, `:snoozed`; event `:buffered` — check engine pattern matches |
| Tests | engine suite on its own Postgres (and SQLite if kept) at new pin; receipt per repo rules |

## 5. Impact — aegis-api-phoenix

| Area | Change |
|---|---|
| Deps | 3 mix.exs: `sparse: "durable"`, `ref:` pin; lock bump of durable + engine **together** (the engine jumps 64e18c3 → post-#48 at the same time: SQLite #46 + admission #47 + this port) |
| Migrations | new host migration calling the engine's upgrade helpers; update `apps/aegis_core/priv/repo/baseline/schema.sql` (durable.* tables + new `nodes`, activity/history tables) |
| Raw SQL on `durable.*` | `Aegis.Workflows` (step_executions ×2), `RequirementWorkflow` (workflow_executions), `WorkflowScheduleFireReconciler`, `AegisWeb.CompanyWork.WorkflowParts` (status mapping), `E2eController` INSERT. New NOT NULL columns all have defaults → INSERT ok; status mappers need the new step/event values |
| New runtime processes | NodeRegistry (heartbeat rows per node), Sampler, CommitWaker, Drainer (`shutdown_grace_period` 15s — check against the release's stop timeout and the 2-node Apple cluster/Horde handoff); Pruner off unless `prune:` set — keep off |
| Config | `config :durable` keys: `:queue_enabled` still valid; review `node_id`, `shutdown_grace_period`, queue `poll_interval` |
| Deps added by upstream | `opentelemetry_api`, `telemetry_metrics` (runtime), `stream_data`/`ex_slop` (dev/test) — Phoenix already has OTel; check version solve |
| Live DBs | dev cluster (Apple), Fly aegis-company, e2e harness images: migrations are additive (new columns w/ defaults, new tables, new indexes). Run index builds `CONCURRENTLY`; rollback = drop added objects |
| E2E | workflow scenarios (RequirementWorkflow, rerun API, scenario 67) are the acceptance gate — Hugo/owner only |

## 6. Gaps to close before resolving the merge

1. **D-1 SQLite:** keep (permanent heavy carry) or drop (engine #46 desktop hosts lose SQLite).
2. Which current Lightforge behaviours does upstream 2.2.0 already cover? Answer by running our durable tests (`idempotent_start`, `wait`, `concurrency`, context/retry/timeout suites) against upstream 2.2.0 + session_id → failing tests = real carry list.
3. Pending-event uniqueness index vs upstream `:buffered` events — confirm no duplicate-row conflict on a DB that already has the index.
4. Engine compensation reliance under 2.0 "failed run is left as it failed".
5. Drainer/NodeRegistry behaviour on the 2-node dev cluster and Fly (node ids, clock-skew table).
6. Phoenix lock drift: fix now, independent of the sync — pin `ref: 86aa946…` explicitly so a deps update can't silently jump lines.

## 7. Order of work

1. (now, small) Phoenix: pin durable by `ref` (gap 6). Backups + fork `main` mirror reset.
2. Gap 2 test run → final carry list. D-1 decision.
3. lightforge-main: graft + merge upstream (monorepo layout), carry set only; durable tests green.
4. Engine: DDL port, admission on `:key`, 2.0 API, `pending_waits`; engine tests green.
5. Phoenix: deps + host migration + baseline + raw-SQL status fixes; `mix test`; then Hugo runs workflow e2e.
6. Rollout: dev cluster → Fly; `CONCURRENTLY` indexes.
