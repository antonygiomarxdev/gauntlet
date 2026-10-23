# shellcheck shell=bash
# shellcheck disable=SC2153 # ROOT and G are set by test/lib.sh
# Tests of the test harness itself: the environment it cleans, the portable
# watchdog, the BSD date double, and the suite run under a CI environment.

test_lib_unsets_ci_and_outer_git_variables() {
  run env CI=true GITHUB_HEAD_REF=feat/x GITHUB_BASE_REF=main GAUNTLET_TODAY=2000-01-01 \
    GIT_DIR=/nonexistent GIT_INDEX_FILE=/nonexistent GIT_PREFIX=sub/ RIPGREP_CONFIG_PATH=/nonexistent \
    bash -c ". '$ROOT/test/lib.sh'; echo \"CI=\${CI-unset} GITHUB_HEAD_REF=\${GITHUB_HEAD_REF-unset} GITHUB_BASE_REF=\${GITHUB_BASE_REF-unset} GAUNTLET_TODAY=\${GAUNTLET_TODAY-unset} GIT_DIR=\${GIT_DIR-unset} GIT_INDEX_FILE=\${GIT_INDEX_FILE-unset} GIT_PREFIX=\${GIT_PREFIX-unset} RIPGREP_CONFIG_PATH=\${RIPGREP_CONFIG_PATH-unset}\""
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_eq "CI=unset GITHUB_HEAD_REF=unset GITHUB_BASE_REF=unset GAUNTLET_TODAY=unset GIT_DIR=unset GIT_INDEX_FILE=unset GIT_PREFIX=unset RIPGREP_CONFIG_PATH=unset" "$OUT" "variables after lib.sh"
}

# The suite passes under a pull_request CI environment: GITHUB_HEAD_REF and CI are set
# in the environment of the run, and the exceptions group is the one that reads them.
test_exceptions_group_passes_under_ci_environment() {
  run env GITHUB_HEAD_REF=feat/x GITHUB_BASE_REF=main CI=true bash "$ROOT/test/run.sh" exceptions
  assert_eq 0 "$STATUS" "exceptions group under CI=true GITHUB_HEAD_REF=feat/x: $OUT"
  assert_not_contains "$OUT" "FAIL "
}

test_with_timeout_returns_124_when_killed() {
  local status=0
  with_timeout 1 sleep 10 || status=$?
  assert_eq 124 "$status" "a command that outlives its budget"
}

test_with_timeout_passes_status_and_output_through() {
  local status=0 out
  with_timeout 5 sh -c 'echo visible; exit 3' > "$TMP/out" || status=$?
  assert_eq 3 "$status" "exit status"
  assert_eq "visible" "$(cat "$TMP/out")" "output"
}

test_with_timeout_passes_stdin_through() {
  local out
  out=$(printf 'piped\n' | with_timeout 5 cat)
  assert_eq "piped" "$out" "stdin of the command"
}

# The real date is the one lib.sh recorded: under the shim on PATH, command -v date
# would name the shim itself.
test_bsd_date_double_has_no_nanoseconds() {
  local out
  out=$(GAUNTLET_REAL_DATE=${GAUNTLET_REAL_DATE:-$(command -v date)} "$ROOT/test/bsd-date/date" +%s%N)
  case "$out" in
    *N) ;;
    *) fail "date +%s%N should print a literal N, got [$out]" ;;
  esac
  assert_eq "$(date +%Y)" "$(GAUNTLET_REAL_DATE=${GAUNTLET_REAL_DATE:-$(command -v date)} "$ROOT/test/bsd-date/date" +%Y)" "other formats pass through"
}

# A run nested under the BSD date double (the exceptions meta test does this) must keep
# the real date. Before that was pinned, the inner run recorded the shim as the real
# date, and any date call in it then exec'd the shim forever. The probe does not call
# date itself, so the check fails cleanly instead of hanging.
test_nested_bsd_date_run_keeps_the_real_date() {
  printf '. "%s/test/lib.sh"\nbash "%s/inner.sh"\n' "$ROOT" "$TMP" > "$TMP/outer.sh"
  # shellcheck disable=SC2016 # the probe expands $GAUNTLET_REAL_DATE when it runs
  printf '. "%s/test/lib.sh"\necho "real=$GAUNTLET_REAL_DATE"\n' "$ROOT" > "$TMP/inner.sh"
  run env GAUNTLET_TEST_BSD_DATE=1 bash "$TMP/outer.sh"
  assert_eq 0 "$STATUS" "nested run: $OUT"
  assert_not_contains "$OUT" "bsd-date"
  assert_contains "$OUT" "real=/"
}
