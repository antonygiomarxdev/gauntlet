# shellcheck shell=bash
# Tests for bin/gauntlet and lib/core.sh.

test_version() {
  run "$G" --version
  assert_eq 0 "$STATUS" "status"
  assert_eq "gauntlet 0.1.0-dev" "$OUT" "output"
}

test_unknown_command() {
  run "$G" nope
  assert_eq 2 "$STATUS" "status"
  assert_contains "$OUT" "unknown command: nope"
}

test_config_last_wins() {
  mkrepo
  # shellcheck source=lib/core.sh
  # shellcheck disable=SC2153 # ROOT is set by test/lib.sh
  . "$ROOT/lib/core.sh"
  echo "touched=off" > .gauntlet/config
  echo "touched=on" >> .gauntlet/config
  assert_eq "on" "$(config_get touched)" "last value"
}

test_config_default_for_missing_key() {
  mkrepo
  # shellcheck source=lib/core.sh
  # shellcheck disable=SC2153 # ROOT is set by test/lib.sh
  . "$ROOT/lib/core.sh"
  echo "touched=on" > .gauntlet/config
  assert_eq "fallback" "$(config_get nokey fallback)" "default"
}

test_config_outside_repo_exits_2() {
  cd "$TMP" || fail "cd failed"
  run bash -c ". '$ROOT/lib/core.sh'; config_get touched"
  assert_eq 2 "$STATUS" "status"
  assert_contains "$OUT" "not inside a git repository"
}

# Harness tests: run copies of run.sh/lib.sh over throwaway test dirs so the
# real suite is never asked to judge its own harness.
harness_copy() {
  mkdir -p "$TMP/t" || fail "mkdir failed"
  cp "$ROOT/test/run.sh" "$ROOT/test/lib.sh" "$TMP/t/" || fail "cp failed"
}

test_harness_broken_file_fails() {
  harness_copy
  printf 'test_ok() { :; }\nif then\n' > "$TMP/t/broken.test.sh"
  run bash "$TMP/t/run.sh" broken
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "FAIL load"
}

test_harness_zero_tests_fails() {
  harness_copy
  printf 'helper() { :; }\n' > "$TMP/t/empty.test.sh"
  run bash "$TMP/t/run.sh" empty
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "no tests ran"
}

test_harness_unknown_group_exits_2() {
  run bash "$ROOT/test/run.sh" nope
  assert_eq 2 "$STATUS" "status"
  assert_contains "$OUT" "unknown test group: nope"
}

test_helper_failure_aborts_test() {
  run bash -c ". '$ROOT/test/lib.sh'; TMP='$TMP/h'; mkdir -p \"\$TMP\"; mkrepo; rule x bogus=1; echo REACHED"
  assert_not_contains "$OUT" "REACHED"
  [ "$STATUS" -ne 0 ] || fail "expected nonzero status"
}

test_mkrepo_cd_failure_aborts_test() {
  run bash -c ". '$ROOT/test/lib.sh'; TMP='/dev/null/nope'; mkrepo; echo REACHED"
  assert_not_contains "$OUT" "REACHED"
  [ "$STATUS" -ne 0 ] || fail "expected nonzero status"
}
