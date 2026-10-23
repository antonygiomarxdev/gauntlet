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

# A config saved with CRLF line ends reads the same as one with LF.
test_config_get_strips_a_carriage_return() {
  mkrepo
  # shellcheck source=lib/core.sh
  # shellcheck disable=SC2153 # ROOT is set by test/lib.sh
  . "$ROOT/lib/core.sh"
  printf 'base=origin/main\r\ntouched=on\r\n# note\r\n' > .gauntlet/config
  assert_eq "origin/main" "$(config_get base)" "base"
  assert_eq "on" "$(config_get touched)" "touched"
  assert_eq "fallback" "$(config_get nokey fallback)" "default"
  run "$G" base
  assert_eq "origin/main" "$OUT" "gauntlet base prints the value without the CR"
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

# R33: bin/gauntlet makes one temp root per run, puts every scratch file under it and removes
# it on exit and on INT, TERM and HUP. Each test runs with a private TMPDIR holding two
# decoys that look like gauntlet's own: the run must leave exactly those behind.
tmp_decoys() {
  must mkdir -p "$TMP/priv/gauntlet.other"
  printf 'keep\n' > "$TMP/priv/gauntlet.keep"
  printf 'keep\n' > "$TMP/priv/gauntlet.other/file"
}

tmp_left() {
  # shellcheck disable=SC2012 # the names are the fixed ones this test makes
  ls -A "$TMP/priv" | LC_ALL=C sort | tr '\n' ' '
}

tmp_assert_clean() {
  assert_eq "gauntlet.keep gauntlet.other " "$(tmp_left)" "$1: what the run left in TMPDIR"
  assert_eq "keep" "$(cat "$TMP/priv/gauntlet.other/file")" "$1: the decoy directory is untouched"
}

# tmp_repo <seconds>: a repo with a.ts in scope of a rule whose detector says it started and
# then sleeps while $TMP/slow exists.
tmp_repo() {
  mkrepo
  printf 'ok\n' > a.ts
  rule slow paths='**/*.ts' "detector=sh -c 'touch \"$TMP/started\"; if [ -e \"$TMP/slow\" ]; then sleep $1; fi' ignored {files}"
  cases_of slow 'TODO x'
  rule todo paths='**/*.ts'
  cases_of todo 'TODO x'
  must git add -A
  run "$G" baseline
  assert_eq 0 "$STATUS" "baseline: $OUT"
  must git add -A
  must git commit -q -m main
  must git checkout -q -b feat
  tmp_decoys
}

# tmp_signal <signal> <group|pid> <gauntlet args...>: start gauntlet in the background in a
# process group of its own (job control), wait for the detector to start, send the signal
# to the whole group (what Ctrl-C and a CI cancel do) or to gauntlet alone, wait. RC is its
# status.
tmp_signal() {
  local sig=$1 mode=$2 pid mark=${TMP_MARK:-$TMP/started}
  shift 2
  rm -f "$mark"
  : > "$TMP/slow"
  set -m
  TMPDIR="$TMP/priv" "$G" "$@" > "$TMP/run.out" 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do
    if [ -e "$mark" ]; then break; fi
    sleep 0.1
  done
  [ -e "$mark" ] || fail "gauntlet never reached the signal point: $(cat "$TMP/run.out")"
  if [ "$mode" = group ]; then kill -"$sig" -- "-$pid"; else kill -"$sig" "$pid"; fi
  RC=0
  wait "$pid" || RC=$?
  set +m
  rm -f "$TMP/slow"
}

# signal_deliverable <sig>: succeed when a shell started here dies of the signal. A job started
# with & from a script has SIGINT ignored, and nohup ignores SIGHUP; both are inherited by
# everything below, so no trap can be set and no signal can be sent to test them.
signal_deliverable() {
  [ "$(bash -c "kill -$1 \$\$; echo alive" 2> /dev/null)" != alive ]
}

test_sigterm_to_the_process_group_removes_the_temp_root() {
  tmp_repo 30
  tmp_signal TERM group check --ci --base main
  assert_eq 143 "$RC" "check --ci after SIGTERM: $(cat "$TMP/run.out")"
  tmp_assert_clean "SIGTERM"
  assert_eq "" "$(cat .gauntlet/baseline.tsv)" "an interrupted gate writes nothing"
}

test_sigint_to_the_process_group_removes_the_temp_root() {
  signal_deliverable INT || { skip "SIGINT is ignored here (a job started with &)"; return 77; }
  tmp_repo 30
  tmp_signal INT group check --ci --base main
  assert_eq 130 "$RC" "check --ci after SIGINT: $(cat "$TMP/run.out")"
  tmp_assert_clean "SIGINT"
}

test_sighup_to_the_process_group_removes_the_temp_root() {
  signal_deliverable HUP || { skip "SIGHUP is ignored here (nohup)"; return 77; }
  tmp_repo 30
  tmp_signal HUP group baseline
  assert_eq 129 "$RC" "baseline after SIGHUP: $(cat "$TMP/run.out")"
  tmp_assert_clean "SIGHUP"
  assert_eq "" "$(cat .gauntlet/baseline.tsv)" "an interrupted baseline writes nothing"
}

# bash runs a trap when the foreground command ends, so a signal sent to gauntlet alone
# is handled once the detector returns: the root is still removed and the status says why.
test_a_signal_to_gauntlet_alone_removes_the_temp_root_when_the_detector_returns() {
  tmp_repo 2
  tmp_signal TERM pid check --ci --base main
  assert_eq 143 "$RC" "check --ci after SIGTERM to the process: $(cat "$TMP/run.out")"
  tmp_assert_clean "SIGTERM to the process"
}

# The trap changes no exit status of a normal run, and a normal run leaves nothing.
test_normal_runs_keep_their_exit_status_and_leave_the_temp_dir_empty() {
  tmp_repo 0
  run env TMPDIR="$TMP/priv" "$G" check --ci --base main
  assert_eq 0 "$STATUS" "a passing gate: $OUT"
  tmp_assert_clean "check --ci"
  printf 'TODO x\n' > a.ts
  must git add a.ts
  run env TMPDIR="$TMP/priv" "$G" check --staged
  assert_eq 1 "$STATUS" "a failing gate: $OUT"
  assert_contains "$OUT" "[new]"
  tmp_assert_clean "check --staged"
  printf -- '---\nid: bad\n---\n' > .gauntlet/rules/bad.md
  run env TMPDIR="$TMP/priv" "$G" baseline
  assert_eq 2 "$STATUS" "a broken setup: $OUT"
  tmp_assert_clean "baseline"
  must rm .gauntlet/rules/bad.md
  local cmd
  for cmd in "test-rules" "doctor" "status" "base" "install-hooks"; do
    run env TMPDIR="$TMP/priv" "$G" $cmd
    tmp_assert_clean "$cmd (status $STATUS)"
  done
  run env TMPDIR="$TMP/priv" "$G" --version
  assert_eq 0 "$STATUS" "--version: $OUT"
  tmp_assert_clean "--version"
}

# Everything a run makes is inside its one root: while the detector runs, TMPDIR holds the
# decoys and a single other entry, named gauntlet.*.
test_a_run_keeps_all_scratch_inside_one_root() {
  tmp_repo 0
  rule spy paths='**/*.ts' "detector=sh -c 'ls -A \"\$TMPDIR\" > \"$TMP/during\"' ignored {files}"
  cases_of spy 'TODO x'
  run env TMPDIR="$TMP/priv" "$G" baseline
  assert_eq 0 "$STATUS" "baseline: $OUT"
  local extra
  extra=$(grep -v -x -e gauntlet.keep -e gauntlet.other "$TMP/during" | tr '\n' ' ')
  case "$extra" in
    gauntlet.??????\ ) ;;
    *) fail "TMPDIR held [$extra] besides the decoys during the run, expected one gauntlet.XXXXXX root" ;;
  esac
}

