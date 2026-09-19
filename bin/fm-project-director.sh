#!/usr/bin/env bash
# shellcheck shell=bash
#
# fm-project-director.sh - state machine + review loop for multi-task projects.
#
# The captain hands a high-level project spec; the director decomposes it into a
# task DAG, dispatches each task through Firstmate's existing lifecycle
# (backlog item -> fm-brief scaffold -> fm-spawn), and converges through
# integration review and gap analysis until project-level acceptance passes or
# a deterministic guard trips BLOCKED. Task completion is not project
# completion: only `accept`, after reviewer-role verification of the project
# acceptance criteria, concludes a project.
#
# docs/project-director.md is the single owner of the architecture, state
# formats, phase machine, and limits; this header owns exact commands only.
#
# Usage:
#   fm-project-director.sh start <spec.md> [--project <slug>]
#   fm-project-director.sh list
#   fm-project-director.sh status <id>
#   fm-project-director.sh phase <id> <phase>
#   fm-project-director.sh plan-set <id> <plan.json>
#   fm-project-director.sh ready <id>
#   fm-project-director.sh dispatch <id> <task-id>
#   fm-project-director.sh task-done <id> <task-id>
#   fm-project-director.sh task-failed <id> <task-id>
#   fm-project-director.sh gaps <id> <gaps.md>
#   fm-project-director.sh accept <id>
#   fm-project-director.sh block <id> <reason...>
#   fm-project-director.sh step <id>
#
# State lives under <data>/director/<id>/ (spec.md, plan.json, state.json,
# history.jsonl, gaps.md, blockers.md). Every mutation validates phase first,
# so re-running an interrupted command is safe.
#
# Dispatch touches the fleet only through the existing interfaces; the exact
# binaries honor the repo's override convention for tests:
#   FM_DIRECTOR_TASKS_AXI (default $ROOT/bin/fm-tasks-axi.sh)
#   FM_DIRECTOR_BRIEF     (default $ROOT/bin/fm-brief.sh)
#   FM_DIRECTOR_SPAWN     (default $ROOT/bin/fm-spawn.sh)
# Role profiles resolve through bin/fm-role-profile-lib.sh at dispatch time;
# the plan stores logical profile names only, so config changes never
# invalidate a plan.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}
FM_HOME=${FM_HOME:-$ROOT}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
DIRECTOR_DIR=$DATA/director
STATE_AXI=${FM_DIRECTOR_TASKS_AXI:-$ROOT/bin/fm-tasks-axi.sh}
BRIEF_BIN=${FM_DIRECTOR_BRIEF:-$ROOT/bin/fm-brief.sh}
SPAWN_BIN=${FM_DIRECTOR_SPAWN:-$ROOT/bin/fm-spawn.sh}
# shellcheck source=bin/fm-role-profile-lib.sh
. "$SCRIPT_DIR/fm-role-profile-lib.sh"

FM_DIRECTOR_PHASES="intake recon architecture plan execute integrate validate gap"
FM_DIRECTOR_MAX_ITERATIONS=${FM_DIRECTOR_MAX_ITERATIONS:-5}
FM_DIRECTOR_MAX_GAP_CYCLES=${FM_DIRECTOR_MAX_GAP_CYCLES:-3}
FM_DIRECTOR_MAX_TASK_FAILURES=${FM_DIRECTOR_MAX_TASK_FAILURES:-2}
FM_DIRECTOR_MAX_TASKS=${FM_DIRECTOR_MAX_TASKS:-50}
FM_DIRECTOR_MAX_DISPATCH_PER_STEP=${FM_DIRECTOR_MAX_DISPATCH_PER_STEP:-3}

fm_director_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

fm_director_dir() {  # <id> -> path, verified
  case "$1" in
    ""|.|..|*/*|*\\*) echo "fm-project-director: invalid project id $1" >&2; return 2 ;;
  esac
  local d=$DIRECTOR_DIR/$1
  [ -d "$d" ] || { echo "fm-project-director: no project $1 (start it first)" >&2; return 2; }
  printf '%s\n' "$d"
}

fm_director_slug() {  # <text>
  printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed -e 's/^-*//' -e 's/-*$//'
}

fm_director_spec_title() {  # <spec.md> first heading line
  sed -n 's/^#[[:space:]]*//p' "$1" | head -1
}

fm_director_state_read() {  # <id> -> phase
  jq -r '.phase' "$DIRECTOR_DIR/$1/state.json"
}

