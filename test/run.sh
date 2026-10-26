#!/usr/bin/env bash
# Usage: test/run.sh [group]
# Runs test/<group>.test.sh (or every test/*.test.sh). Each test_* function runs
# in its own subshell with a fresh $TMP that is removed afterwards.
# Exits 0 only when every test passes and at least one test ran.
# Bash 3.2 compatible.
set -u

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=test/lib.sh
. "$TEST_DIR/lib.sh"

run_one() {
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/gauntlet-test.XXXXXX") || return 1
  TMP=$(cd "$TMP" && pwd -P) || return 1
  trap 'rm -rf "$TMP"' EXIT
  "$1"
}

if [ "$#" -gt 0 ]; then
  if [ ! -f "$TEST_DIR/$1.test.sh" ]; then
    echo "unknown test group: $1" >&2
    exit 2
  fi
  files="$TEST_DIR/$1.test.sh"
else
  files=$(ls "$TEST_DIR"/*.test.sh)
fi

failed=0
ran=0
skipped=0
for f in $files; do
  # shellcheck source=/dev/null # test files are chosen at runtime
  . "$f" || { echo "FAIL load $f"; failed=$((failed + 1)); continue; }
  for name in $(compgen -A function | grep '^test_'); do
    ran=$((ran + 1))
    status=0
    err=$(run_one "$name" 2>&1) || status=$?
    if [ "$status" -eq 0 ]; then
      echo "ok $name"
    elif [ "$status" -eq 77 ]; then
      echo "SKIP $name: $err"
      skipped=$((skipped + 1))
    else
      echo "FAIL $name: ${err:-exit status $status}"
      failed=$((failed + 1))
    fi
  done
  for name in $(compgen -A function | grep '^test_'); do
    unset -f "$name"
  done
done

if [ "$ran" -eq 0 ]; then
  echo "FAIL no tests ran" >&2
  failed=$((failed + 1))
fi
if [ "$skipped" -gt 0 ]; then
  echo "skipped: $skipped (see SKIP lines above)"
fi

[ "$failed" -eq 0 ]
