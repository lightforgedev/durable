# Idempotent Admission and Run-Scoped Wait Ingress

Durable owns atomic start deduplication and run-scoped wait discovery; host libraries own authorization, tenant scope, actor attribution, and business retry policy.

| Metadata | Value |
| --- | --- |
| Owner | Lightforge Durable maintainers |
| Audience | Durable and host-engine maintainers |
| Last reviewed | 2026-10-06 |
| Review cadence | On admission, wait, migration, or storage-dialect changes |
| Canon status | active |
| Related pointers | Bead `aegis-brtav`; Durable PR #18; AegisDurableEngine PR #46 |

## Outcome and acceptance bar

| Item | Contract |
| --- | --- |
| Requirement | A repeated start request creates one run; a host can inspect and fulfill only the waits for an authorized run. |
| Intent | Close setup-onboarding gaps E2-E4 without adding workflow rewind. |
| Why | App-owned deduplication has a crash gap; global wait scans are incomplete; direct Durable ingress bypasses host authorization. |
| User | Workflow hosts, setup clients, operators, and auditors. |
| Trust boundary | Durable enforces mechanical uniqueness and exact wait correlation. The host derives scope and decides who may start or resume a run. |
| Acceptance bar | PostgreSQL and SQLite preserve duplicate-start, conflicting-reuse, wrong-run, wrong-org, and duplicate-delivery invariants under concurrency and restart. |

## Evidence and decision

| Candidate | Exact source | Remaining gap | Decision |
| --- | --- | --- | --- |
| App-owned `workflow_instances` | Phoenix setup design E4 workaround | Crash between Durable insert and app projection can create duplicate runs. | Keep as a product projection; do not use as admission authority. |
| Caller-supplied run UUID | Durable `feat/sqlite` `97741fa` | Primary-key conflict does not retain a canonical request fingerprint. | Reject. |
| Opaque key plus stored fingerprint | Durable `feat/sqlite` `97741fa` | Requires two additive columns and one unique index. | Implement in the Lightforge fork. |
| Global pending-wait listing | `Durable.Wait.list_pending_inputs/1` and `list_pending_events/1` | Bounded global scans cannot prove all waits for one run. | Add direct run filters and a combined query. |
| Arbitrary backward goto | `Durable.Executor` rejects backward decisions | Re-entry requires output invalidation, new attempts, stale-wait fencing, and side-effect reconciliation. | Defer; not required by E2-E4. |
| Continue-as-new | No Durable contract at `97741fa` | Needs chain identity, carry-forward policy, child policy, and migration semantics. | Separate future design after a demonstrated unbounded-history requirement. |

Lightforge owns these fork changes. No upstream request or upstream acceptance is a delivery dependency.

## Contract

| Item | Required statement |
| --- | --- |
| Start | `Durable.start/3` accepts optional `:idempotency_key`; omitted keys preserve existing behavior. |
| Identity | The key is opaque, non-empty, bounded, and unique within one Durable storage namespace. Hosts namespace or hash business identity before calling. |
| Fingerprint | Module, workflow name, normalized input, queue, priority, and schedule determine the immutable request fingerprint. |
| Duplicate | Same key and fingerprint returns the existing run without a second start event, queue wake, or inline execution. |
| Admission receipt | `:return_admission` adds `:started` or `:existing` for trusted host adapters; the default return remains `{:ok, run_id}`. |
| Conflict | Same key and different fingerprint returns `{:error, :idempotency_conflict}`. |
| Re-enrolment | A deliberate new enrolment supplies a new host-derived generation key. Terminal status does not implicitly permit key reuse. |
| Wait query | `pending_waits/2` returns every pending input and event for one run; absence returns an empty list and never falls back to a global scan. |
| Input/event ingress | Durable consumes an exact `(run_id, kind, name)` wait. Host wrappers authorize the run before delegation. |
| Failure | Invalid keys fail before insert; unknown/stale waits do not resume a run; host scope mismatch returns not-found. |

### State flow

```text
start(key, request)
  -> insert won                  -> new run -> wake once
  -> key exists + same digest   -> existing run
  -> key exists + other digest  -> idempotency_conflict

authorized pending_waits/provide_input/send_event
  -> host scope check
  -> exact Durable wait query or consume
  -> durable state transition
  -> host telemetry/audit boundary
```

## Module plan

| File/module | Responsibility | Change |
| --- | --- | --- |
| `Durable.Executor` | Atomic start admission and existing-run reconciliation | Extend |
| `WorkflowExecution` | Persist key and fingerprint; translate uniqueness violations | Extend |
| Durable migrations | Add nullable columns and partial unique index on both dialects | Add |
| `Durable.Wait` | Filter inputs/events by run and return combined pending waits | Extend |
| `Durable` | Public pending-wait facade | Extend |
| `AegisDurableEngine` | `%Scope{}`-first start key, wait query, and ingress APIs | Host-fork change |
| `AegisDurableEngine.MultiTenancy` | Fail-closed organization ownership check | Reuse |

## Trust and data boundary

| Threat | Control |
| --- | --- |
| Cross-organization wake | Host verifies immutable run ownership before querying or consuming a wait. Wrong scope returns not-found. |
| Duplicate trigger | Storage unique index arbitrates concurrent inserts; callers do not perform check-then-insert. |
| Key reuse with changed data | Stored fingerprint comparison fails closed. |
| Sensitive business key exposure | AEGIS hashes its organization/workflow/subject/generation tuple before passing the opaque key to Durable. |
| Stale input/event | Durable requires an exact pending wait and performs the consume/resume transaction. |
| Duplicate observability | Only the winning insert emits the Durable start event and wake. Host telemetry includes run and organization, never raw key material. |

## Validation matrix

| Scenario | Expected receipt | Boundary |
| --- | --- | --- |
| Same key, sequential duplicate | One execution ID and row | Durable focused test |
| Same key, concurrent duplicate | One committed row; every caller receives its ID | Real-connection PostgreSQL and SQLite integration test |
| Same key, changed input/workflow/options | `:idempotency_conflict`; original row unchanged | Durable focused test |
| No key | Two calls retain current two-run behavior | Durable compatibility test |
| Run with input and event waits | Combined query returns only that run's waits | Durable wait test |
| Unknown run | Empty wait list; no global fallback | Durable wait test |
| Wrong organization | Not-found; pending wait remains pending | Engine integration test |
| Authorized input/event | Exact wait consumed; unrelated run untouched | Engine integration test |
| Duplicate/stale delivery | No second resume or unrelated mutation | Durable and engine tests |
| SQLite busy/concurrency | Immediate transactions settle to one run | SQLite integration test |

## Rollout and gates

| Gate | Status |
| --- | --- |
| Durable SQLite predecessor | Open PR #18 at `97741fa`; this work is stacked on that exact head. |
| Engine SQLite predecessor | Open PR #46 at `dd4ade1`; engine work is stacked on that exact head. |
| PostgreSQL validation | Durable focused suite: 82 tests; real-concurrency suite: 3 tests. Engine full suite against locked Durable commit `135fc82`: 367 tests, 0 failures. Passed on 2026-10-06. |
| SQLite validation | Durable full suite including integration: 444 tests, 0 failures. Engine full suite against locked Durable commit `135fc82`: 367 tests, 0 failures. Passed on 2026-10-06. |
| Phoenix setup integration | Out of this slice; must consume the released fork commits before removing app workarounds. |

Deployment order: Durable migration and code, then AegisDurableEngine migration/code, then Phoenix setup callers. Rollback keeps nullable admission columns until no deployed caller supplies an idempotency key.