fm_director_state_touch() {  # <id>
  local tmp
  tmp=$(jq --arg t "$(fm_director_now)" '.updated=$t' "$DIRECTOR_DIR/$1/state.json")
  printf '%s\n' "$tmp" > "$DIRECTOR_DIR/$1/state.json"
}

fm_director_require_phase() {  # <id> <allowed-phases-space-separated>
  local phase
  phase=$(fm_director_state_read "$1")
  case " $2 " in
    *" $phase "*) ;;
    *) echo "fm-project-director: project $1 is in phase $phase; command requires: $2" >&2; return 2 ;;
  esac
}

fm_director_history_append() {  # <id> <json>
  printf '%s\n' "$2" >> "$DIRECTOR_DIR/$1/history.jsonl"
}

fm_director_block() {  # <id> <reason>
  local id=$1; shift
  local tmp
  tmp=$(jq --arg p blocked '.phase=$p' "$DIRECTOR_DIR/$id/state.json")
  printf '%s\n' "$tmp" > "$DIRECTOR_DIR/$id/state.json"
  printf -- '- [%s] BLOCKED: %s\n' "$(fm_director_now)" "$*" >> "$DIRECTOR_DIR/$id/blockers.md"
  fm_director_history_append "$id" "$(jq -cn --arg t "$(fm_director_now)" --arg r "$*" '{ts:$t,event:"blocked",reason:$r}')"
  echo "blocked: $id - $*"
}


fm_director_task_set() {  # <id> <task-id> <field> <value>
  local tmp
  tmp=$(jq --arg t "$2" --arg f "$3" --arg v "$4" '(.tasks[] | select(.id==$t) | .[$f]) = $v' "$DIRECTOR_DIR/$1/plan.json")
  printf '%s\n' "$tmp" > "$DIRECTOR_DIR/$1/plan.json"
}

fm_director_task_failures() {  # <id> <task-id> -> count
  jq -r --arg t "$2" '.task_failures[$t] // 0' "$DIRECTOR_DIR/$1/state.json"
}

fm_director_count_inc() {  # <id> <field> [delta]
  local tmp
  tmp=$(jq --arg f "$2" --argjson d "${3:-1}" '.[$f] = ((.[$f] // 0) + $d)' "$DIRECTOR_DIR/$1/state.json")
  printf '%s\n' "$tmp" > "$DIRECTOR_DIR/$1/state.json"
}


fm_director_ready_tasks() {  # <id> -> task ids with all deps done, status pending
  local task dep ok
  jq -r '.tasks[].id' "$DIRECTOR_DIR/$1/plan.json" | while IFS= read -r task; do
    [ "$(jq -r --arg t "$task" '.tasks[] | select(.id==$t) | .status' "$DIRECTOR_DIR/$1/plan.json")" = pending ] || continue
    ok=1
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      [ "$(jq -r --arg d "$dep" '[.tasks[] | select(.id==$d)][0].status // "missing"' "$DIRECTOR_DIR/$1/plan.json")" = "done" ] || ok=0
    done < <(jq -r --arg t "$task" '.tasks[] | select(.id==$t) | .deps[]? // empty' "$DIRECTOR_DIR/$1/plan.json")
    if [ "$ok" = 1 ]; then printf '%s\n' "$task"; fi
  done
  return 0
}

