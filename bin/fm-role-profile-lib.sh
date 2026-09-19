#!/usr/bin/env bash
# shellcheck shell=bash
# fm-role-profile-lib.sh - the single owner of role-based runtime resolution
# (harness / model / effort) across the orchestration hierarchy: director,
# firstmate, secondmate, crew, scout, and reviewer.
#
# Sourced, never executed. It answers exactly one question: "which concrete
# harness/model/effort axes does this role resolve to right now?" Precedence
# per axis:
#
#   1. explicit override, via FM_ROLE_HARNESS / FM_ROLE_MODEL / FM_ROLE_EFFORT
#   2. the role's entry in config/role-profiles.json
#      (secondmate additionally falls through "secondmate.<scope>" ->
#       "secondmate" -> "firstmate" entries before giving up)
#   3. unset axis: the caller passes no flag for that axis to fm-spawn.sh, so
#      Firstmate's EXISTING static resolution (crew-dispatch judgment at
#      intake, config/crew-harness, config/secondmate-harness) still owns it.
#
# This keeps today's dispatch behavior byte-identical when no profile file
# exists: the library resolves nothing, callers pass no new flags.
#
# File format (config/role-profiles.json, local, gitignored, optional):
#   {"roles": {
#     "director":   {"harness": "codex", "model": "gpt-5.6", "effort": "high"},
#     "firstmate":  {"harness": "claude", "model": "sonnet", "effort": "medium"},
#     "secondmate": {"harness": "codex", "model": "gpt-5.5", "effort": "medium"},
#     "secondmate.backend": {"harness": "codex", "model": "gpt-5.6", "effort": "xhigh"},
#     "crew":       {"harness": "claude", "model": "haiku", "effort": "low"},
#     "scout":      {"harness": "claude", "model": "haiku", "effort": "low"},
#     "reviewer":   {"harness": "codex", "model": "gpt-5.6", "effort": "high"}
#   }}
# Every axis is optional; a partial profile leaves the unset axes on the
# existing static path. "secondmate.<scope>" addresses one domain secondmate.
#
# Role classes constrain valid harness names (docs/configuration.md "Harness
# support" owns the verified sets):
#   director reviewer crew scout -> worker set (primaries plus gemini/muse/rovo/agy)
#   firstmate secondmate         -> primary set only
# The firstmate role cannot switch an already-running primary session; it is
# consumed by secondmate delegation (a secondmate home runs a firstmate) and by
# status display. docs/project-director.md owns that limitation.
#
# API (all print to stdout; errors print one stderr line and return 2):
#   fm_role_profiles_file              -> the profile file path for this home
#   fm_role_profile_resolve <role> [<scope>]
#     -> "harness<TAB>model<TAB>effort<TAB>source"; an unset axis is empty and
#        source is override|profile|profile+override|none
#   fm_role_profile_flags <role> [<scope>]
#     -> a ready-to-append " --harness h --model m --effort e" flag string
#        containing ONLY the resolved axes (empty string when none resolve)
# A malformed profile file, unknown role, unknown harness, or invalid effort is
# a loud error, never silently ignored (same posture as CREW_DISPATCH).

FM_ROLE_PROFILE_EFFORTS=" low medium high xhigh max ultra "

fm_role_profiles_file() {
  local script_dir root home
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  root=${FM_ROOT_OVERRIDE:-$(cd "$script_dir/.." && pwd)}
  home=${FM_HOME:-$root}
  printf '%s/role-profiles.json\n' "${FM_ROLE_PROFILES_OVERRIDE:-${FM_CONFIG_OVERRIDE:-$home/config}}"
}

# Verified harness sets. The worker set adds gemini/muse/rovo/agy, which are
# verified for crewmates and scouts only, never for primaries.
fm_role_profile_harness_ok() {  # <class: worker|primary> <harness>
  case "$2" in
    claude|codex|opencode|pi|pi-signed|grok|kimi|cursor|omp) return 0 ;;
    gemini|muse|rovo|agy) [ "$1" = worker ] ;;
    *) return 1 ;;
  esac
}

fm_role_profile_axis() {  # <file> <key> <axis> -> value or empty
  jq -r --arg k "$2" --arg a "$3" '.roles[$k][$a] // empty' "$1" 2>/dev/null
}

# Normalize a registry's natural-language secondmate scope into a profile key.
fm_role_profile_scope_key() {  # <scope>
  printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed -e 's/^-*//' -e 's/-*$//'
}

