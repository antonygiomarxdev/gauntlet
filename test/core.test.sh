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

# repo_root says "not inside a git repository" when git says that and only then. Any other failure
# is git's own: an unreadable config (here a core.hooksPath with a ~user that does not exist, which
# every git command trips over) or a bare repository. It is named by git's first error line.
test_repo_root_names_the_git_error_when_it_is_not_a_missing_repository() {
  mkrepo
  must git config core.hooksPath '~gauntlet-no-such-user/hooks'
  run "$G" status
  assert_eq 2 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "gauntlet: cannot find the repository root: fatal: failed to expand user dir in: '~gauntlet-no-such-user/hooks'"
  assert_not_contains "$OUT" "not inside a git repository"
  run bash -c ". '$ROOT/lib/core.sh'; repo_root"
  assert_eq 2 "$STATUS" "repo_root: $OUT"
  assert_contains "$OUT" "cannot find the repository root: fatal: failed to expand user dir"
}

test_repo_root_in_a_bare_repository_names_the_git_error() {
  must git init -q --bare "$TMP/bare.git"
  must cd "$TMP/bare.git"
  run "$G" status
  assert_eq 2 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "gauntlet: cannot find the repository root: fatal: this operation must be run in a work tree"
  assert_not_contains "$OUT" "not inside a git repository"
}

# The git line may hold text the project wrote (a config value, a path): a control byte in it is
# written out, never sent to the terminal. (This git already turns the byte into "?", so a git that
# does not stands in.)
test_repo_root_prints_the_git_error_escaped() {
  local real
  real=$(command -v git) || fail "no git on PATH"
  must mkdir "$TMP/shim" "$TMP/plain"
  cat > "$TMP/shim/git" <<SHIM
#!/bin/sh
if [ "\$1" = rev-parse ]; then
  printf 'fatal: bad config value \033[2J here\nhint: a second line git printed\n' >&2
  exit 128
fi
exec "$real" "\$@"
SHIM
  must chmod +x "$TMP/shim/git"
  must cd "$TMP/plain"
  run env PATH="$TMP/shim:$PATH" "$G" status
  assert_eq 2 "$STATUS" "status: $OUT"
  assert_contains "$OUT" 'gauntlet: cannot find the repository root: fatal: bad config value \x1b[2J here'
  assert_not_contains "$OUT" "a second line git printed"
  assert_eq 0 "$(printf '%s' "$OUT" | LC_ALL=C tr -d '\011\012\040-\176' | wc -c | tr -d ' ')" "raw control bytes in: $OUT"
}

# A git that fails without a word still gets a message that says what failed.
test_repo_root_says_so_when_git_fails_without_a_message() {
  local real
  real=$(command -v git) || fail "no git on PATH"
  must mkdir "$TMP/shim" "$TMP/plain"
  cat > "$TMP/shim/git" <<SHIM
#!/bin/sh
if [ "\$1" = rev-parse ]; then exit 128; fi
exec "$real" "\$@"
SHIM
  must chmod +x "$TMP/shim/git"
  must cd "$TMP/plain"
  run env PATH="$TMP/shim:$PATH" "$G" status
  assert_eq 2 "$STATUS" "status: $OUT"
  assert_eq "gauntlet: cannot find the repository root: git failed" "$OUT" "the message"
}

test_repo_root_outside_a_repository_still_says_so() {
  must mkdir "$TMP/plain"
  must cd "$TMP/plain"
  run "$G" status
  assert_eq 2 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "gauntlet: not inside a git repository"
}

# git's messages are translated, so "not a git repository" is only recognised in English: the second
# look at git's error is made in the C locale. A git that answers in German unless LC_ALL is C stands in
# for a translated git here (none is installed on most machines).
test_repo_root_asks_git_for_its_error_in_the_c_locale() {
  local real
  real=$(command -v git) || fail "no git on PATH"
  must mkdir "$TMP/shim" "$TMP/plain"
  cat > "$TMP/shim/git" <<SHIM
#!/bin/sh
if [ "\$1" = rev-parse ]; then
  if [ "\${LC_ALL:-}" = C ]; then
    echo "fatal: not a git repository (or any of the parent directories): .git" >&2
  else
    echo "fatal: kein Git-Repository (oder irgendeines der Elternverzeichnisse): .git" >&2
  fi
  exit 128
fi
exec "$real" "\$@"
SHIM
  must chmod +x "$TMP/shim/git"
  must cd "$TMP/plain"
  run env PATH="$TMP/shim:$PATH" LANG=de_DE.UTF-8 "$G" status
  assert_eq 2 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "gauntlet: not inside a git repository"
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

# C4: install and install-hooks take a lock (a directory under the git common dir) and the run's
# traps remove it on every way out. The lock is the owner's alone.
lock_repo() {
  mkrepo
  must cp -R "$ROOT/bin" "$ROOT/lib" .gauntlet/
  tmp_decoys
}

# The owner is held inside the vendoring copy (the cp says so and hangs) when the signal comes.
test_a_signal_during_install_removes_the_lock() {
  lock_repo
  must mkdir -p "$TMP/shim"
  real_cp=$(command -v cp)
  cat > "$TMP/shim/cp" <<SHIM
#!/bin/sh
case "\$*" in
  *.bin.new*) [ -d "$TMP/repo/.git/gauntlet-install.lock" ] && touch "$TMP/cp.started"; sleep 30 ;;
esac
exec "$real_cp" "\$@"
SHIM
  must chmod +x "$TMP/shim/cp"
  TMP_MARK="$TMP/cp.started" PATH="$TMP/shim:$PATH" tmp_signal TERM group install
  assert_eq 143 "$RC" "install after SIGTERM: $(cat "$TMP/run.out")"
  [ ! -e .git/gauntlet-install.lock ] || fail "the lock survived the signal"
  tmp_assert_clean "SIGTERM during install"
}

