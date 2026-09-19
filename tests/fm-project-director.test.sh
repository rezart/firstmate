#!/usr/bin/env bash
# tests/fm-project-director.test.sh - public CLI regression and convergence
# coverage for bin/fm-project-director.sh with a stubbed Firstmate toolchain.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-project-director) || exit 1
DIRECTOR="$ROOT/bin/fm-project-director.sh"

make_world() {  # <name>
  local name=$1
  local home=$TMP_ROOT/$name
  mkdir -p "$home/bin" "$home/repo" "$home/config"
  cat > "$home/bin/tasks" <<'EOF'
#!/usr/bin/env bash
printf 'tasks %s\n' "$*" >> "$FM_DIRECTOR_TEST_LOG"
[ "${1:-}" != show ]
EOF
  cat > "$home/bin/brief" <<'EOF'
#!/usr/bin/env bash
printf 'brief %s\n' "$*" >> "$FM_DIRECTOR_TEST_LOG"
mkdir -p "$FM_DATA_OVERRIDE/$1"
printf '## Captain\047s intent\n{TASK}\n\n## Firstmate spec\n{FIRSTMATE_SPEC}\n\nDelivery contract: mode=direct-PR\n' > "$FM_DATA_OVERRIDE/$1/brief.md"
EOF
  cat > "$home/bin/spawn" <<'EOF'
#!/usr/bin/env bash
printf 'spawn %s\n' "$*" >> "$FM_DIRECTOR_TEST_LOG"
EOF
  chmod +x "$home/bin/tasks" "$home/bin/brief" "$home/bin/spawn"
  printf '%s\n' "$home"
}

make_recovery_world() {  # <name> <spawn outcome>
  local home
  home=$(make_world "$1")
  cat > "$home/bin/tasks" <<'EOF'
#!/usr/bin/env bash
printf 'tasks %s\n' "$*" >> "$FM_DIRECTOR_TEST_LOG"
if [ "${1:-}" = show ]; then exit 1; fi
EOF
  cat > "$home/bin/spawn" <<EOF
#!/usr/bin/env bash
printf 'spawn %s\n' "\$*" >> "\$FM_DIRECTOR_TEST_LOG"
$2
EOF
  chmod +x "$home/bin/tasks" "$home/bin/spawn"
  printf '%s\n' "$home"
}

run_director() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME=$home FM_DATA_OVERRIDE=$home/data FM_STATE_OVERRIDE=$home/state FM_CONFIG_OVERRIDE=$home/config \
    FM_DIRECTOR_TASKS_AXI=$home/bin/tasks FM_DIRECTOR_BRIEF=$home/bin/brief \
    FM_DIRECTOR_SPAWN=$home/bin/spawn FM_DIRECTOR_TEST_LOG=$home/commands.log \
    "$DIRECTOR" "$@"
}

write_spec() {  # <home>
  cat > "$1/spec.md" <<'EOF'
# Notification service

Deliver notification fan-out.

Acceptance:
- Valid events fan out to all enabled channels.
- The integration test passes.
EOF
}

write_plan() {  # <home> <extra task JSON, optional>
  cat > "$1/plan.json" <<EOF
{
  "version": 1,
  "project": "notification-service",
  "repo": "$1/repo",
  "mode": "direct-PR",
  "yolo": "off",
  "acceptance": ["Valid events fan out to all enabled channels.", "The integration test passes."],
  "tasks": [
    {"id":"schema","title":"Event schema","objective":"Define the event schema.","instructions":"Implement the schema.","context":"No prior task.","acceptance":["Schema tests pass."],"deps":[],"files":["src/schema/"],"validation":"make schema-test","profile":"crew","status":"pending"},
    {"id":"delivery","title":"Channel delivery","objective":"Deliver events.","instructions":"Implement channel delivery.","context":"Consumes the event schema.","acceptance":["Delivery tests pass."],"deps":["schema"],"files":["src/delivery/"],"validation":"make delivery-test","profile":"crew","status":"pending"}$2
  ]
}
EOF
}


# Explicit ids stay inside the director namespace.
HOME0=$(make_world traversal)
write_spec "$HOME0"
out=$(run_director "$HOME0" start "$HOME0/spec.md" --project ../../outside 2>&1 || true)
assert_contains "$out" "project id must be a lowercase slug" "start refuses project traversal"
assert_absent "$HOME0/outside" "start cannot create state outside director root"
pass "project id validation"
# State creation and plan validation.
HOME1=$(make_world state)
write_spec "$HOME1"
out=$(run_director "$HOME1" start "$HOME1/spec.md")
assert_contains "$out" "started: notification-service" "start derives id and persists state"
assert_present "$HOME1/data/director/notification-service/spec.md" "start persists verbatim spec"
assert_grep '"phase":"intake"' "$HOME1/data/director/notification-service/state.json" "start enters intake"

