# Project Director

The Project Director is an orchestration layer above Firstmate's existing task lifecycle.
The captain hands it a high-level project spec; it decomposes the project into tasks, dispatches them through Firstmate's existing workers, integrates the results, validates the whole against the project's own acceptance criteria, runs gap analysis, and replans until acceptance passes or the project is genuinely blocked.

Its guiding principle is that task completion is not project completion.
A task reporting `done` is one input; the director only concludes the project when an independent review pass verifies the original acceptance criteria against the actual repo state.

This document is the single owner of the director's architecture, state formats, CLI contract, and limitations.
`bin/fm-project-director.sh` and its header own exact commands and flags.
The judgment-side procedure (how the firstmate session plans, reviews, and replans) lives in the internal [`project-director` skill](../.agents/skills/project-director/SKILL.md).

## Mental model

The director is a state machine plus a review loop, not a daemon and not a second fleet.

```
intake -> recon -> architecture -> plan -> execute -> integrate -> validate
                                                              |          |
                                                              |          v
                                                              +------ gap analysis
                                                                         |
                                                            pass: COMPLETE    fail: replan -> execute
                                                                         |
                                              any guard exceeded: BLOCKED (reason recorded)
```

- Deterministic mechanics - DAG math, dependency gating, budget and iteration guards, state transitions, persistence, BLOCKED - live in the CLI so they are testable without a model and behave identically on every run.
- Judgment - reading a spec, designing a decomposition, writing acceptance criteria, judging integration, finding gaps - is performed by the firstmate session (or a director-profiled worker) following the `project-director` skill, driving the CLI between judgment steps.
- Execution stays entirely in Firstmate: tasks are ordinary backlog items, spawned through `fm-brief.sh` and `fm-spawn.sh` exactly as a hand-dispatched task would be, observed through `fm-crew-state.sh`, and torn down through `fm-teardown.sh`.
- The director adds no watcher, no timer, no second state system; it is a durable record on disk plus commands that read and advance it.

## Role-based runtime selection

The director introduced the concept of a logical role having its own runtime: director, firstmate, secondmate (with an optional scope such as `secondmate.backend`), crew, scout, and reviewer.
`bin/fm-role-profile-lib.sh` is the single owner of that resolution; [`docs/configuration.md`](configuration.md) ("Role profiles") owns the `config/role-profiles.json` format.

Two invariants matter architecturally:

- Project state stores logical profile names only (`"profile": "crew"`), never concrete models.
  Concrete harness/model/effort are resolved at dispatch time and recorded in the execution history.
  Changing a model in `config/role-profiles.json` therefore never invalidates a plan; the next dispatch simply resolves the new value.
- The reviewer role exists so acceptance is not self-certification: the director invokes review under the reviewer profile, which an operator normally pins to a different harness or model than crew work.
  The roles are independent by construction - nothing forces reviewer and crew to differ, but the default example and the skill both treat them as distinct.

One honest limitation: a firstmate session that is already running cannot switch its own model.
The `firstmate` profile applies at launch surfaces - seeding a secondmate home (a secondmate runs a firstmate) and relaunching a dead one - and to status display, never to a live session in flight.

## Persisted state

All director state lives under `data/director/<project-id>/`, private to the home, one directory per project:

| File | Owner of |
| - | - |
| `spec.md` | The captain's original spec, verbatim. |
| `plan.json` | The current task DAG (format below). |
| `state.json` | Phase machine, counters, guards, timestamps. |
| `history.jsonl` | Append-only execution records, one per dispatch/review, including the concrete resolved runtime. |
| `gaps.md` | Open gap findings from review passes, one bullet per gap. |
| `blockers.md` | BLOCKED reasons, guard trips, and anything the captain must decide. |

`<project-id>` is a slug derived from the spec title at `start` and printed back by every command.
State is plain JSON and Markdown so a human can inspect it.
Replans supply a full revised DAG and retain any matching task already recorded `done`.
Plan replacement in `execute` refuses while any task is in flight.
Dispatch persists `dispatching` intent and its backlog id before it touches Firstmate's task lifecycle, then reconciles a published worker record on retry instead of spawning a duplicate.

### plan.json - the DAG

```json
{
  "version": 1,
  "project": "payments-webhook",
  "acceptance": [
    "Spec test X passes against the running service",
    "POST /hook returns 2xx for a valid payload"
  ],
  "tasks": [
    {
      "id": "t1-schema",
      "title": "Define webhook payload schema",
      "objective": "One sentence the worker and reviewer both read.",
      "instructions": "Body for the brief's Firstmate spec section.",
      "context": "Adjacent landed work the worker needs to know.",
      "acceptance": ["cargo test -p schema passes"],
      "deps": [],
      "files": ["crates/schema/"],
      "validation": "cargo test -p schema",
      "profile": "crew",
      "status": "pending",
      "backlog": "payments-webhook/t1-schema"
    }
  ]
}
```

