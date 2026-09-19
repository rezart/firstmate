---
name: project-director
description: >-
  Agent-only procedure for driving the Project Director loop for a multi-task project.
  Use when the captain asks for a whole project to be planned, decomposed, executed, and verified end to end
  ("build X", "deliver Y") rather than a single task, and when resuming, reviewing, or replanning such a project.
  Owns the judgment side of the loop: recon, architecture, DAG authoring, reviewer-role review, and gap analysis.
user-invocable: false
metadata:
  internal: true
---

# Project Director procedure

`bin/fm-project-director.sh` owns the deterministic state machine; this skill owns the judgment you supply between its commands.
`docs/project-director.md` is the single owner of formats, phases, guards, and limits; read its CLI section before your first drive.
The principle throughout: task completion is not project completion - only reviewer-verified project acceptance concludes a project.

## Intake

1. Confirm the ask is a project, not a task: multiple deliverables, integration across them, acceptance criteria stated at the whole.
   A single well-scoped change is an ordinary task; dispatch it per AGENTS.md section 7 instead.
2. Write the captain's spec verbatim to a file with a `# Title` heading and an `Acceptance:` section listing the project-level criteria.
   These criteria are the only thing that can conclude the project, so lift them from the captain's own words; ask one concise question if they are absent.
3. `fm-project-director.sh start <spec.md>`; relay the printed project id.

## Recon and architecture

In `recon`: read the target repo's README, AGENTS.md, recent history, and the seams the spec touches.
A scout dispatch is appropriate here when the repo is large or unfamiliar; keep it bounded.

In `architecture`: decide the decomposition shape - what must land first, what is independent, what integrates.
Then author `plan.json` exactly per the DAG format in docs/project-director.md and `plan-set` it.

Rules for the DAG:

- One task = one independently landable change with its own acceptance and validation.
- `deps` only where integration genuinely requires ordering; over-serializing wastes the fleet.
- Per-task `profile` is a logical role (`crew`, `scout`, or `reviewer`); never a concrete model.
- `repo`, `mode`, `yolo` come from the project's registered delivery posture (AGENTS.md section 7); resolve them with `fm-project-mode.sh` when in doubt.

## Execute

Drive `step` after each supervision-cycle check of live tasks.

- For each dispatched backlog id, read current state with `fm-crew-state.sh <bid>`; never trust a single status event.
- Landed and verified -> `task-done`. Failed per its delivery mode -> `task-failed`; the CLI blocks the project after repeated failures on one task.
- `step` refuses to invent work: when nothing is ready and nothing is in flight it either moves to `integrate` or blocks.
- Do not hand-edit `plan.json` mid-execute; a changed plan goes through `plan-set` in a replan cycle.

## Review (integrate/validate/gap)

When `step` prints `review required`, run the review yourself under the reviewer role's posture - skeptical, spec-first, unconvinced by worker reports:

1. Re-read the captain's acceptance criteria from `spec.md`.
2. Inspect the actual repo state: the landed changes, tests, docs.
3. For each criterion, verify it against evidence you produced or ran, not worker claims; run the validation commands.
4. Verdict:
   - All criteria verified -> `accept <id>`; the project is COMPLETE. Relay the outcome to the captain with what landed.
   - Gaps found -> write them to a file, one bullet per gap, each naming the criterion it breaks and the concrete missing work; `gaps <id> <file>`.
     The CLI opens a replan cycle back to `execute`; author the gap-remediation tasks into a revised DAG and `plan-set` it.

Never soften this: if you cannot verify a criterion, that is a gap, not a pass.

## Blockers

When any guard trips, the CLI records BLOCKED. Read `blockers.md`, form the smallest unblock - a captain decision, an external fix, a revised plan - and either relay the decision to the captain or `phase <id> execute` after the fix. Preserve counters; a re-armed project keeps its history and failure counts.

## Recovery

After any crash or restart, `status <id>` shows the consistent state; re-run `step` or the interrupted command. History in `history.jsonl` is the audit trail if the transcript is gone.