out=$(run_director "$HOME1" phase notification-service architecture)
assert_contains "$out" "intake -> architecture" "phase can advance to architecture"
write_plan "$HOME1" ""
out=$(run_director "$HOME1" plan-set notification-service "$HOME1/plan.json")
assert_contains "$out" "2 tasks, phase -> execute" "plan-set accepts a DAG and begins execution"
assert_contains "$(jq -r '.phase' "$HOME1/data/director/notification-service/state.json")" execute "plan state persisted"
pass "director persists intake and adopted plan"
# Dependency gating and resolved runtime history.
printf '{"roles":{"crew":{"harness":"claude","model":"haiku","effort":"low"},"reviewer":{"harness":"codex","model":"gpt-5.6","effort":"high"}}}' > "$HOME1/config/role-profiles.json"
out=$(run_director "$HOME1" ready notification-service)
assert_contains "$out" "schema" "root DAG task is ready"
assert_not_contains "$out" "delivery" "dependent DAG task is gated"

out=$(run_director "$HOME1" dispatch notification-service delivery 2>&1 || true)
assert_contains "$out" "unfinished deps" "dispatch refuses dependency violation"
out=$(run_director "$HOME1" step notification-service)
assert_contains "$out" "dispatched 1 task" "step dispatches ready task"
assert_grep 'tasks add notification-service-schema Event schema --kind task' "$HOME1/commands.log" "dispatch files ordinary backlog item"
assert_grep 'spawn notification-service-schema' "$HOME1/commands.log" "dispatch uses existing spawn interface"
assert_grep '--harness claude --model haiku --effort low' "$HOME1/commands.log" "crew profile resolves into spawn flags"
assert_grep '"harness":"claude"' "$HOME1/data/director/notification-service/history.jsonl" "history records concrete resolved runtime"
assert_grep '"profile":"crew"' "$HOME1/data/director/notification-service/history.jsonl" "plan uses logical profile in history"

# Retrying after a partial dispatch never files or launches the same task twice.
HOME5=$(make_recovery_world dispatch-failure 'exit 1')
write_spec "$HOME5"
run_director "$HOME5" start "$HOME5/spec.md" >/dev/null
run_director "$HOME5" phase notification-service architecture >/dev/null
write_plan "$HOME5" ""
run_director "$HOME5" plan-set notification-service "$HOME5/plan.json" >/dev/null
run_director "$HOME5" dispatch notification-service schema >/dev/null 2>&1 || true
run_director "$HOME5" dispatch notification-service schema >/dev/null 2>&1 || true
assert_contains "$(grep -c '^tasks add notification-service-schema' "$HOME5/commands.log")" 1 "retry after spawn failure does not duplicate backlog"
assert_contains "$(grep -c '^spawn notification-service-schema' "$HOME5/commands.log")" 2 "retry resumes the failed spawn"
pass "dispatch failure recovery"

# shellcheck disable=SC2016 # The nested spawn stub receives $1 as its task id.
HOME6=$(make_recovery_world dispatch-published 'mkdir -p "$FM_STATE_OVERRIDE"; : > "$FM_STATE_OVERRIDE/$1.meta"')
write_spec "$HOME6"
run_director "$HOME6" start "$HOME6/spec.md" >/dev/null
run_director "$HOME6" phase notification-service architecture >/dev/null
write_plan "$HOME6" ""
run_director "$HOME6" plan-set notification-service "$HOME6/plan.json" >/dev/null
run_director "$HOME6" dispatch notification-service schema >/dev/null
fm_director_status=$(jq -r '.tasks[] | select(.id=="schema") | .status' "$HOME6/data/director/notification-service/plan.json")
assert_contains "$fm_director_status" dispatched "published spawn persists dispatched state"
assert_contains "$(grep -c '^spawn notification-service-schema' "$HOME6/commands.log")" 1 "published spawn launches once"
pass "published dispatch recovery"
assert_grep 'Event schema' "$HOME1/data/notification-service-schema/brief.md" "brief receives task intent"
assert_grep 'Implement the schema.' "$HOME1/data/notification-service-schema/brief.md" "brief receives task instructions"
pass "dependency gating dispatch and runtime history"

# Convergence: dependency completes, dependent dispatches, review must decide.
run_director "$HOME1" task-done notification-service schema >/dev/null
out=$(run_director "$HOME1" step notification-service)
assert_contains "$out" "dispatched 1 task" "dependent task dispatches after dependency completes"
run_director "$HOME1" task-done notification-service delivery >/dev/null
out=$(run_director "$HOME1" step notification-service)
assert_contains "$out" "phase -> integrate" "all terminal DAG tasks transition to integration"
out=$(run_director "$HOME1" step notification-service)
assert_contains "$out" "review required" "integration cannot self-certify acceptance"
pass "task completion does not imply project completion"

