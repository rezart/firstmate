#!/usr/bin/env bash
# tests/fm-role-profile.test.sh - behavior of bin/fm-role-profile-lib.sh through
# its documented API: file resolution, per-axis precedence, secondmate
# fallthrough, class validation, and the no-file no-change regression.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-role-profile) || exit 1
export TMP_ROOT
resolve() {  # <home> <role> [<scope>]
  FM_HOME=$1 FM_ROLE_PROFILES_OVERRIDE='' bash -c \
    '. "$1/bin/fm-role-profile-lib.sh"; fm_role_profile_resolve "$2" "${3:-}"' _ "$ROOT" "$2" "${3:-}"
}

flags() {  # <home> <role> [<scope>]
  FM_HOME=$1 FM_ROLE_PROFILES_OVERRIDE='' bash -c \
    '. "$1/bin/fm-role-profile-lib.sh"; fm_role_profile_flags "$2" "${3:-}"' _ "$ROOT" "$2" "${3:-}"
}

mkprofiles() {  # <dir> <json>
  mkdir -p "$1/config"
  printf '%s' "$2" > "$1/config/role-profiles.json"
}

# --- file resolution --------------------------------------------------------

out=$(FM_HOME=$TMP_ROOT/h1 FM_ROLE_PROFILES_OVERRIDE='' bash -c '. "$1/bin/fm-role-profile-lib.sh"; fm_role_profiles_file' _ "$ROOT")
assert_contains "$out" "$TMP_ROOT/h1/config/role-profiles.json" "profiles file resolves under FM_HOME/config"

out=$(FM_ROLE_PROFILES_OVERRIDE=$TMP_ROOT/alt/role-profiles.json bash -c '. "$1/bin/fm-role-profile-lib.sh"; fm_role_profiles_file' _ "$ROOT")
assert_contains "$out" "$TMP_ROOT/alt/role-profiles.json" "FM_ROLE_PROFILES_OVERRIDE wins"

out=$(FM_CONFIG_OVERRIDE=$TMP_ROOT/cfg bash -c '. "$1/bin/fm-role-profile-lib.sh"; fm_role_profiles_file' _ "$ROOT")
assert_contains "$out" "$TMP_ROOT/cfg/role-profiles.json" "FM_CONFIG_OVERRIDE is the next fallback"
pass "file resolution precedence"

# --- no file: resolves nothing, callers pass no flags ------------------------

mkdir -p "$TMP_ROOT/empty"
out=$(FM_HOME=$TMP_ROOT/empty FM_ROLE_PROFILES_OVERRIDE='' resolve_unused=1 bash -c '. "$1/bin/fm-role-profile-lib.sh"; fm_role_profile_resolve director; fm_role_profile_resolve crew; fm_role_profile_flags reviewer' _ "$ROOT")
assert_contains "$out" "			none" "no file -> all roles resolve nothing"
expect_code 0 $? "no-file resolve exits 0"
pass "absent file keeps existing dispatch untouched (regression)"

# --- full profile resolution -------------------------------------------------

mkprofiles "$TMP_ROOT/full" '{"roles":{
  "director":{"harness":"codex","model":"gpt-5.6","effort":"high"},
  "firstmate":{"harness":"claude","model":"sonnet","effort":"medium"},
  "secondmate":{"harness":"codex","model":"gpt-5.5","effort":"medium"},
  "secondmate.backend":{"harness":"codex","model":"gpt-5.6","effort":"xhigh"},
  "crew":{"harness":"claude","model":"haiku","effort":"low"},
  "reviewer":{"harness":"codex","model":"gpt-5.6","effort":"high"}}}'

out=$(resolve "$TMP_ROOT/full" director)
assert_contains "$out" "$(printf 'codex\tgpt-5.6\thigh\tprofile')" "director resolves from profile"
out=$(resolve "$TMP_ROOT/full" crew)
assert_contains "$out" "$(printf 'claude\thaiku\tlow\tprofile')" "crew resolves from profile"
out=$(resolve "$TMP_ROOT/full" firstmate)
assert_contains "$out" "$(printf 'claude\tsonnet\tmedium\tprofile')" "firstmate role resolves"