# gauntlet_cleanup removes the run root and the one registered partial file, nothing else.
test_cleanup_removes_the_root_and_the_registered_partial_file_only() {
  # shellcheck source=lib/core.sh
  . "$ROOT/lib/core.sh"
  must mkdir -p "$TMP/root/inner" "$TMP/sibling"
  printf 'x\n' > "$TMP/root/inner/f"
  printf 'x\n' > "$TMP/sibling/f"
  printf 'x\n' > "$TMP/dest.tmp"
  printf 'x\n' > "$TMP/dest"
  GAUNTLET_TMP="$TMP/root"
  partial_begin "$TMP/dest.tmp"
  gauntlet_cleanup
  [ ! -e "$TMP/root" ] || fail "the run root is still there"
  [ ! -e "$TMP/dest.tmp" ] || fail "the registered partial file is still there"
  [ -e "$TMP/sibling/f" ] || fail "cleanup removed a sibling of the root"
  [ -e "$TMP/dest" ] || fail "cleanup removed the destination"
  # Once the rename is done the file is no longer registered.
  printf 'x\n' > "$TMP/other"
  partial_begin "$TMP/other"
  partial_end
  gauntlet_cleanup
  [ -e "$TMP/other" ] || fail "cleanup removed a file that was no longer partial"
}

