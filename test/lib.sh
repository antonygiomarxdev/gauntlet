# shellcheck shell=bash
# Shared helpers for the fixture-based test suite. Sourced by test/run.sh.
# Bash 3.2 compatible.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC2034 # read by test files
G="$ROOT/bin/gauntlet"

# The suite must not depend on the machine or the CI runner it runs on. A runner's
# CI, GITHUB_* and GAUNTLET_* variables change which checks run (a pull_request event
# sets GITHUB_HEAD_REF), RIPGREP_CONFIG_PATH changes what rg prints, and a hook
# exports GIT_* that point at the real repo. Unset them all before any test runs.
unset CI GITHUB_HEAD_REF GITHUB_BASE_REF GITHUB_REF GITHUB_REF_NAME
unset GAUNTLET_TODAY GAUNTLET_COMMIT_BUDGET_MS RIPGREP_CONFIG_PATH
for name in $(compgen -e); do
  case "$name" in GIT_*) unset "$name" ;; esac
done

# Test repos must not inherit the developer's global hooks or signing.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1

# GAUNTLET_TEST_BSD_DATE=1 puts test/bsd-date first on PATH: its date has no %N,
# as macOS's does, so the runner's clock fallback runs on Linux too.
if [ "${GAUNTLET_TEST_BSD_DATE:-}" = 1 ]; then
  # A nested run (the harness runs the exceptions group under this one) inherits
  # the shim on PATH: keep the real date recorded above it, or the shim would name
  # itself and exec forever.
  if [ -z "${GAUNTLET_REAL_DATE:-}" ]; then GAUNTLET_REAL_DATE=$(command -v date); fi
  export GAUNTLET_REAL_DATE
  case ":$PATH:" in
    *":$ROOT/test/bsd-date:"*) ;;
    *) PATH="$ROOT/test/bsd-date:$PATH" ;;
  esac
  export PATH
fi

# hook_const <NAME>: the value of a constant that lib/hooks.sh defines (HOOK_GATE_CI,
# GAUNTLET_CMD_CI, HOOK_SHARED_CI, ...). A test that compares with a hook line asks for it here, so
# the text of a gate line has one source; a test never pastes the pre-push command. Read in a
# subshell, so nothing of the library leaks into the suite.
hook_const() {
  ( . "$ROOT/lib/hooks.sh" && printf '%s' "${!1}" )
}

# kill_tree <pid>: kill <pid> and everything it started, the youngest first. A bash that waits
# for a command substitution holds a TERM trap until it ends, so killing only the top process
# leaves a runaway chain of subshells running.
kill_tree() {
  local child
  for child in $(pgrep -P "$1" 2> /dev/null); do kill_tree "$child"; done
  kill "$1" 2> /dev/null
}

# with_timeout <seconds> <cmd...>: run cmd and kill it, and what it started, once <seconds>
# have passed; returns 124 when it was killed, else cmd's status. A background sleep and kill,
# because macOS has no GNU timeout. stdin is passed through: a background job would
# otherwise read /dev/null.
with_timeout() {
  local secs=$1 flag pid watcher rc=0
  shift
  flag=$(mktemp "${TMPDIR:-/tmp}/gauntlet-watch.XXXXXX") || return 1
  "$@" <&0 &
  pid=$!
  (
    sleep "$secs" &
    sleeper=$!
    trap 'kill "$sleeper" 2>/dev/null; exit 0' TERM
    if wait "$sleeper"; then echo x > "$flag"; kill_tree "$pid"; fi
  ) > /dev/null 2>&1 &
  watcher=$!
  wait "$pid" || rc=$?
  kill "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null
  if [ -s "$flag" ]; then rc=124; fi
  rm -f "$flag"
  return "$rc"
}

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

# cases_of <id> <bad line>: a bad case that the rule must flag and a good case it
# must not. Rule tests run only when a rule or format changes (R5), so a rule
# added on a branch needs its cases on that branch.
cases_of() {
  printf '%s\n' "$2" > ".gauntlet/rules/$1.bad.txt"
  printf 'ok\n' > ".gauntlet/rules/$1.good.txt"
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

# script_row <rule-id>: approve engine=script for a rule with a script row, as a
# maintainer would by hand (no command writes one).
script_row() {
  if [ ! -s .gauntlet/exceptions.tsv ]; then
    printf 'type\ttarget\treason\tdate\tbranch\n' > .gauntlet/exceptions.tsv || fail "cannot write exceptions.tsv"
  fi
  printf 'script\t%s\tfixture\t2026-10-22\t-\n' "$1" >> .gauntlet/exceptions.tsv || fail "cannot write exceptions.tsv"
}

# unreadable_object <rev:path>: delete the loose git object behind a path, so the
# tree still lists the path and git cannot read its content. Fails the test when the
# object is not loose or still reads, so a test never passes without a damaged object.
unreadable_object() {
  local oid obj
  oid=$(git rev-parse "$1") || fail "unreadable_object: no such path $1"
  obj=".git/objects/${oid:0:2}/${oid:2}"
  [ -f "$obj" ] || fail "unreadable_object: $1 is not a loose object"
  rm -f "$obj" || fail "unreadable_object: cannot remove $obj"
  if git cat-file -p "$oid" > /dev/null 2>&1; then fail "unreadable_object: $1 still reads"; fi
}

# git_fails <ls-tree|ls-files> <path> [<rev> [<nth>]]: put a git first on PATH that fails
# the <nth> listing of <path> (the first by default) and, when <rev> is given, only at <rev>,
# with a git error, as a damaged repository would, and runs every other call through the real
# git. Only that one, so a later read of the same path cannot stand in for the site under
# test, and <nth> reaches a site behind an earlier read of the same path.
git_fails() {
  local real
  real=$(command -v git) || fail "git_fails: no git on PATH"
  must mkdir -p "$TMP/shim"
  rm -f "$TMP/shim/count"
  cat > "$TMP/shim/git" <<'SHIM'
#!/bin/sh
cmd= ; path= ; rev= ; prev=
for a in "$@"; do
  case "$a" in ls-tree|ls-files) if [ -z "$cmd" ]; then cmd=$a; fi ;; esac
  if [ "$prev" = -- ]; then path=${a#":(top,literal)"}; fi
  if [ "$a" = -- ]; then rev=$prev; fi
  prev=$a
done
if [ "$cmd" = "$SHIM_CMD" ] && [ "$path" = "$SHIM_PATH" ] && { [ -z "$SHIM_REV" ] || [ "$rev" = "$SHIM_REV" ]; }; then
  n=$(cat "$SHIM_COUNT" 2>/dev/null || echo 0)
  n=$((n + 1))
  echo "$n" > "$SHIM_COUNT"
  if [ "$n" -eq "$SHIM_NTH" ]; then
    echo "fatal: simulated failure reading $path" >&2
    exit 128
  fi
fi
exec "$SHIM_REAL" "$@"
SHIM
  must chmod +x "$TMP/shim/git"
  export SHIM_REAL=$real SHIM_CMD=$1 SHIM_PATH=$2 SHIM_REV=${3:-} SHIM_NTH=${4:-1} SHIM_COUNT="$TMP/shim/count"
  PATH="$TMP/shim:$PATH"
  export PATH
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

# skip <reason>: report the calling test as skipped, not ok. The test then
# returns 77 at once (skip "..."; return 77). test/run.sh prints a SKIP line with
# the reason and does not count it as a failure.
skip() {
  printf '%s\n' "$1" >&2
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