out=$(flags "$TMP_ROOT/full" crew)
assert_contains "$out" " --harness claude --model haiku --effort low" "flags string carries resolved axes"
pass "profile entries resolve per axis"

# --- director/reviewer/crew are independent; reviewer != crew by config ------

out=$(resolve "$TMP_ROOT/full" reviewer)
assert_contains "$out" "$(printf 'codex\tgpt-5.6\thigh\tprofile')" "reviewer independent of crew profile"
pass "role independence"

# --- secondmate scope fallthrough --------------------------------------------

out=$(resolve "$TMP_ROOT/full" secondmate)
assert_contains "$out" "$(printf 'codex\tgpt-5.5\tmedium\tprofile')" "plain secondmate uses secondmate entry"
out=$(resolve "$TMP_ROOT/full" secondmate backend)
assert_contains "$out" "$(printf 'codex\tgpt-5.6\txhigh\tprofile')" "scoped secondmate.backend wins"

mkprofiles "$TMP_ROOT/nosm" '{"roles":{"firstmate":{"harness":"claude","model":"sonnet","effort":"medium"}}}'
out=$(resolve "$TMP_ROOT/nosm" secondmate)
assert_contains "$out" "$(printf 'claude\tsonnet\tmedium\tprofile')" "secondmate falls through to firstmate entry"

out=$(resolve "$TMP_ROOT/full" secondmate Backend)
assert_contains "$out" "$(printf 'codex\tgpt-5.6\txhigh\tprofile')" "natural-language secondmate scope normalizes to profile key"
pass "secondmate fallthrough secondmate.<scope> -> secondmate -> firstmate"

# --- partial profile leaves unset axes empty ---------------------------------

mkprofiles "$TMP_ROOT/part" '{"roles":{"scout":{"harness":"grok"}}}'
out=$(resolve "$TMP_ROOT/part" scout)
assert_contains "$out" "$(printf 'grok\t\t\tprofile')" "partial profile leaves axes unset"
out=$(flags "$TMP_ROOT/part" scout)
assert_contains "$out" " --harness grok" "flags carry only the resolved axis"
assert_not_contains "$out" "--model" "unset model axis emits no flag"
assert_not_contains "$out" "--effort" "unset effort axis emits no flag"
pass "partial profiles"

# --- override precedence ------------------------------------------------------

out=$(FM_HOME=$TMP_ROOT/full FM_ROLE_PROFILES_OVERRIDE='' FM_ROLE_MODEL=custom bash -c \
  '. "$1/bin/fm-role-profile-lib.sh"; fm_role_profile_resolve director' _ "$ROOT")
assert_contains "$out" "$(printf 'codex\tcustom\thigh\tprofile+override')" "env override beats profile per axis"

out=$(FM_HOME=$TMP_ROOT/empty FM_ROLE_PROFILES_OVERRIDE='' FM_ROLE_HARNESS=pi FM_ROLE_MODEL=m FM_ROLE_EFFORT=low bash -c \
  '. "$1/bin/fm-role-profile-lib.sh"; fm_role_profile_resolve crew' _ "$ROOT")
assert_contains "$out" "$(printf 'pi\tm\tlow\toverride')" "override works with no file"
pass "override precedence"

# --- validation refuses loudly -------------------------------------------------

out=$(FM_HOME=$TMP_ROOT/empty FM_ROLE_PROFILES_OVERRIDE='' bash -c '. "$1/bin/fm-role-profile-lib.sh"; fm_role_profile_resolve bogus; echo rc=$?' _ "$ROOT" 2>&1)
assert_contains "$out" "unknown role bogus" "unknown role refused"
assert_contains "$out" "rc=2" "unknown role exits 2"

out=$(FM_HOME=$TMP_ROOT/full FM_ROLE_PROFILES_OVERRIDE='' FM_ROLE_HARNESS=gemini bash -c \
  '. "$1/bin/fm-role-profile-lib.sh"; fm_role_profile_resolve secondmate; echo rc=$?' _ "$ROOT" 2>&1)