fm_director_fill_brief() {  # <brief> <task-body-file> <spec-body-file>
  awk -v tf="$2" -v sf="$3" '
    $0 == "{TASK}" { while ((getline l < tf) > 0) print l; next }
    $0 == "{FIRSTMATE_SPEC}" { while ((getline l < sf) > 0) print l; next }
    { print }
  ' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

fm_director_cmd_start() {  # <spec.md> [--project <slug>]
  local spec slug='' dir
  case "$#" in
    1) ;;
    3) [ "$2" = --project ] && [ -n "$3" ] || { echo "fm-project-director: usage: start <spec.md> [--project <slug>]" >&2; return 2; } ;;
    *) echo "fm-project-director: usage: start <spec.md> [--project <slug>]" >&2; return 2 ;;
  esac
  spec=$1
  [ "${2:-}" != --project ] || slug=$3
  [ -f "$spec" ] || { echo "fm-project-director: spec file $spec not found" >&2; return 2; }
  [ -n "$slug" ] || slug=$(fm_director_slug "$(fm_director_spec_title "$spec")")
  case "$slug" in
    ""|.|..|*/*|*\\*|*[!a-z0-9-]*) echo "fm-project-director: project id must be a lowercase slug" >&2; return 2 ;;
  esac
  dir=$DIRECTOR_DIR/$slug
  [ -e "$dir" ] && { echo "fm-project-director: project $slug already exists" >&2; return 2; }
  mkdir -p "$dir"
  cp "$spec" "$dir/spec.md"
  jq -cn --arg p intake --arg t "$(fm_director_now)" \
    '{version:1,phase:$p,iteration:0,tasks_dispatched:0,gap_cycles:0,task_failures:{},last_gaps_hash:"",created:$t,updated:$t}' > "$dir/state.json"
  : > "$dir/history.jsonl"
  : > "$dir/gaps.md"
  : > "$dir/blockers.md"
  echo "started: $slug ($dir)"
}

fm_director_cmd_list() {
  [ -d "$DIRECTOR_DIR" ] || return 0
  local id
  for id in "$DIRECTOR_DIR"/*/; do
    [ -d "$id" ] || continue
    id=${id%/}
    printf '%s\t%s\titeration %s\n' "${id##*/}" "$(fm_director_state_read "${id##*/}")" \
      "$(jq -r '.iteration' "$id/state.json")"
  done
}

fm_director_cmd_status() {  # <id>
  local dir id=$1 phase
  dir=$(fm_director_dir "$id")
  phase=$(fm_director_state_read "$id")
  echo "project: $id"
  echo "phase: $phase"
  jq -r '"iteration: \(.iteration)  dispatched: \(.tasks_dispatched)  gap cycles: \(.gap_cycles)"' "$dir/state.json"
  if [ -f "$dir/plan.json" ]; then
    echo "tasks:"
    jq -r '.tasks[] | "  \(.id)  \(.status)  deps:\(.deps | map(.) | join(","))  \(.title)"' "$dir/plan.json"
  fi
  echo "runtimes:"
  local role out h m e s rest tab
  tab=$(printf '\t')
  for role in director reviewer firstmate crew; do
    out=$(fm_role_profile_resolve "$role") || { echo "  $role: (profile error)" >&2; continue; }
    h=${out%%"$tab"*}
    rest=${out#*"$tab"}
    m=${rest%%"$tab"*}
    rest=${rest#*"$tab"}
    e=${rest%%"$tab"*}
    s=${rest#*"$tab"}
    printf '  %-10s %s %s %s [%s]\n' "$role" "${h:--}" "${m:--}" "${e:--}" "$s"
  done
  [ -s "$dir/gaps.md" ] && { echo "open gaps:"; sed 's/^/  /' "$dir/gaps.md"; }
  [ -s "$dir/blockers.md" ] && { echo "blockers:"; sed 's/^/  /' "$dir/blockers.md"; }
}

fm_director_cmd_phase() {  # <id> <phase>
  local id=$1 new=$2 old order_old order_new tmp
  fm_director_dir "$id" >/dev/null
  old=$(fm_director_state_read "$id")
  case " $FM_DIRECTOR_PHASES " in
    *" $new "*) ;;
    *) echo "fm-project-director: unknown phase $new" >&2; return 2 ;;
  esac
  if [ "$old" = blocked ]; then
    [ "$new" = execute ] || { echo "fm-project-director: a blocked project only re-arms into execute (or replans via plan-set)" >&2; return 2; }
  else
    fm_director_phase_order() { case " $FM_DIRECTOR_PHASES " in *" $1 "*) printf '%s' $((1 + $(printf '%s' "$FM_DIRECTOR_PHASES" | tr ' ' '\n' | grep -n "^$1$" | cut -d: -f1)));; *) printf '0';; esac; }
    order_old=$(fm_director_phase_order "$old")
    order_new=$(fm_director_phase_order "$new")
    [ "$order_new" -gt "$order_old" ] || { echo "fm-project-director: phase moves forward only ($old -> $new refused)" >&2; return 2; }
  fi
  tmp=$(jq --arg p "$new" '.phase=$p' "$DIRECTOR_DIR/$id/state.json")
  printf '%s\n' "$tmp" > "$DIRECTOR_DIR/$id/state.json"
  fm_director_state_touch "$id"
  echo "phase: $old -> $new"
}