# Candidate profile keys for one role/scope, most specific first.
fm_role_profile_keys() {  # <role> <scope>
  local scope
  scope=$(fm_role_profile_scope_key "${2:-}")
  if [ "$1" = secondmate ] && [ -n "$scope" ]; then
    printf '%s\nsecondmate\nfirstmate\n' "secondmate.$scope"
  elif [ "$1" = secondmate ]; then
    printf '%s\nfirstmate\n' secondmate
  else
    printf '%s\n' "$1"
  fi
}

fm_role_profile_resolve() {  # <role> [<scope>]
  local role=${1:-} scope=${2:-} class file key
  local harness model effort val src
  local src_h='' src_m='' src_e=''
  case "$role" in
    director|reviewer|crew|scout) class=worker ;;
    firstmate|secondmate) class=primary ;;
    *)
      printf 'fm-role-profile: unknown role %s\n' "$role" >&2
      return 2
      ;;
  esac
  harness=${FM_ROLE_HARNESS:-}
  model=${FM_ROLE_MODEL:-}
  effort=${FM_ROLE_EFFORT:-}
  [ -n "$harness" ] && src_h=override
  [ -n "$model" ] && src_m=override
  [ -n "$effort" ] && src_e=override

  file=$(fm_role_profiles_file)
  if [ -f "$file" ]; then
    if ! jq -e '(.roles | type) == "object" and ([.roles | keys[] | test("^(director|reviewer|crew|scout|firstmate|secondmate|secondmate\\.[a-z0-9]+(-[a-z0-9]+)*)$")] | all) and ([.roles[] | type == "object"] | all) and ([.roles[] | to_entries[]? | select((.key == "harness" or .key == "model" or .key == "effort") and (.value | type != "string"))] | length == 0)' "$file" >/dev/null 2>&1; then
      printf 'fm-role-profile: %s is not a valid role-profile file (expected role objects with string harness/model/effort axes)\n' "$file" >&2
      return 2
    fi
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      if [ -z "$harness" ]; then
        val=$(fm_role_profile_axis "$file" "$key" harness)
        if [ -n "$val" ]; then harness=$val; src_h=profile; fi
      fi
      if [ -z "$model" ]; then
        val=$(fm_role_profile_axis "$file" "$key" model)
        if [ -n "$val" ]; then model=$val; src_m=profile; fi
      fi
      if [ -z "$effort" ]; then
        val=$(fm_role_profile_axis "$file" "$key" effort)
        if [ -n "$val" ]; then effort=$val; src_e=profile; fi
      fi
      [ -n "$harness" ] && [ -n "$model" ] && [ -n "$effort" ] && break
    done < <(fm_role_profile_keys "$role" "$scope")
  fi

  if [ -n "$harness" ] && ! fm_role_profile_harness_ok "$class" "$harness"; then
    printf 'fm-role-profile: role %s cannot run harness %s (class %s)\n' "$role" "$harness" "$class" >&2
    return 2
  fi
  if [ -n "$effort" ]; then
    case "$FM_ROLE_PROFILE_EFFORTS" in
      *" $effort "*) ;;
      *)
        printf 'fm-role-profile: invalid effort %s (expected one of low medium high xhigh max ultra)\n' "$effort" >&2
        return 2
        ;;
    esac
  fi

  if [ -n "$src_h" ] || [ -n "$src_m" ] || [ -n "$src_e" ]; then
    case "$src_h$src_m$src_e" in
      overrideoverrideoverride) src=override ;;
      *override*) src=profile+override ;;
      *) src=profile ;;
    esac
  else
    src=none
  fi
  printf '%s\t%s\t%s\t%s\n' "$harness" "$model" "$effort" "$src"
}

# Ready-to-append flag string with ONLY the resolved axes; empty when none.
# Callers append it unquoted to an fm-spawn.sh argument list.
fm_role_profile_flags() {  # <role> [<scope>]
  local out h m e rest tab flags=
  tab=$(printf '\t')
  out=$(fm_role_profile_resolve "$@") || return 2
  h=${out%%"$tab"*}
  rest=${out#*"$tab"}
  m=${rest%%"$tab"*}
  rest=${rest#*"$tab"}
  e=${rest%%"$tab"*}
  [ -n "$h" ] && flags="$flags --harness $h"
  [ -n "$m" ] && flags="$flags --model $m"
  [ -n "$e" ] && flags="$flags --effort $e"
  printf '%s\n' "$flags"
}