# A command that waits on somebody else's lock does not own it: a signal ends the waiter and the
# lock stays for its owner.
test_a_signal_to_a_command_waiting_for_the_lock_leaves_the_lock() {
  lock_repo
  must mkdir .git/gauntlet-install.lock
  must mkdir -p "$TMP/shim"
  real_sleep=$(command -v sleep)
  cat > "$TMP/shim/sleep" <<SHIM
#!/bin/sh
touch "$TMP/sleep.started"
exec "$real_sleep" "\$@"
SHIM
  must chmod +x "$TMP/shim/sleep"
  GAUNTLET_LOCK_WAIT=30 TMP_MARK="$TMP/sleep.started" PATH="$TMP/shim:$PATH" tmp_signal TERM group install-hooks
  assert_eq 143 "$RC" "install-hooks after SIGTERM: $(cat "$TMP/run.out")"
  [ -d .git/gauntlet-install.lock ] || fail "a waiter that did not own the lock removed it"
  tmp_assert_clean "SIGTERM while waiting for the lock"
}

# A signal that lands while mkdir makes the lock is handled once mkdir returns, before the run
# can record that it owns the lock. The lock must not outlive the run all the same.
test_a_signal_as_the_lock_is_made_still_removes_it() {
  lock_repo
  must mkdir -p "$TMP/shim"
  real_mkdir=$(command -v mkdir)
  cat > "$TMP/shim/mkdir" <<SHIM
#!/bin/sh
"$real_mkdir" "\$@" || exit \$?
case "\$*" in
  *gauntlet-install.lock) kill -TERM "\$PPID" ;;
esac
SHIM
  must chmod +x "$TMP/shim/mkdir"
  run env TMPDIR="$TMP/priv" PATH="$TMP/shim:$PATH" "$G" install
  assert_eq 143 "$STATUS" "install, signalled as it made the lock: $OUT"
  [ ! -e .git/gauntlet-install.lock ] || fail "the lock survived a signal that landed as it was made"
  tmp_assert_clean "SIGTERM as the lock is made"
}