fm_director_cmd_plan_set() {  # <id> <plan.json>
  local id=$1 file=$2 dir dup known t dep replacement tmp
  dir=$(fm_director_dir "$id")
  fm_director_require_phase "$id" "architecture plan execute blocked"
  jq -e '(.acceptance | type) == "array" and (.acceptance | length) > 0 and (.tasks | type) == "array" and (.repo | type) == "string" and (.mode | type) == "string" and (.yolo | type) == "string"' "$file" >/dev/null 2>&1 \
    || { echo "fm-project-director: plan needs non-empty acceptance[], tasks[], repo, mode, yolo at top level" >&2; return 2; }
  case $(jq -r '.mode' "$file") in no-mistakes|direct-PR|local-only) ;; *) echo "fm-project-director: mode must be no-mistakes|direct-PR|local-only" >&2; return 2 ;; esac
  case $(jq -r '.yolo' "$file") in on|off) ;; *) echo "fm-project-director: yolo must be on|off" >&2; return 2 ;; esac
  dup=$(jq -r '.tasks[].id' "$file" | sort | uniq -d)
  [ -z "$dup" ] || { echo "fm-project-director: duplicate task ids: $dup" >&2; return 2; }
  known=$(jq -r '.tasks[].id' "$file" | sort)
  while IFS= read -r t; do
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      printf '%s\n' "$known" | grep -qx "$dep" || { echo "fm-project-director: task $t depends on unknown task $dep" >&2; return 2; }
    done < <(jq -r --arg t "$t" '.tasks[] | select(.id==$t) | .deps[]? // empty' "$file")
  done < <(jq -r '.tasks[].id' "$file")
  if [ "$(fm_director_state_read "$id")" = execute ] && jq -e '[.tasks[] | select(.status == "dispatched" or .status == "dispatching")] | length == 0' "$dir/plan.json" >/dev/null; then
    :
  elif [ "$(fm_director_state_read "$id")" = execute ]; then
    echo "fm-project-director: cannot replace a plan while tasks are in flight" >&2
    return 2
  fi
  if [ -f "$dir/plan.json" ]; then
    replacement=$(jq --slurpfile old "$dir/plan.json" '.tasks |= map(. as $new | (($old[0].tasks[]? | select(.id == $new.id)) // {}) as $prior | if $prior.status == "done" then .status = "done" | .backlog = $prior.backlog else . end)' "$file")
    printf '%s\n' "$replacement" > "$dir/plan.json"
  else
    cp "$file" "$dir/plan.json"
  fi
  tmp=$(jq '.phase="execute"' "$dir/state.json")
  printf '%s\n' "$tmp" > "$dir/state.json"
  fm_director_state_touch "$id"
  echo "plan adopted: $(jq -r '.tasks | length' "$dir/plan.json") tasks, phase -> execute"
}
fm_director_cmd_ready() { fm_director_ready_tasks "$1"; }


