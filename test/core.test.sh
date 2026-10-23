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