test_cleanup_without_a_root_removes_nothing() {
  # shellcheck source=lib/core.sh
  . "$ROOT/lib/core.sh"
  printf 'x\n' > "$TMP/keep"
  unset GAUNTLET_TMP GAUNTLET_PARTIAL
  gauntlet_cleanup
  [ -e "$TMP/keep" ] || fail "cleanup with no root removed a file"
}

# tmp_new falls back to TMPDIR when no run root exists (a library used alone).
test_tmp_new_uses_the_root_and_falls_back_to_tmpdir() {
  # shellcheck source=lib/core.sh
  . "$ROOT/lib/core.sh"
  must mkdir -p "$TMP/root" "$TMP/tmpdir"
  local p
  p=$(GAUNTLET_TMP="$TMP/root" TMPDIR="$TMP/tmpdir" tmp_new -d) || fail "tmp_new -d failed"
  case "$p" in "$TMP/root/gauntlet."*) ;; *) fail "expected a directory under the root, got [$p]" ;; esac
  [ -d "$p" ] || fail "tmp_new -d made no directory"
  p=$(unset GAUNTLET_TMP; TMPDIR="$TMP/tmpdir" tmp_new) || fail "tmp_new failed"
  case "$p" in "$TMP/tmpdir/gauntlet."*) ;; *) fail "expected a file under TMPDIR, got [$p]" ;; esac
  [ -f "$p" ] || fail "tmp_new made no file"
}

test_commit_gate_leaves_no_partial_time_file_in_the_git_dir() {
  tmp_repo 0
  printf 'fine\n' > b.ts
  must git add b.ts
  run env TMPDIR="$TMP/priv" "$G" check --staged
  assert_eq 0 "$STATUS" "check --staged: $OUT"
  [ -f .git/gauntlet-time.tsv ] || fail "the time file was not written"
  assert_eq "" "$(find .git -name '*.tmp' | tr '\n' ' ')" "partial files in .git"
  tmp_assert_clean "check --staged"
}

# The commit gate writes its time file through a temp file next to it. A signal between the
# two steps must not leave that file in .git: the cp here creates it, says so and hangs.
test_a_signal_while_the_time_file_is_written_leaves_no_partial_file() {
  tmp_repo 0
  printf 'fine\n' > b.ts
  must git add b.ts
  must mkdir -p "$TMP/shim"
  real_cp=$(command -v cp)
  cat > "$TMP/shim/cp" <<SHIM
#!/bin/sh
case "\$2" in
  *.tmp) : > "\$2"; touch "$TMP/cp.started"; sleep 30 ;;
esac
exec "$real_cp" "\$@"
SHIM
  must chmod +x "$TMP/shim/cp"
  TMP_MARK="$TMP/cp.started" PATH="$TMP/shim:$PATH" tmp_signal TERM group check --staged
  assert_eq 143 "$RC" "check --staged after SIGTERM: $(cat "$TMP/run.out")"
  assert_eq "" "$(find .git -name '*.tmp' | tr '\n' ' ')" "partial files left in .git"
  tmp_assert_clean "SIGTERM while the time file is written"
}

# status writes STATUS.md the same way, through .gauntlet/.STATUS.md.<pid>.
test_a_signal_while_status_is_written_leaves_no_partial_file() {
  tmp_repo 0
  must mkdir -p "$TMP/shim"
  real_mv=$(command -v mv)
  cat > "$TMP/shim/mv" <<SHIM
#!/bin/sh
case "\$3" in
  */STATUS.md) touch "$TMP/mv.started"; sleep 30 ;;
esac
exec "$real_mv" "\$@"
SHIM
  must chmod +x "$TMP/shim/mv"
  TMP_MARK="$TMP/mv.started" PATH="$TMP/shim:$PATH" tmp_signal TERM group status
  assert_eq 143 "$RC" "status after SIGTERM: $(cat "$TMP/run.out")"
  assert_eq "" "$(find .gauntlet -name '.STATUS.md.*' | tr '\n' ' ')" "partial files left in .gauntlet"
  tmp_assert_clean "SIGTERM while STATUS.md is written"
}

# bin/gauntlet changes to the repo root, so a relative TMPDIR must not change meaning on the way.
test_a_relative_tmpdir_is_resolved_before_the_runner_changes_directory() {
  mkrepo
  printf 'ok\n' > a.ts
  rule todo paths='**/*.ts'
  must git add -A
  must mkdir -p tmpx pkg/sub
  must cd pkg/sub
  run env TMPDIR=../../tmpx "$G" baseline
  assert_eq 0 "$STATUS" "baseline with a relative TMPDIR: $OUT"
  assert_eq "" "$(ls -A "$TMP/repo/tmpx")" "what the run left in the relative TMPDIR"
  assert_eq "" "$(ls -A "$TMP/repo/pkg/sub")" "nothing was made in the working directory"
}

