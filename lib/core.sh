# shellcheck shell=bash
# Core helpers shared by every gauntlet command. Sourced, never executed.
# Bash 3.2 compatible. Uses only bash, awk, git and coreutils.

# shellcheck disable=SC2034 # read by bin/gauntlet
GAUNTLET_VERSION=0.1.0-dev

# die <msg> [code=2]: report on stderr and exit.
die() {
  printf 'gauntlet: %s\n' "$1" >&2
  exit "${2:-2}"
}

# tmp_new [-d]: create a temp file, or a directory with -d, and print its path. Under
# the run root GAUNTLET_TMP when bin/gauntlet made one (its trap removes the root on
# every exit and on INT, TERM and HUP, R33); under TMPDIR when a library is used alone.
tmp_new() {
  mktemp ${1+"$1"} "${GAUNTLET_TMP:-${TMPDIR:-/tmp}}/gauntlet.XXXXXX"
}

# gauntlet_cleanup: remove what the run made outside its own scratch and then the run
# root, GAUNTLET_TMP. bin/gauntlet runs it from its EXIT trap. It removes the root it
# was given and the one partial file registered, nothing else.
gauntlet_cleanup() {
  if [ -n "${GAUNTLET_PARTIAL:-}" ]; then rm -f "$GAUNTLET_PARTIAL"; fi
  if [ -n "${GAUNTLET_TMP:-}" ]; then rm -rf "$GAUNTLET_TMP"; fi
}

# partial_begin <path> / partial_end: name the one file a command writes next to its
# destination before it renames it into place, so gauntlet_cleanup removes it when a
# signal ends the run in between.
partial_begin() {
  GAUNTLET_PARTIAL=$1
}

partial_end() {
  GAUNTLET_PARTIAL=
}

# repo_root: print the absolute path of the top-level working tree.
repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || die "not inside a git repository"
}

# config_get <key> [default]: print the last value set for key in
# .gauntlet/config (key=value lines, # comments skipped), or the default.
config_get() {
  local root file value
  root=$(repo_root) || exit 2
  file="$root/.gauntlet/config"
  if [ -f "$file" ] && value=$(awk -v k="$1" '
    /^[[:space:]]*#/ { next }
    {
      eq = index($0, "=")
      if (eq == 0) { next }
      key = substr($0, 1, eq - 1)
      gsub(/^[ \t]+|[ \t]+$/, "", key)
      if (key != k) { next }
      val = substr($0, eq + 1)
      gsub(/^[ \t]+|[ \t]+$/, "", val)
      last = val
      found = 1
    }
    END { if (!found) exit 1; print last }
  ' "$file"); then
    printf '%s\n' "$value"
  else
    printf '%s\n' "${2-}"
  fi
}

# now_ms: print the current time in milliseconds. Falls back to seconds x 1000
# where date does not support %N (macOS prints a literal N).
now_ms() {
  local t
  t=$(date +%s%N 2>/dev/null) || t=""
  case "$t" in
    ""|*N*) printf '%s000\n' "$(date +%s)" ;;
    *) printf '%s\n' "$((t / 1000000))" ;;
  esac
}