fm_director_cmd_dispatch() {  # <id> <task-id>
  local id=$1 tid=$2 dir profile kind mode yolo repo flags bid brief taskfile specfile stage
  dir=$(fm_director_dir "$id")
  fm_director_require_phase "$id" "execute"
  case "$(jq -r --arg t "$tid" '.tasks[] | select(.id==$t) | .status // "missing"' "$dir/plan.json")" in
    pending|dispatching) ;;
    *) echo "fm-project-director: task $tid is not pending" >&2; return 2 ;;
  esac
  local dispatched
  dispatched=$(jq -r '.tasks_dispatched' "$dir/state.json")
  [ "$dispatched" -lt "$FM_DIRECTOR_MAX_TASKS" ] || { fm_director_block "$id" "task budget exhausted ($dispatched >= $FM_DIRECTOR_MAX_TASKS)"; return 2; }
  local dep ok=1
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    [ "$(jq -r --arg d "$dep" '[.tasks[] | select(.id==$d)][0].status // "missing"' "$dir/plan.json")" = "done" ] || ok=0
  done < <(jq -r --arg t "$tid" '.tasks[] | select(.id==$t) | .deps[]? // empty' "$dir/plan.json")
  [ "$ok" = 1 ] || { echo "fm-project-director: task $tid has unfinished deps" >&2; return 2; }

  profile=$(jq -r --arg t "$tid" '.tasks[] | select(.id==$t) | .profile // "crew"' "$dir/plan.json")
  kind=$(jq -r --arg t "$tid" '.tasks[] | select(.id==$t) | .kind // "task"' "$dir/plan.json")
  mode=$(jq -r '.mode' "$dir/plan.json")
  yolo=$(jq -r '.yolo' "$dir/plan.json")
  repo=$(jq -r '.repo' "$dir/plan.json")
  [ -d "$repo" ] || { echo "fm-project-director: plan repo $repo is not a directory" >&2; return 2; }
  flags=$(fm_role_profile_flags "$profile") || return 2
  bid="$id-$tid"
  stage=$(jq -r --arg t "$tid" '.tasks[] | select(.id==$t) | .dispatch_stage // ""' "$dir/plan.json")
  if [ -e "$STATE/$bid.meta" ]; then
    fm_director_task_set "$id" "$tid" status dispatched
    fm_director_task_set "$id" "$tid" dispatch_stage complete
    if [ "$stage" != complete ]; then
      fm_director_count_inc "$id" tasks_dispatched
      fm_director_history_append "$id" "$(jq -cn --arg t "$(fm_director_now)" --arg task "$tid" '{ts:$t,event:"dispatch-recovered",task:$task}')"
    fi
    fm_director_state_touch "$id"
    echo "reconciled: $tid as $bid"
    return 0
  fi
  if [ "$stage" != backlog ]; then
    fm_director_task_set "$id" "$tid" status dispatching
    fm_director_task_set "$id" "$tid" backlog "$bid"
    fm_director_task_set "$id" "$tid" dispatch_stage intent
    fm_director_history_append "$id" "$(jq -cn --arg t "$(fm_director_now)" --arg task "$tid" --arg b "$bid" '{ts:$t,event:"dispatching",task:$task,backlog:$b}')"
    fm_director_state_touch "$id"
    if ! "$STATE_AXI" show "$bid" >/dev/null 2>&1; then
      taskfile=$(mktemp)
      jq -r --arg t "$tid" '.tasks[] | select(.id==$t) | .title' "$dir/plan.json" > "$taskfile"
      "$STATE_AXI" add "$bid" "$(cat "$taskfile")" --kind task >/dev/null
      rm -f "$taskfile"
    fi
    fm_director_task_set "$id" "$tid" dispatch_stage backlog
    fm_director_state_touch "$id"
  fi

  if [ "$kind" = scout ]; then
    "$BRIEF_BIN" "$bid" "$repo" --scout >/dev/null
  else
    "$BRIEF_BIN" "$bid" "$repo" --mode "$mode" >/dev/null
  fi
  brief=$DATA/$bid/brief.md
  [ -f "$brief" ] || { echo "fm-project-director: expected scaffolded brief at $brief" >&2; return 2; }
  taskfile=$(mktemp) specfile=$(mktemp)
  jq -r --arg t "$tid" '.tasks[] | select(.id==$t) | "# \(.title)\n\n\(.objective // .title)\n\nContext:\n\(.context // "none")\n\nTask acceptance:\n\(.acceptance | map("- " + .) | join("\n"))"' "$dir/plan.json" > "$taskfile"
  jq -r --arg t "$tid" '.tasks[] | select(.id==$t) | "\(.instructions // "Implement the objective above.")\n\nValidation: \(.validation // "the task acceptance list")\n\nTouch only: \(.files // [] | join(", "))"' "$dir/plan.json" > "$specfile"
  fm_director_fill_brief "$brief" "$taskfile" "$specfile"
  if [ "$kind" = scout ]; then
    # shellcheck disable=SC2086
    "$SPAWN_BIN" "$bid" "$repo" --scout $flags >/dev/null
  else
    # shellcheck disable=SC2086
    "$SPAWN_BIN" "$bid" "$repo" --mode "$mode" --yolo "$yolo" $flags >/dev/null
  fi
  fm_director_task_set "$id" "$tid" status dispatched
  fm_director_task_set "$id" "$tid" dispatch_stage complete
  fm_director_count_inc "$id" tasks_dispatched
  local rh rm re rest tab
  tab=$(printf '\t')
  rest=$(fm_role_profile_resolve "$profile")
  rh=${rest%%"$tab"*}; rest=${rest#*"$tab"}; rm=${rest%%"$tab"*}; rest=${rest#*"$tab"}; re=${rest%%"$tab"*}
  fm_director_history_append "$id" "$(jq -cn --arg t "$(fm_director_now)" --arg task "$tid" --arg p "$profile" --arg h "$rh" --arg m "$rm" --arg e "$re" '{ts:$t,event:"dispatch",task:$task,profile:$p,harness:$h,model:$m,effort:$e}')"
  fm_director_state_touch "$id"
  rm -f "$taskfile" "$specfile"
  echo "dispatched: $tid as $bid"
}

