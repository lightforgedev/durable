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
| **connect-phoenix main** | durable **`d0c24e7`** (`feat/sqlite`; tree == lightforge-main `b7114f7` except ci.yml — SQLite, no admission), engine **`dd4ade1`** (engine `feat/sqlite`; engine main differs by 3 lib files). SQLite-only: `config :durable, schema_prefix: nil` (compile-time), WAL, `:immediate` transactions, 6+ queues at 100–500 ms poll |
| **Phoenix main mix.lock** | durable **`86aa946`** (only on `backup/lightforge-main-pre-upstream-rebase-20261006` and `feat/sqlite`, not on `lightforge-main`); engine **`64e18c3`** (#45 — before SQLite #46, admission #47/#48) |

Consequence of the pins: **admission (`idempotency_key`) is deployed nowhere** (Phoenix and connect-phoenix both predate it). **SQLite is live in connect-phoenix** (Connect host `$AEGIS_CONNECT_HOME/workflows.sqlite3`), not in Phoenix. Phoenix's `baseline/schema.sql` has no `idempotency_key` column. A bare
`mix deps.update durable` in Phoenix today jumps from 86aa946 to the orphan c34a7e5 line.

## 2. Our delta vs upstream 2.2.0 — keep / adopt-upstream / verify

| Lightforge feature | Upstream 2.2.0 | Decision |
|---|---|---|
| Idempotent admission: `idempotency_key`, fingerprint, unique index (5fd99ac, 6fdf1dc, c34a7e5) | `:key`, `on_duplicate`, `key_scope`, `reuse:`, `return: :details`, `holds_key` index | **Adopt upstream `:key` as the storage mechanism; keep #47's semantics in the engine.** Upstream `key_scope` is workflow-definition scope, not per-start org scope, and `:use_existing` does not reject a reused key with changed input. So: upstream `key:` = the existing org + workflow + caller-key digest; start with `return: :details` and resolve the duplicate path by holder identity; compare a persisted canonical request fingerprint so changed input still returns `:idempotency_conflict`. Never deployed → no data migration |
| `retry_count`, `last_retried_at` + `Durable.retry` in place | `retry/2`, `rerun`, `retried_at`, `trigger: :rerun` | **Adopt upstream.** Leave the two Phoenix columns in place (unused); stop writing them |
| `step_executions.session_id` (+ index) | absent | **Carry.** Phoenix `Aegis.Workflows` reads `durable.step_executions` |
| `pending_events.on_timeout` (`:resume`/`:fail`) | wait-group `on_timeout: :fail`, `timeout_value` semantics; no column | **Verify** engine approval/event waits against upstream semantics; carry the column only if a behaviour is missing |
| Pending-event uniqueness hardening (v20260723) | `:buffered` status + event buffering (send before wait) | **Adopt upstream index; retain it on upgrade.** Upstream 2.2 creates the same partial uniqueness invariant (`status = 'pending' AND wait_type = 'single'`); `:buffered` rows are excluded, so no conflict. Tests: send-before-wait, and an upgrade DB that already has our v20260723 index |
| `Durable.pending_waits/1` | removed from public API | Move into engine (query `pending_events`/`pending_inputs`), or carry a 10-line fn |
| Wake poller on start/resume; context persisted on step failure / before wait; normalized errors; `Atom.to_string` module storage; child start gated on host registration | upstream: CommitWaker, attempt fencing, persisted engine_state; module stored as string | **Verify each by test** (our tests replayed on upstream); drop if green |
| SQLite: `Storage.Dialect`, `Migration.Dialect`, `Queue.Adapters.SQLite`, dialect edits in old migrations | absent | **Carry — required (D-1 resolved 2026-11-27: used by connect-phoenix).** Largest carry. Upstream Postgres-specific surface grew since June: `fragment(` 5→80, advisory locks 0→6, `text[]`/`ANY(` 0→6 (tags, key_scope), jsonb 8→25, `ON CONFLICT` 2→6, LISTEN/NOTIFY CommitWaker, `@schema_prefix "durable"` hardcoded in 10 schemas (we need the compile-time `schema_prefix: nil`). Each needs a Dialect path, on every sync |
| Elixir 1.20/OTP 29 type fixes | upstream `~> 1.15`, warnings-clean under credo strict | Re-run `--warnings-as-errors` on 1.20 after merge; keep only fixes still needed |

Carry set: **SQLite dialect layer (incl. compile-time schema prefix) + session_id + pending_waits + whatever §2
verification proves missing.** To keep SQLite cheap across syncs: isolate every dialect branch behind
`Durable.Storage.Dialect` (no inline `if sqlite?` in executor/queue), and run the full durable suite on both
adapters as the sync gate.

## 3. Branch strategy (replaces the projection approach)

1. Back up: push `backup/main-20261127` (fork main), `backup/lightforge-main-20261127`.
2. Fork `main` := `upstream/main` (force). Pure mirror from now on; GitHub "Sync fork" works.
3. lightforge-main adopts upstream's **monorepo layout**, with our package under `durable/`:
   - one-time graft commit: parents `ad60324` (upstream) + `c34a7e5` (lightforge-main), tree =
     upstream `ad60324` with `durable/` = our tree. Merge base for later merges = upstream history.
   - `git merge upstream/main` → resolve (28 files in the trial; executor.ex 23 hunks).
   - every later sync is `git merge upstream/main`. No projection, no rewritten history.
   - **Enforce downstream-only:** local `upstream` remote gets `pushurl = DISABLED`; protect fork
     `main` (mirror) and `lightforge-main`; the mirror reset is a lease-guarded push tied to the
     recorded old fork-main SHA `701c3c6`, run only after the backup branch is verified on the remote.
4. Consumers add `sparse: "durable"`: Phoenix ×3 apps (`aegis_platform`, `aegis_company`,
   `aegis_web` mix.exs) and engine `durable_dep/0`. Pin by `ref:` (not `branch:`) so lock and
   branch can't drift apart again (the 86aa946 problem).
5. `durable_dashboard/` comes along unused; leave it out of deps.

## 4. Impact — aegis-durable-engine

| Area | Change |
|---|---|
| **Durable migration ledger** | Engine Postgres DDL records only the host Ecto migration in `public.schema_migrations`; 2.2 NodeRegistry checks Durable's schema-local migration ledger. The port must create and seed that ledger with every version the hand-written DDL covers (or provide an equivalent explicit compatibility check); otherwise schema verification is silently lost |
| **Postgres DDL** | Engine hand-writes the `durable` schema (`AegisDurableEngine.Migration.up_postgres`) and doesn't use Durable's migrator. Port upstream's 11 migrations (v20261016 operator controls/nodes, deadlines+history/activity, workflow keys, schedule keys+tags, claim index, ready order+schedule source, root_workflow_id, engine_state, kept-lock index, node clock skew, key scopes) as idempotent `add_*` helpers + update `up_postgres` for fresh installs. **Biggest engine item.** Index builds on `workflow_executions` block inserts → `CONCURRENTLY`, which must run outside the Ecto DDL transaction (`@disable_ddl_transaction true` + `@disable_migration_lock true`, separate migration) |
| SQLite path | `Migration.SQLite` calls `Durable.Migration.up/0`. Breaks if D-1 drops SQLite; otherwise needs dialect for all new migrations |
| Admission (#47) | Keep `scoped_idempotency_key` (org + workflow + caller-key digest) and pass it as upstream `key:`; `return: :details` + holder lookup for duplicates; persisted canonical fingerprint compared on duplicate → `:idempotency_conflict` on changed input; map `:key_contended`. Replace the `idempotency_key` columns/index with upstream key columns + a fingerprint column (never shipped to Phoenix). Tests: concurrent same-input, concurrent different-input, cross-org same caller key |
| `pending_waits/2` | Reimplement (§2) |
| 2.0 breaking | read fns return `{:ok,_}`/`{:error,_}` + `!` twins; parallel blocks must be named (engine `helpers.ex` emits `parallel do`) |
| Compensation | Two separate paths. **Native Durable DSL compensation** is now explicit (`Durable.rollback/2`): audit the actual native-DSL workflow modules (engine, Phoenix, connect-phoenix) that declare `compensate:` and rely on auto-rollback. **Engine declarative runner** runs its own compensation stack and is unaffected by the 2.0 change. The 21 engine `compensate` references are not all `rollback/2` callers |
| New status values | step `:cancelled`, `:snoozed`; event `:buffered` — check engine pattern matches |
| Tests | engine suite on its own Postgres (and SQLite if kept) at new pin; receipt per repo rules |

## 5. Impact — aegis-api-phoenix

| Area | Change |
|---|---|
| Deps | 3 mix.exs: `sparse: "durable"`, `ref:` pin; lock bump of durable + engine **together** (the engine jumps 64e18c3 → post-#48 at the same time: SQLite #46 + admission #47 + this port) |
| Migrations | new host migration calling the engine's upgrade helpers; update `apps/aegis_core/priv/repo/baseline/schema.sql` (durable.* tables + new `nodes`, activity/history tables) |
| Raw SQL on `durable.*` | `Aegis.Workflows` (step_executions ×2), `RequirementWorkflow` (workflow_executions), `WorkflowScheduleFireReconciler`, `AegisWeb.CompanyWork.WorkflowParts` (status mapping), `E2eController` INSERT. New NOT NULL columns all have defaults → INSERT ok; status mappers need the new step/event values |
| Shutdown | Drainer = `shutdown_grace_period` 15 s + 5 s hand-back = 20 s. Fly today: `fly.staging.toml` `kill_timeout = "10s"`, other Phoenix Fly configs default 5 s → set and prove a platform kill timeout above 20 s (e.g. 30 s) on every Fly config plus the release stop timeout; Apple cluster stop timeout likewise. Gate: two-node drain/hand-off test |
| New runtime processes | NodeRegistry (heartbeat rows per node), Sampler, CommitWaker, Drainer; Pruner off unless `prune:` set — keep off |
| Config / node identity | `:queue_enabled` still valid. `node_id` is derived, not a config key → verify unique release node names across both nodes and Fly machines, and stale-node cleanup after replaced machines |
| Deps added by upstream | `opentelemetry_api`, `telemetry_metrics` (runtime), `stream_data`/`ex_slop` (dev/test) — Phoenix already has OTel; check version solve |
| Live DBs | dev cluster (Apple), Fly aegis-company, e2e harness images. Schema changes are additive (new columns w/ defaults, new tables, new indexes) |
| **Mixed-version rollout** | Old and new queue workers must never overlap on one DB: (1) expand schema first (additive migration + ledger seed, `CONCURRENTLY` indexes); (2) drain old workers (`queue_enabled` off / stop); (3) deploy one exact Durable + engine set to both nodes; (4) enable queues. **Rollback is not "drop added objects"**: once 2.2 writes new statuses / `engine_state` / key columns, going back needs a data downgrade or a forward fix — decide which before rollout |
| E2E | workflow scenarios (RequirementWorkflow, rerun API, scenario 67) are the acceptance gate — Hugo/owner only |

## 5b. Impact — aegis-connect-phoenix (SQLite consumer)

| Area | Change |
|---|---|
| Deps | `@durable_rev` / `@durable_engine_rev` in mix.exs → new lightforge-main / engine SHAs; `durable_dep/4` git branch gets `sparse: "durable"` |
| Schema | SQLite migrations run through `Durable.Migration.up/0` via engine `Migration.SQLite` → all 11 upstream migrations must have SQLite forms (arrays → JSON text, partial/unique indexes, no `CONCURRENTLY`, no schemas) |
| Concurrency | Upstream claims use `FOR UPDATE SKIP LOCKED` + advisory locks; SQLite path relies on `:immediate` write lock + `busy_timeout 5000`. Re-check claim/kept-lock/key-holder logic under the single-writer model and short poll intervals (signal_flows 100 ms) |
| Wake | CommitWaker uses Postgres LISTEN/NOTIFY → SQLite needs the in-process wake (single node) |
| Multi-node features | NodeRegistry, clock skew, Drainer: single local node — must start cleanly and not assume Postgres |
| 2.0 breaking | Connect workflows (`Connect.Panels.Refresh`, `Connect.Work.WaiverWait`/`RolloutWait`, signal flows): read-fn tuples, named parallel blocks, explicit rollback |
| Tests | connect-phoenix suite + its flows harness at the new pins |

## 6. Gaps to close before resolving the merge

1. ~~D-1 SQLite~~ **Resolved: keep** (connect-phoenix). Open: engine `feat/sqlite` (dd4ade1) vs engine main — confirm connect-phoenix's 3-file difference is merged or intended before re-pinning.
2. Which current Lightforge behaviours does upstream 2.2.0 already cover? Answer by running our durable tests (`idempotent_start`, `wait`, `concurrency`, context/retry/timeout suites) against upstream 2.2.0 + session_id → failing tests = real carry list.
3. ~~Pending-event index~~ resolved (Hugo): upstream has the same partial invariant; adopt and retain.
4. Native-DSL `compensate:` consumers relying on auto-rollback (audit; engine declarative runner excluded).
5. Two-node drain/hand-off at a kill timeout above 20 s; unique node names; stale-node cleanup.
6. Phoenix lock drift: fix now, independent of the sync — pin `ref: 86aa946…` explicitly so a deps update can't silently jump lines.
7. Durable migration ledger seeding for engine-owned Postgres DDL.
8. Rollback strategy after 2.2 writes data: data downgrade vs forward fix.

## 7. Order of work

1. (now, small) Phoenix: pin durable by `ref` (gap 6). Backups + fork `main` mirror reset.
2. Gap 2 test run → final carry list. Downstream-only guards (push URL, branch protection).
3. lightforge-main: graft + merge upstream (monorepo layout), carry set only; durable tests green.
4. Engine: DDL port, admission on `:key`, 2.0 API, `pending_waits`; engine tests green.
5. Phoenix: deps + host migration + baseline + raw-SQL status fixes; `mix test`; then Hugo runs workflow e2e.
5b. connect-phoenix: pins + `sparse`; suite + flows harness on SQLite.
6. Rollout per the mixed-version contract (§5): expand → drain → deploy one set → enable; dev cluster first, then Fly with kill timeout ≥ 30 s.

## 8. Gap 2 results (2026-11-27): Lightforge tests run against upstream 2.2.0

Method: each Lightforge-added test, from June base `a37f6c5` to `lightforge-main`, was copied into an upstream `a6e4467`
`durable/` worktree and run with `--include integration` on a throwaway PG 18. Upstream's own suite is the baseline:
1429 passed, 0 failed (598 integration excluded). 21 Lightforge tests ran: 7 pass, 14 fail.

| Test (LF file) | Result on upstream | Classification → action |
|---|---|---|
| two queues run work (queue/manager) | pass | covered, drop ours |
| event resume wakes the queue (wait) | pass | covered, drop ours |
| atom/tuple/binary errors normalized (error_normalization ×3) | pass | covered, drop ours |
| `Context.input/0` readable in steps (context_input) | pass | covered, drop ours |
| **context written before a step error is persisted** (error_normalization) | fail: `context["failure_evidence"]` nil | **real gap → carry** |
| `pending_waits/1` ×2 (wait) | fail: undefined | **carry** in engine (§4) |
| **retry re-executes only the failed step** (resume_edge_cases) | fail: step2 never re-ran | **covered** (§8.1): the LF test fakes a failed row with no step history; upstream resumes from step rows. Retry epoch → **carry** (§8.1) |
| **retry bounded** (resume_edge_cases) | fail: upstream returned `{:ok, _}` where we expect `:retry_limit_reached` | **real gap → carry the bound in the engine** (no unbounded retry from operators) |
| retry already queued returns same receipt (resume_edge_cases) | fail: `{:error, :not_failed}` | semantics differ but still idempotent (no second run) → adopt upstream; engine maps `:not_failed` |
| **provide_input wakes poller, non-inline** (wait) | fail: assert_eventually timed out | **covered** (§8.1): harness — wake is deferred to commit; sandbox never commits |
| **child callback failure removes the child** (orchestration) | fail: parent not `:completed` | **carry `after_start`** (§8.1): tenancy gate, no upstream equivalent |
| inline child completion before parent wait; dynamic string refs (orchestration ×2) | fail: reads our `context["__children"]` internals | test reads internals → rewrite against upstream child links (`list_children`) before judging |
| already-waiting workflow not re-executed (wait) | fail: `:superseded` vs `:not_pending` | covered (no re-execution); error atom differs → engine maps it |
| `on_timeout: :fail` records mode; event timeout fails run (wait ×2) | fail: no `on_timeout` field; internal `do_check_timeouts/1` shape | **drop** (§8.1): no consumer uses event `on_timeout: :fail` |
| concurrent identical starts admit one (integration/concurrency) | fail: `Storage.Dialect` absent | expected: admission moves to the engine on upstream `:key` (§2/§4) |

### 8.1 Verify rows resolved (2026-11-27)

| Item | Evidence | Action |
|---|---|---|
| Retry re-runs only the failed step, same id | Upstream `operator_controls_test.exs` `describe "retry/2"` + property "never re-runs a completed step" | **Covered, drop ours** |
| Retry epoch `context.__durable_retry_epoch` | Engine `context.ex` derives `workflow_attempt = epoch + 1` so each retry gets a fresh agent session/event identity. Upstream `retry_workflow/2` (`reset_for_retry`) never sets it | **Carry** (Durable or engine). Without it a retried agent step replays the prior attempt's terminal event. Test: retry a failed agent step → new attempt id |
| `provide_input` wakes the poller | Upstream resumes inside a transaction; `DurablePubSub.wake` defers to `CommitWaker` until commit, and the SQL sandbox never commits. Upstream `integration/run_control_test.exs` "input given / event sent inside a transaction resumes the run when it commits" (poll interval 1 h) run here: **3/3 pass** | **Covered, drop ours** |
| `call_workflow(..., after_start: fun)` deletes the child when the gate fails | Upstream `Durable.Orchestration` has no `after_start` (opts: `ref`, `timeout`, `timeout_value`, `queue`, `durable`). Consumers: engine `declarative/runner.ex` `subworkflow_opts` → `MultiTenancy.verify_workflow_tag`; Phoenix `requirement_parent_workflow.ex` `verify_child_tenancy` | **Carry**, security-relevant (cross-tenant child guard). Port the LF test with the feature |
| Event `wait_for_event(..., on_timeout: :fail)` | Upstream: `on_timeout` only on `PendingInput`; event timeouts always resume with `timeout_value`. No consumer passes it (engine `runner.ex`/`helpers.ex` pass only `timeout`/`timeout_value`; Phoenix, connect-phoenix: none) | **Drop.** Engine DDL `pending_events.on_timeout` (DEFAULT `'resume'`) becomes unused; leave it or drop it in the port |

Carry list (final): SQLite dialect layer, `step_executions.session_id`, `pending_waits`, context persisted on step
failure, retry epoch, `after_start` child gate, bounded retry (engine).

## 9. Merge into lightforge-main (2026-11-27)

Branch `sync/upstream-merge-20261127`. History: graft `ac12f43` (parents lightforge-main `445652d95` +
upstream `ad60324`; tree = upstream `ad60324` with `durable/` = lightforge-main) → merge upstream `a6e4467` taking
upstream's tree → carry-specific commits (a carry's review fixes are separate commits, not squashed, so the pushed
branch is never rewritten): CI `3e5fcaf`; session_id `8f3265f`; pending_waits `85f210e` + `7a666b1`; retry epoch
`df5af18` + `1a31d8d` + `afad6d7`; after_start `ec58a05`; failed-step context `ec2561a` + `cfdf833`. Every later sync:
`git merge upstream/main`.

**SQLite split (owner, 2026-11-27).** Porting SQLite onto 2.2 is a large job: raw SQL call sites went from 13 to 94, the
queue adapter has 2 new callbacks, and 16 migrations need translating. So lightforge-main moves to 2.2 on Postgres now,
and the current SQLite code stays on **`lightforge-sqlite` = `445652d95`** for connect-phoenix. The compile-time
`schema_prefix` goes with it. Porting SQLite to 2.2 is its own bead, sized after an adapter spike.

| Carry | Where | Change vs lightforge-main | Test (RED on upstream → GREEN) |
|---|---|---|---|
| `step_executions.session_id` | migration `V20260609000000` (original LF version), `StepExecution` | same | `step_execution_session_id_test.exs` 2/2 |
| `pending_waits/2` + `!` | `Durable`, `Durable.Wait` | 2.x read contract: `{:ok, waits}`; `{:error, :not_found}` for an id that isn't a run's (was `[]`); in `ReadFunctions` | `lightforge/pending_waits_test.exs` 5/5 + read contract |
| Retry epoch | `Executor.reopen/4` (the run retried) **and `put_back/3`** (every lane and called child the retry requeues, in the same update), `EngineState` `__retry_epoch__`, **`Durable.Context.retry_epoch/0`** | moved from `context.__durable_retry_epoch` into engine state: in the context it made a never-saved run hand its step the context instead of its input (upstream `Issue48Test` failed). **Engine port: read `Durable.Context.retry_epoch/0`** | `lightforge/retry_epoch_test.exs` 5/5 (2 of the original 3 RED); `lightforge/retry_put_back_test.exs` 2/2 (failed lane, cancelled called child; both RED before `afad6d7`) |
| `after_start` child gate | `Durable.Orchestration` | runs **inside** the insert transaction; failure rolls back, so a rejected child never commits (LF inserted then deleted). Also on `start_workflow/3` | `lightforge/after_start_test.exs` 4/4 (0/4 on upstream) |
| Failed step keeps its context | `Executor.handle_step_failure/4` | step failures only; only the run's own process context (an inline child leaves its own behind); engine state written = the row's current state with the step's process state over it, so a recorded child can't be erased | `lightforge/failed_step_context_test.exs` 2/2 (0/2 on upstream); `lightforge/failed_step_child_test.exs` 1/1 (start child, write context, fail, retry: one child, same correlation; passes before `cfdf833` too, since `run_step/4` already merges on the main path; guards `fail_at/5` and future paths) |
| Root CI and Site workflows | `.github/workflows/{ci,site}.yml` | `workflow_dispatch` only (fork policy: no CI builds) | n/a |

Dropped (covered upstream or unused, §8/§8.1): Lightforge admission columns (moves to the engine on upstream `:key`),
`retry_count`/`last_retried_at` + `:retry_limit_reached` (bound moves to the engine), event `on_timeout`, pending-event
index (upstream has it), wake-on-start/resume, error normalization, `Context.input`.

Receipt at `1a31d8d` (porcelain empty, PG 18 throwaway): `compile --warnings-as-errors` 0, `format --check-formatted` 0,
`mix test` **1454 passed, 0 failed** (600 excluded), `mix test --only integration` **482 passed, 0 failed**. Fuzz not run.

**Owner action:** the fork's Actions ran upstream CI and Site on the mirror push to `main` (Site failed: no Cloudflare
secret). Disable both on the fork (`gh workflow disable ci.yml site.yml -R lightforgedev/durable`) or turn Actions off;
the dispatch-only change here covers lightforge-main only.

Engine port inputs from this merge: `Durable.Context.retry_epoch/0`; `pending_waits!/1`; `{:error, {:child_start_callback_failed, _}}`
from `start_workflow/3` too.