- `deps` references sibling task ids; a task is dispatchable only when every dep is `done`.
- `status` is one of `pending`, `dispatching`, `dispatched`, `done`, `failed`, `skipped`.
- `dispatching` is durable recovery intent; it records the backlog item before Firstmate's existing brief and spawn operations run.
- `profile` is a logical role name resolved through `fm-role-profile-lib.sh` at dispatch time.
- `acceptance` at the project level is the captain's own criteria, written at `start` from the spec, and is the only thing that can conclude the project.

### state.json - the phase machine

```json
{
  "version": 1,
  "phase": "execute",
  "iteration": 1,
  "tasks_dispatched": 3,
  "gap_cycles": 0,
  "created": "2026-09-18T10:00:00Z",
  "updated": "2026-09-18T11:40:00Z"
}
```

Phases: `intake`, `recon`, `architecture`, `plan`, `execute`, `integrate`, `validate`, `gap`, `complete`, `blocked`.
`intake` through `plan` are advanced by the judgment side through `begin`/`phase` commands; `execute` through `gap` are advanced by `step`, which reconciles live task state before acting; `complete` and `blocked` are terminal.

## CLI

```
fm-project-director.sh start <spec.md> [--project <slug>]   # intake: persist spec, derive id, create skeleton
fm-project-director.sh list                                 # one line per project: id, phase, iteration
fm-project-director.sh status <id>                          # phase, counters, DAG table, runtime table
fm-project-director.sh phase <id> <phase>                   # judgment-side phase advance (forward only)
fm-project-director.sh plan-set <id> <plan.json>            # adopt a DAG (validates: unique ids, known deps, non-empty acceptance)
fm-project-director.sh ready <id>                           # ids of dispatchable tasks (deps done), one per line
fm-project-director.sh dispatch <id> <task-id>              # file backlog item, scaffold brief, resolve profile, spawn
fm-project-director.sh task-done <id> <task-id>             # record landed outcome (verified before accept)
fm-project-director.sh task-failed <id> <task-id>           # record failure; increments the task's failure count
fm-project-director.sh gaps <id> <gaps.md>                  # adopt review findings; new gaps open a replan cycle
fm-project-director.sh accept <id>                          # reviewer verified project acceptance: COMPLETE
fm-project-director.sh block <id> <reason...>               # record BLOCKED with reason
fm-project-director.sh step <id>                            # advance the loop one deterministic step
```

`dispatch` is the only command that touches the fleet, and it does so exclusively through the existing interfaces: `fm-tasks-axi.sh add`, `fm-brief.sh`, role-profile resolution, and `fm-spawn.sh`.
All other commands are pure state operations, which is what makes the loop testable with a stubbed toolchain.

`step` reconciles and advances: while dispatchable tasks remain it dispatches them (bounded per run); a `dispatching` task remains in flight until its published worker record is reconciled; when every task is `done` it moves to `integrate`.
In `integrate`, `validate`, and `gap` the review is judgment work, so `step` prints the pending review question and exits 0; the judgment side runs the review under the reviewer role and then records its outcome through `gaps` or `accept`.
It never fabricates a verdict.

## Completion and BLOCKED semantics

COMPLETE requires `accept`, which requires every project-level acceptance criterion to have been verified by the reviewer role against the actual repo - not reported by workers.
A `done` task is necessary but never sufficient.

The director refuses silent divergence into infinite work through deterministic guards, all recorded in `state.json` and all tripping BLOCKED with a reason in `blockers.md`:

- `max_iterations` (default 5): total replan cycles.
- `max_gap_cycles` (default 3): consecutive gap-analysis rounds that produce new gaps.
- A failed task blocks the project immediately, so no failed required node can pass into integration or acceptance; a revised plan supplies the next implementation path.
- `max_tasks` (default 50): total dispatches across the project's life.
- Identical-gap rediscovery: a new gap cycle whose findings hash-match the previous cycle's blocks instead of looping.

BLOCKED is terminal for the CLI but recoverable by the captain: after a decision or external fix, `fm-project-director.sh phase <id> execute` (or `plan-set` with a revised DAG) re-arms the loop, preserving counters and history.

## Recovery

Every command validates state before acting and appends to `history.jsonl` only after the effect it records.
After a crash, `status` shows the last consistent state and `step` (or the specific command that was interrupted) is simply re-run; there is no lock, because only the firstmate session drives the director, and the CLI's own validations catch a stale intermediate state.
Execution history is the audit trail: each record carries task id, logical profile, resolved concrete harness/model/effort, timestamp, and outcome.

## V1 limits

- One director project at a time per home is the intended posture; nothing enforces it beyond the captain's attention.
- The judgment side runs in the firstmate session; there is no headless autonomous director daemon, by design.
- Cross-project coordination, UI, and budget/cost accounting beyond task counts are out of scope for V1.