test_an_inherited_lock_path_is_never_removed() {
  lock_repo
  must mkdir "$TMP/keep"
  run env GAUNTLET_LOCK="$TMP/keep" "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks: $OUT"
  [ -d "$TMP/keep" ] || fail "a lock path from the environment was removed"
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

# closed_dir_is_removed: succeed when `rm -rf` removes an empty directory of mode 000, as GNU rm
# does. BSD rm (macOS) stops on a directory it cannot enter and leaves it, even an empty one. The
# test of a run root that cannot be entered (below) holds only where rm removes it.
closed_dir_is_removed() {
  local probe
  probe=$(mktemp -d "$TMP/probe.XXXXXX") || fail "cannot make the probe directory"
  chmod 000 "$probe"
  rm -rf "$probe" 2> /dev/null || true
  if [ -e "$probe" ]; then
    chmod 700 "$probe"
    rm -rf "$probe"
    return 1
  fi
}

# closed_dir_rm_shim <stops|removes>: an rm first on PATH that behaves as BSD rm does (stops on a
# directory it cannot enter, prints the usual message, exits 1) or as GNU rm does (removes it).
closed_dir_rm_shim() {
  local real
  # The real rm, also when a shim of the other kind is already first on PATH.
  real=$(PATH=${PATH#"$TMP/rmshim:"} command -v rm)
  must mkdir -p "$TMP/rmshim"
  # shellcheck disable=SC2016 # the shim's own variables, expanded when it runs
  case "$1" in
    stops)
      printf '#!/bin/sh\nfor d in "$@"; do :; done\nif [ -d "$d" ] && [ ! -x "$d" ]; then echo "rm: $d: Permission denied" >&2; exit 1; fi\nexec "%s" "$@"\n' "$real" > "$TMP/rmshim/rm"
      ;;
    removes)
      printf '#!/bin/sh\nfor d in "$@"; do :; done\nif [ -d "$d" ]; then chmod u+rwx "$d"; fi\nexec "%s" "$@"\n' "$real" > "$TMP/rmshim/rm"
      ;;
  esac
  must chmod +x "$TMP/rmshim/rm"
  PATH="$TMP/rmshim:$PATH"
}

# The probe says what rm does, on every platform: its verdict is pinned with an rm of each kind, so
# a probe that always says "removed" (and so fails on BSD) or never does (and so skips on GNU) is
# caught here and not only on the platform where it matters.
test_the_closed_directory_probe_tells_an_rm_that_stops_from_one_that_removes() {
  closed_dir_rm_shim stops
  if closed_dir_is_removed; then fail "the probe says rm removes a directory it cannot enter, and this rm stops on it"; fi
  closed_dir_rm_shim removes
  closed_dir_is_removed || fail "the probe says rm leaves a directory it cannot enter, and this rm removes it"
}

# M6: when the run root cannot be entered, the root that was made is still removed.
test_a_root_that_cannot_be_entered_is_still_removed() {
  [ "$(id -u)" -ne 0 ] || { skip "root enters any directory"; return 77; }
  # The directory the shim below makes is mode 000 until the cleanup removes it. If the cleanup
  # fails, this teardown makes it removable before the harness removes $TMP, so a failed run never
  # leaves a directory the harness cannot delete.
  trap 'chmod -R u+rwx "$TMP" 2> /dev/null; rm -rf "$TMP"' EXIT
  # W2b re-review N7: BSD rm (macOS) stops on a directory it cannot enter and leaves it, even an empty
  # one, so the assertion below cannot hold there. Probe the platform first, and skip with the reason.
  if ! closed_dir_is_removed; then
    skip "rm -rf leaves an empty mode-000 directory on this platform (BSD rm): the removal of a root that cannot be entered cannot be tested here"
    return 77
  fi
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

# R33 pinned from the outside: no code path makes scratch anywhere but under the run root. A
# mktemp on PATH logs every call. Per gauntlet run there is exactly one call that makes the root
# (in TMPDIR) and every other call names a template inside a root; a bare `mktemp`, or one
# aimed at TMPDIR itself, is a leak that no signal test sees until it is interrupted at the
# right moment. The allow-list is empty on purpose.
test_every_mktemp_call_is_inside_the_run_root() {
  tmp_repo 0
  must mkdir -p "$TMP/shim"
  local real_mktemp
  real_mktemp=$(command -v mktemp)
  printf '#!/bin/sh\necho "$*" >> "%s/mktemp.log"\nexec "%s" "$@"\n' "$TMP" "$real_mktemp" > "$TMP/shim/mktemp"
  must chmod +x "$TMP/shim/mktemp"
  : > "$TMP/mktemp.log"
  local runs=0 cmd
  printf 'ok2\n' >> a.ts
  must git add a.ts
  for cmd in "baseline" "check --ci --base main" "check --staged" "test-rules" "doctor" "status"; do
    # shellcheck disable=SC2086 # the words of $cmd are the arguments
    run env TMPDIR="$TMP/priv" PATH="$TMP/shim:$PATH" "$G" $cmd
    runs=$((runs + 1))
    [ -s "$TMP/mktemp.log" ] || fail "gauntlet $cmd made no temp file at all: $OUT"
  done
  # The commands that write a hook or a rule file make a temp file of their own (the new text
  # goes into a temp file, then over the target, so the target keeps its mode): install-hooks edits an
  # existing hook and upgrades an old pre-push line, promote rewrites a rule's severity, install
  # does both after vendoring. The shim saw only the six commands above before (W2b re-review N3),
  # so a bare mktemp at these sites passed. The allow-list is still empty.
  must cp -R "$ROOT/bin" "$ROOT/lib" .gauntlet/
  # An older gauntlet line (a marked line that is not the current form): install-hooks replaces it.
  local old_line='.gauntlet/bin/gauntlet check --ci  # gauntlet'
  printf '#!/bin/sh\necho mine\n' > .git/hooks/pre-commit
  printf '#!/bin/sh\n%s\n' "$old_line" > .git/hooks/pre-push
  chmod 755 .git/hooks/pre-commit .git/hooks/pre-push
  rule shadowed severity=shadow
  for cmd in "install-hooks" "promote shadowed" "install"; do
    cp "$TMP/mktemp.log" "$TMP/mktemp.before"
    # shellcheck disable=SC2086 # the words of $cmd are the arguments
    run env TMPDIR="$TMP/priv" PATH="$TMP/shim:$PATH" "$G" $cmd
    runs=$((runs + 1))
    assert_eq 0 "$STATUS" "gauntlet $cmd: $OUT"
    if cmp -s "$TMP/mktemp.before" "$TMP/mktemp.log"; then fail "gauntlet $cmd made no temp file at all: $OUT"; fi
    printf '#!/bin/sh\necho mine\n' > .git/hooks/pre-commit
    printf '#!/bin/sh\n%s\n' "$old_line" > .git/hooks/pre-push
  done
  # The other two ways a hook is written: a hook that does not exist yet, and an empty one.
  rm -f .git/hooks/pre-commit .git/hooks/pre-push
  for cmd in "create" "empty"; do
    if [ "$cmd" = empty ]; then
      : > .git/hooks/pre-commit
      : > .git/hooks/pre-push
      chmod 755 .git/hooks/pre-commit .git/hooks/pre-push
    fi
    cp "$TMP/mktemp.log" "$TMP/mktemp.before"
    run env TMPDIR="$TMP/priv" PATH="$TMP/shim:$PATH" "$G" install-hooks
    runs=$((runs + 1))
    assert_eq 0 "$STATUS" "gauntlet install-hooks ($cmd): $OUT"
    if cmp -s "$TMP/mktemp.before" "$TMP/mktemp.log"; then fail "gauntlet install-hooks ($cmd) made no temp file at all: $OUT"; fi
  done
  local line template roots=0 stray=
  while IFS= read -r line; do
    template=${line#-d }
    case "$template" in
      "$TMP"/priv/gauntlet.XXXXXX) roots=$((roots + 1)) ;;
      "$TMP"/priv/gauntlet.??????/gauntlet.XXXXXX) ;;
      *) stray="$stray [mktemp ${line:-with no template}]" ;;
    esac
  done < "$TMP/mktemp.log"
  assert_eq "" "$stray" "mktemp calls outside the run root"
  assert_eq "$runs" "$roots" "one root per run"
}