# BSD tr decodes its input in the user's locale and stops with "Illegal byte sequence" on a file
# name or a detector line that is not valid UTF-8; GNU tr is bytewise, so only a macOS run shows
# it. A static pin: every tr in lib/ and bin/ is spelled LC_ALL=C tr on its own line. The
# allow-list is empty on purpose: add a line here, with the reason, only for a tr that never sees
# a name or detector output.
test_every_tr_in_lib_and_bin_runs_in_the_c_locale() {
  local bad
  bad=$(awk '
    /^[[:space:]]*#/ { next }
    {
      line = $0; all = 0; c = 0
      s = line
      while (match(s, /(^|[^A-Za-z0-9_.\/-])tr /)) { all++; s = substr(s, RSTART + RLENGTH) }
      s = line
      while (match(s, /LC_ALL=C tr /)) { c++; s = substr(s, RSTART + RLENGTH) }
      if (all != c) print FILENAME ":" FNR ": " line
    }
  ' "$ROOT"/lib/*.sh "$ROOT/bin/gauntlet")
  assert_eq "" "$bad" "tr without LC_ALL=C on the same line"
}

# I4: the cleanup removes what this process made, never a path the environment names. A
# variable of the same name in the environment (a CI job, a wrapper, a leftover export) is not
# this run's.
test_an_inherited_partial_path_is_never_removed() {
  mkrepo
  printf 'precious\n' > "$TMP/victim.txt"
  run env GAUNTLET_PARTIAL="$TMP/victim.txt" "$G" base
  assert_eq 0 "$STATUS" "base: $OUT"
  assert_eq "precious" "$(cat "$TMP/victim.txt")" "after a command with a root"
  run env GAUNTLET_PARTIAL="$TMP/victim.txt" "$G" --version
  assert_eq "precious" "$(cat "$TMP/victim.txt")" "after --version"
  run env GAUNTLET_PARTIAL="$TMP/victim.txt" "$G" nosuchcommand
  assert_eq "precious" "$(cat "$TMP/victim.txt")" "after an unknown command"
}

test_an_inherited_run_root_is_never_removed() {
  mkrepo
  must mkdir "$TMP/keep"
  printf 'precious\n' > "$TMP/keep/file"
  local args
  for args in "base" "--version" "nosuchcommand" "check --ci --base nosuch"; do
    # shellcheck disable=SC2086 # the words of $args are the arguments
    run env GAUNTLET_TMP="$TMP/keep" "$G" $args
    assert_eq "precious" "$(cat "$TMP/keep/file" 2> /dev/null)" "after: gauntlet $args"
  done
}

# An exported GAUNTLET_TMP does not leak into what the run starts either: the root is not exported.
test_the_run_root_is_not_exported_to_children() {
  mkrepo
  printf 'ok\n' > a.ts
  rule todo paths='**/*.ts' "detector=sh -c 'env | grep -e ^GAUNTLET_TMP= -e ^GAUNTLET_PARTIAL= > \"$TMP/env.out\"; true' ignored {files}"
  cases_of todo 'TODO x'
  must git add -A
  run env GAUNTLET_TMP="$TMP/keep" GAUNTLET_PARTIAL="$TMP/victim" "$G" baseline
  assert_eq 0 "$STATUS" "baseline: $OUT"
  assert_eq "" "$(cat "$TMP/env.out")" "GAUNTLET_TMP and GAUNTLET_PARTIAL as the detector saw them"
}

# M6: when the run root cannot be entered, the root that was made is still removed.
test_a_root_that_cannot_be_entered_is_still_removed() {
  [ "$(id -u)" -ne 0 ] || { skip "root enters any directory"; return 77; }
  mkrepo
  must mkdir -p "$TMP/priv" "$TMP/shim"
  local real_mktemp
  real_mktemp=$(command -v mktemp)
  cat > "$TMP/shim/mktemp" <<SHIM
#!/bin/sh
dir=\$("$real_mktemp" "\$@") || exit \$?
chmod 000 "\$dir"
printf '%s\n' "\$dir"
SHIM
  must chmod +x "$TMP/shim/mktemp"
  run env PATH="$TMP/shim:$PATH" TMPDIR="$TMP/priv" "$G" base
  assert_eq 2 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "cannot enter the temp directory"
  assert_eq "" "$(ls -A "$TMP/priv")" "what the run left in TMPDIR"
}