assert_contains "$out" "cannot run harness gemini" "crew-only harness refused for primary role"
assert_contains "$out" "rc=2" "class violation exits 2"

out=$(FM_HOME=$TMP_ROOT/full FM_ROLE_PROFILES_OVERRIDE='' FM_ROLE_HARNESS=gemini bash -c \
  '. "$1/bin/fm-role-profile-lib.sh"; fm_role_profile_resolve scout; echo rc=$?' _ "$ROOT" 2>&1)
assert_contains "$out" "$(printf 'gemini\t\t\tprofile+override')" "crew-only harness allowed for worker role"

out=$(FM_HOME=$TMP_ROOT/full FM_ROLE_PROFILES_OVERRIDE='' FM_ROLE_EFFORT=turbo bash -c \
  '. "$1/bin/fm-role-profile-lib.sh"; fm_role_profile_resolve crew; echo rc=$?' _ "$ROOT" 2>&1)
assert_contains "$out" "invalid effort turbo" "invalid effort refused"
assert_contains "$out" "rc=2" "invalid effort exits 2"

mkdir -p "$TMP_ROOT/bad/config"; printf 'not json' > "$TMP_ROOT/bad/config/role-profiles.json"
out=$(FM_HOME=$TMP_ROOT/bad FM_ROLE_PROFILES_OVERRIDE='' bash -c \
  '. "$1/bin/fm-role-profile-lib.sh"; fm_role_profile_resolve crew; echo rc=$?' _ "$ROOT" 2>&1)
assert_contains "$out" "not a valid role-profile file" "malformed file refused"
assert_contains "$out" "rc=2" "malformed file exits 2"

mkprofiles "$TMP_ROOT/bad-entry" '{"roles":{"crew":"bad"}}'
out=$(FM_HOME=$TMP_ROOT/bad-entry FM_ROLE_PROFILES_OVERRIDE='' bash -c \
  '. "$1/bin/fm-role-profile-lib.sh"; fm_role_profile_resolve crew; echo rc=$?' _ "$ROOT" 2>&1)
assert_contains "$out" "not a valid role-profile file" "string role entry refused"
assert_contains "$out" "rc=2" "string role entry exits 2"

mkprofiles "$TMP_ROOT/bad-axis" '{"roles":{"crew":{"effort":2}}}'
out=$(FM_HOME=$TMP_ROOT/bad-axis FM_ROLE_PROFILES_OVERRIDE='' bash -c \
  '. "$1/bin/fm-role-profile-lib.sh"; fm_role_profile_resolve crew; echo rc=$?' _ "$ROOT" 2>&1)
assert_contains "$out" "not a valid role-profile file" "non-string profile axis refused"
assert_contains "$out" "rc=2" "non-string profile axis exits 2"

mkprofiles "$TMP_ROOT/bad-scope" '{"roles":{"secondmate.Bad_scope":{"model":"x"}}}'
out=$(FM_HOME=$TMP_ROOT/bad-scope FM_ROLE_PROFILES_OVERRIDE='' bash -c \
  '. "$1/bin/fm-role-profile-lib.sh"; fm_role_profile_resolve secondmate backend; echo rc=$?' _ "$ROOT" 2>&1)
assert_contains "$out" "not a valid role-profile file" "invalid scoped role key refused"
assert_contains "$out" "rc=2" "invalid scoped role key exits 2"
pass "loud validation posture"

# --- config change does not need any migration --------------------------------

sed 's/"haiku"/"new-model"/' "$TMP_ROOT/full/config/role-profiles.json" > "$TMP_ROOT/full/config/role-profiles.json.new"
mv "$TMP_ROOT/full/config/role-profiles.json.new" "$TMP_ROOT/full/config/role-profiles.json"
out=$(resolve "$TMP_ROOT/full" crew)
assert_contains "$out" "new-model" "config edit is visible on next resolve, no invalidation step"
pass "resolution is read-at-dispatch"

echo "# fm-role-profile: all cases passed"