# sh_quote: a value as one word for a shell. gauntlet prints commands for the user to paste, and
# the value in them is a ref, a path or a rule id that a repository chose.
test_sh_quote_wraps_the_value_in_single_quotes() {
  # shellcheck source=lib/core.sh
  # shellcheck disable=SC2153 # ROOT is set by test/lib.sh
  . "$ROOT/lib/core.sh"
  assert_eq "'main'" "$(sh_quote main)" "an ordinary word"
  assert_eq "''" "$(sh_quote '')" "the empty value is still a word"
  assert_eq "'a b'" "$(sh_quote 'a b')" "a space"
}

# The one character a single-quoted word cannot hold is written close, escape, open.
test_sh_quote_writes_an_embedded_single_quote_as_close_escape_open() {
  # shellcheck source=lib/core.sh
  # shellcheck disable=SC2153 # ROOT is set by test/lib.sh
  . "$ROOT/lib/core.sh"
  assert_eq "'it'\\''s'" "$(sh_quote "it's")" "one quote"
  assert_eq "''\\'''" "$(sh_quote "'")" "a quote alone"
  assert_eq "'a'\\'''\\''b'" "$(sh_quote "a''b")" "two quotes in a row"
}

# What a shell reads back is the value, byte for byte, whatever it holds: expansions, separators,
# redirections, globs, a leading dash, a newline, a tab, a backslash, non-ASCII text.
# shellcheck disable=SC2016 # the values are literal text: nothing in them is to expand here
test_sh_quote_reads_back_as_the_same_value_in_a_shell() {
  local v n=0
  # shellcheck source=lib/core.sh
  # shellcheck disable=SC2153 # ROOT is set by test/lib.sh
  . "$ROOT/lib/core.sh"
  for v in 'plain' 'ev$(touch${IFS}PWNED)' '`touch PWNED`' 'a;touch PWNED' 'a&b|c' 'a>b<c' '*' '?[a]' '-n' '--help' '#x' '!x' 'a\b' 'a"b' "it's" "'" "a'b'c" $'a\tb' $'a\nb' ' lead and trail ' 'ñandú → x' '$HOME' '~'; do
    n=$((n + 1))
    printf '%s' "$v" > "$TMP/want.$n"
    (cd "$TMP" && sh -c "printf %s $(sh_quote "$v")" > "$TMP/got.$n" 2>&1)
    cmp -s "$TMP/want.$n" "$TMP/got.$n" || fail "sh_quote did not read back as [$v]: got [$(cat "$TMP/got.$n")]"
  done
  if [ -e "$TMP/PWNED" ]; then fail "a value ran as a command"; fi
}
