# shellcheck shell=bash
# Shared helpers for the fixture-based test suite. Sourced by test/run.sh.
# Bash 3.2 compatible.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC2034 # read by test files
G="$ROOT/bin/gauntlet"

# Test repos must not inherit the developer's global hooks or signing.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1
# Hooks export these; a suite run from inside a hook must not reach the real repo.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

# mkrepo: create $TMP/repo on branch main with a gauntlet skeleton and one
# commit, then cd into it.
mkrepo() {
  must mkdir -p "$TMP/repo"
  must cd "$TMP/repo"
  must git init -q .
  must git symbolic-ref HEAD refs/heads/main
  must git config user.name "Test User"
  must git config user.email "test@example.com"
  must git config commit.gpgsign false
  must mkdir -p .gauntlet/rules
  must touch .gauntlet/config .gauntlet/baseline.tsv .gauntlet/exceptions.tsv
  must git add -A
  must git commit -q -m "init"
}

# must <cmd...>: run a command; abort the test if it fails.
must() {
  "$@" || fail "command failed: $*"
}

# rule <id> [key=value ...]: write .gauntlet/rules/<id>.md (flat front matter).
rule() {
  local id=$1
  shift
  local severity=block stage=commit engine=rg paths='**' exclude='' format=''
  local detector="rg --with-filename --line-number --no-heading 'TODO' {files}"
  local fix='remove it' source=pending since=2026-10-22
  local kv
  for kv in "$@"; do
    case "$kv" in
      severity=*) severity=${kv#severity=} ;;
      stage=*) stage=${kv#stage=} ;;
      engine=*) engine=${kv#engine=} ;;
      detector=*) detector=${kv#detector=} ;;
      paths=*) paths=${kv#paths=} ;;
      exclude=*) exclude=${kv#exclude=} ;;
      format=*) format=${kv#format=} ;;
      fix=*) fix=${kv#fix=} ;;
      source=*) source=${kv#source=} ;;
      since=*) since=${kv#since=} ;;
      *) fail "rule: unknown key in $kv" ;;
    esac
  done
  must mkdir -p .gauntlet/rules
  {
    echo "---"
    echo "id: $id"
    echo "severity: $severity"
    echo "stage: $stage"
    echo "engine: $engine"
    echo "detector: $detector"
    echo "paths: $paths"
    echo "exclude: $exclude"
    if [ -n "$format" ]; then echo "format: $format"; fi
    echo "fix: $fix"
    echo "source: $source"
    echo "since: $since"
    echo "---"
    echo "Fixture rule $id."
  } > ".gauntlet/rules/$id.md" || fail "cannot write rule $id"
}

# run <cmd...>: run a command, capturing combined output in $OUT and status in $STATUS.
run() {
  # shellcheck disable=SC2034 # read by test files
  OUT=$("$@" 2>&1)
  # shellcheck disable=SC2034 # read by test files
  STATUS=$?
}

# fail <msg>: abort the current test (each test runs in its own subshell).
fail() {
  echo "$1" >&2
  exit 1
}

# assert_eq <expected> <actual> [label]
assert_eq() {
  if [ "$1" != "$2" ]; then
    fail "${3:+$3: }expected [$1] got [$2]"
  fi
}

# assert_contains <haystack> <needle>
assert_contains() {
  case "$1" in
    *"$2"*) ;;
    *) fail "expected output to contain [$2], got [$1]" ;;
  esac
}

# assert_not_contains <haystack> <needle>
assert_not_contains() {
  case "$1" in
    *"$2"*) fail "expected output not to contain [$2], got [$1]" ;;
    *) ;;
  esac
}