fm_director_cmd_task_done() {  # <id> <task-id>
  local id=$1 tid=$2
  fm_director_dir "$id" >/dev/null
  [ "$(jq -r --arg t "$tid" '.tasks[] | select(.id==$t) | .status // "missing"' "$DIRECTOR_DIR/$id/plan.json")" = dispatched ] \
    || { echo "fm-project-director: task $tid is not dispatched" >&2; return 2; }
  fm_director_task_set "$id" "$tid" status "done"
  fm_director_history_append "$id" "$(jq -cn --arg t "$(fm_director_now)" --arg task "$tid" '{ts:$t,event:"task-done",task:$task}')"
  fm_director_state_touch "$id"
  echo "done: $tid"
}

fm_director_cmd_task_failed() {  # <id> <task-id>
  local id=$1 tid=$2 failures tmp
  fm_director_dir "$id" >/dev/null
  case "$(jq -r --arg t "$tid" '.tasks[] | select(.id==$t) | .status // "missing"' "$DIRECTOR_DIR/$id/plan.json")" in
    dispatched|dispatching) ;;
    *) echo "fm-project-director: task $tid is not dispatched" >&2; return 2 ;;
  esac
  fm_director_task_set "$id" "$tid" status failed
  tmp=$(jq --arg t "$tid" '.task_failures[$t] = ((.task_failures[$t] // 0) + 1)' "$DIRECTOR_DIR/$id/state.json")
  printf '%s\n' "$tmp" > "$DIRECTOR_DIR/$id/state.json"
  failures=$(fm_director_task_failures "$id" "$tid")
  fm_director_history_append "$id" "$(jq -cn --arg t "$(fm_director_now)" --arg task "$tid" --argjson n "$failures" '{ts:$t,event:"task-failed",task:$task,failures:$n}')"
  fm_director_state_touch "$id"
  fm_director_block "$id" "task $tid failed (attempt $failures); revise the plan before resuming"
  return 2
}

fm_director_cmd_gaps() {  # <id> <gaps.md>
  local id=$1 file=$2 hash tmp iteration gap_cycles
  fm_director_dir "$id" >/dev/null
  fm_director_require_phase "$id" "integrate validate gap"
  [ -s "$file" ] || { echo "fm-project-director: an empty gaps file means acceptance passed; use accept instead" >&2; return 2; }
  hash=$(cksum "$file" | cut -d' ' -f1)
  [ "$hash" != "$(jq -r '.last_gaps_hash' "$DIRECTOR_DIR/$id/state.json")" ] \
    || { fm_director_block "$id" "gap analysis rediscovered the identical findings as the previous cycle"; return 2; }
  cp "$file" "$DIRECTOR_DIR/$id/gaps.md"
  fm_director_count_inc "$id" iteration
  fm_director_count_inc "$id" gap_cycles
  iteration=$(jq -r '.iteration' "$DIRECTOR_DIR/$id/state.json")
  gap_cycles=$(jq -r '.gap_cycles' "$DIRECTOR_DIR/$id/state.json")
  [ "$iteration" -lt "$FM_DIRECTOR_MAX_ITERATIONS" ] || { fm_director_block "$id" "max replan iterations reached ($iteration)"; return 2; }
  [ "$gap_cycles" -lt "$FM_DIRECTOR_MAX_GAP_CYCLES" ] || { fm_director_block "$id" "max consecutive gap cycles reached ($gap_cycles)"; return 2; }
  tmp=$(jq --arg h "$hash" '.last_gaps_hash=$h | .phase="execute"' "$DIRECTOR_DIR/$id/state.json")
  printf '%s\n' "$tmp" > "$DIRECTOR_DIR/$id/state.json"
  fm_director_history_append "$id" "$(jq -cn --arg t "$(fm_director_now)" --argjson n "$iteration" '{ts:$t,event:"gaps",cycle:$n}')"
  fm_director_state_touch "$id"
  echo "gaps adopted: replan cycle $iteration, phase -> execute"
}