# Gap analysis reopens execution and repeated findings block.
printf -- '- The integration criterion is unproven.\n' > "$HOME1/gaps.md"
out=$(run_director "$HOME1" gaps notification-service "$HOME1/gaps.md")
assert_contains "$out" "phase -> execute" "gaps open a replan cycle"
assert_contains "$(jq -r '.iteration' "$HOME1/data/director/notification-service/state.json")" 1 "gap cycle increments iteration"
out=$(run_director "$HOME1" step notification-service)
assert_contains "$out" "phase -> integrate" "completed original DAG returns to review after replan"
out=$(run_director "$HOME1" gaps notification-service "$HOME1/gaps.md" 2>&1 || true)
assert_contains "$out" "identical findings" "identical gaps block instead of looping"
assert_contains "$(jq -r '.phase' "$HOME1/data/director/notification-service/state.json")" blocked "block persists terminal state"
pass "gap cycles converge or block"


# A replan replaces the full DAG only after a review finding and dispatches its remediation.
HOME4=$(make_world replan)
write_spec "$HOME4"
run_director "$HOME4" start "$HOME4/spec.md" >/dev/null
run_director "$HOME4" phase notification-service architecture >/dev/null
write_plan "$HOME4" ""
run_director "$HOME4" plan-set notification-service "$HOME4/plan.json" >/dev/null
run_director "$HOME4" dispatch notification-service schema >/dev/null
run_director "$HOME4" task-done notification-service schema >/dev/null
run_director "$HOME4" dispatch notification-service delivery >/dev/null
run_director "$HOME4" task-done notification-service delivery >/dev/null
run_director "$HOME4" step notification-service >/dev/null
printf -- '- Add retry coverage.\n' > "$HOME4/gaps.md"
run_director "$HOME4" gaps notification-service "$HOME4/gaps.md" >/dev/null
write_plan "$HOME4" ',
    {"id":"retry","title":"Retry coverage","objective":"Cover retry behavior.","instructions":"Implement the retry coverage.","context":"Depends on delivery.","acceptance":["Retry test passes."],"deps":["delivery"],"files":["src/delivery/"],"validation":"make retry-test","profile":"crew","status":"pending"}'
out=$(run_director "$HOME4" plan-set notification-service "$HOME4/plan.json")
assert_contains "$out" "3 tasks, phase -> execute" "gap replan adopts revised full DAG"
out=$(run_director "$HOME4" ready notification-service)
assert_contains "$out" retry "only remediation task becomes ready after replan"
run_director "$HOME4" step notification-service >/dev/null
run_director "$HOME4" task-done notification-service retry >/dev/null
run_director "$HOME4" step notification-service >/dev/null
out=$(run_director "$HOME4" accept notification-service)
assert_contains "$out" "project acceptance verified by reviewer" "replanned project can reach acceptance"
pass "gap replan convergence"
# Explicit reviewer acceptance remains the only completion path.
out=$(run_director "$HOME1" phase notification-service execute)
assert_contains "$out" "-> execute" "phase command can re-arm a completed project"
run_director "$HOME1" step notification-service >/dev/null
out=$(run_director "$HOME1" accept notification-service)
assert_contains "$out" "project acceptance verified by reviewer" "only explicit acceptance completes project"
assert_contains "$(jq -r '.phase' "$HOME1/data/director/notification-service/state.json")" complete "complete is persisted"
pass "explicit reviewer acceptance completes project"

# Failure guard prevents a task from being retried indefinitely.
HOME2=$(make_world failures)
write_spec "$HOME2"
run_director "$HOME2" start "$HOME2/spec.md" >/dev/null
run_director "$HOME2" phase notification-service architecture >/dev/null
write_plan "$HOME2" ""
rm -f "$HOME2/data/director/notification-service/plan.json"
run_director "$HOME2" plan-set notification-service "$HOME2/plan.json" >/dev/null
run_director "$HOME2" dispatch notification-service schema >/dev/null
out=$(FM_DIRECTOR_MAX_TASK_FAILURES=1 run_director "$HOME2" task-failed notification-service schema 2>&1 || true)
assert_contains "$out" "task schema failed (attempt 1)" "failed task blocks project before integration"
assert_contains "$(jq -r '.phase' "$HOME2/data/director/notification-service/state.json")" blocked "failure guard persists block"
pass "failure budget protection"

# Invalid DAG is rejected before it can be adopted.
HOME3=$(make_world invalid)
write_spec "$HOME3"
run_director "$HOME3" start "$HOME3/spec.md" >/dev/null
run_director "$HOME3" phase notification-service architecture >/dev/null
cat > "$HOME3/bad-plan.json" <<EOF
{"repo":"$HOME3/repo","mode":"direct-PR","yolo":"off","acceptance":["x"],"tasks":[{"id":"a","deps":["missing"]}]}
EOF
out=$(run_director "$HOME3" plan-set notification-service "$HOME3/bad-plan.json" 2>&1 || true)
assert_contains "$out" "depends on unknown task missing" "plan-set rejects unknown dependencies"
pass "DAG validation"

echo "# fm-project-director: all cases passed"