fm_director_cmd_accept() {  # <id>
  local id=$1 tmp
  fm_director_dir "$id" >/dev/null
  fm_director_require_phase "$id" "integrate validate gap"
  jq -e '[.tasks[] | select(.status != "done")] | length == 0' "$DIRECTOR_DIR/$id/plan.json" >/dev/null \
    || { echo "fm-project-director: acceptance requires every plan task to be done" >&2; return 2; }
  tmp=$(jq '.phase="complete" | .gap_cycles=0' "$DIRECTOR_DIR/$id/state.json")
  printf '%s\n' "$tmp" > "$DIRECTOR_DIR/$id/state.json"
  fm_director_history_append "$id" "$(jq -cn --arg t "$(fm_director_now)" '{ts:$t,event:"accept"}')"
  fm_director_state_touch "$id"
  echo "complete: $id - project acceptance verified by reviewer"
}
fm_director_cmd_block() {  # <id> <reason...>
  local id=$1; shift
  fm_director_dir "$id" >/dev/null
  fm_director_block "$id" "$*"
}

fm_director_cmd_step() {  # <id>
  local id=$1 dir phase dispatched_n ready_n pending_n
  dir=$(fm_director_dir "$id")
  phase=$(fm_director_state_read "$id")
  case "$phase" in
    complete|blocked) echo "phase: $phase (terminal; nothing to step)"; return 0 ;;
  esac
  case "$phase" in
    integrate|validate|gap)
      echo "review required: run reviewer-role review of project acceptance for $id, then record 'gaps <file>' or 'accept'"
      return 0
      ;;
  esac
  [ "$phase" = execute ] || { echo "fm-project-director: phase $phase is judgment work; use phase/plan-set" >&2; return 2; }
  if [ ! -f "$dir/plan.json" ]; then
    echo "fm-project-director: no plan yet; plan-set first" >&2; return 2
  fi
  ready_n=$(fm_director_ready_tasks "$id" | wc -l | tr -d ' ')
  if [ "$ready_n" -gt 0 ]; then
    local n=0 t
    while IFS= read -r t; do
      [ "$n" -ge "$FM_DIRECTOR_MAX_DISPATCH_PER_STEP" ] && break
      fm_director_cmd_dispatch "$id" "$t" || return 2
      n=$((n + 1))
    done < <(fm_director_ready_tasks "$id")
    echo "step: dispatched $n task(s)"
    return 0
  fi
  dispatched_n=$(jq -r '[.tasks[] | select(.status=="dispatched" or .status=="dispatching")] | length' "$dir/plan.json")
  if [ "$dispatched_n" -gt 0 ]; then
    echo "step: $dispatched_n task(s) in flight; reconcile with fm-crew-state.sh, then task-done/task-failed"
    return 0
  fi
  pending_n=$(jq -r '[.tasks[] | select(.status=="pending")] | length' "$dir/plan.json")
  if [ "$pending_n" -gt 0 ]; then
    fm_director_block "$id" "$pending_n task(s) pending but no deps can complete (failed deps make the DAG unsatisfiable); replan via plan-set or block"
    return 2
  fi
  local tmp
  tmp=$(jq '.phase="integrate"' "$dir/state.json")
  printf '%s\n' "$tmp" > "$dir/state.json"
  fm_director_state_touch "$id"
  echo "step: all tasks terminal, phase -> integrate (review required next)"
}


case "${1:-}" in
  start) shift; fm_director_cmd_start "$@" ;;
  list) fm_director_cmd_list ;;
  status) shift; fm_director_cmd_status "$1" ;;
  phase) shift; fm_director_cmd_phase "$@" ;;
  plan-set) shift; fm_director_cmd_plan_set "$@" ;;
  ready) shift; fm_director_cmd_ready "$1" ;;
  dispatch) shift; fm_director_cmd_dispatch "$@" ;;
  task-done) shift; fm_director_cmd_task_done "$@" ;;
  task-failed) shift; fm_director_cmd_task_failed "$@" ;;
  gaps) shift; fm_director_cmd_gaps "$@" ;;
  accept) shift; fm_director_cmd_accept "$1" ;;
  block) shift; fm_director_cmd_block "$@" ;;
  step) shift; fm_director_cmd_step "$1" ;;
  *)
    sed -n '3,30p' "${BASH_SOURCE[0]}" | grep -E '^# (Usage|fm-project)' >&2 || true
    [ -n "${1:-}" ] && echo "fm-project-director: unknown command ${1:-}" >&2
    exit 2
    ;;
esac
