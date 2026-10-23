# shellcheck shell=bash
# shellcheck disable=SC2153 # ROOT, G and STATUS are set by test/lib.sh
# Tests for check --ci: new violations, rising totals, a baseline that differs
# from the code, shadow and track reporting, and the dirty-tree refusal. Each
# test puts a.ts with the given content on main, commits the baseline there,
# branches, changes the tree, regenerates the baseline and runs the gate.

# commit_all <msg>: stage and commit everything, untracked files included.
commit_all() {
  must git add -A
  must git commit -q -m "$1"
}

# gate_setup <a.ts content> [rule options...]: a main branch with one todo rule
# over **/*.ts, its cases and a committed baseline, then a feat branch.
gate_setup() {
  local content=$1
  shift
  mkrepo
  printf '%s\n' "$content" > a.ts
  rule todo paths='**/*.ts' "$@"
  cases_of todo 'TODO x'
  rebaseline
  assert_eq 0 "$STATUS" "main baseline"
  commit_all main
  must git checkout -q -b feat
}

# rebaseline: stage everything, then regenerate the baseline. A file only
# counts once it is in the index (R19), so stage before measuring.
rebaseline() {
  must git add -A
  run "$G" baseline
}

# gate: run check --ci against main; result in $OUT and $STATUS.
gate() {
  run "$G" check --ci --base main
}

test_new_violation_fails() {
  gate_setup 'ok'
  printf 'TODO fix\n' > a.ts
  rebaseline
  assert_eq 0 "$STATUS" "feat baseline"
  commit_all feat
  gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "[new]"
  assert_contains "$OUT" "a.ts:"
  assert_contains "$OUT" "todo"
  assert_contains "$OUT" "fix: remove it"
}

test_new_violation_path_with_space() {
  gate_setup 'ok'
  mkdir -p "my dir"
  printf 'TODO\n' > "my dir/ä b.ts"
  rebaseline
  commit_all feat
  gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "my dir/ä b.ts:1"
}

test_moved_line_passes() {
  gate_setup 'TODO here'
  printf 'ok\nTODO here\n' > a.ts
  rebaseline
  commit_all moved
  gate
  assert_eq 0 "$STATUS" "status"
  assert_not_contains "$OUT" "[new]"
}

test_global_rise_fails() {
  gate_setup 'TODO x'
  printf 'TODO x\n' > b.ts
  rebaseline
  commit_all second
  gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "[global]"
  assert_contains "$OUT" "todo  1 → 2"
}

test_baseline_lie_fails() {
  gate_setup 'TODO here'
  : > .gauntlet/baseline.tsv
  commit_all lie
  gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "[baseline]"
  assert_contains "$OUT" "baseline differs from the code; run gauntlet baseline and commit it"
}

test_shadow_never_fails() {
  gate_setup 'ok' severity=shadow
  printf 'TODO fix\n' > a.ts
  rebaseline
  commit_all feat
  gate
  assert_eq 0 "$STATUS" "status"
  assert_contains "$OUT" "would have failed"
}

test_track_rise_reports() {
  gate_setup 'ok' severity=track
  printf 'TODO fix\n' > a.ts
  rebaseline
  commit_all feat
  gate
  assert_eq 0 "$STATUS" "status"
  assert_contains "$OUT" "consider promoting"
}

test_all_problems_reported_together() {
  gate_setup 'ok'
  printf 'TODO fix\n' > a.ts
  commit_all feat
  gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "[new]"
  assert_contains "$OUT" "[baseline]"
  assert_contains "$OUT" "FAIL (2 problems)"
}

test_onboarding_branch_skips_1_to_3() {
  mkrepo
  rule todo paths='**/*.ts'
  must git rm -q .gauntlet/baseline.tsv
  commit_all main-no-baseline
  must git checkout -q -b feat5
  printf 'TODO here\n' > a.ts
  rebaseline
  commit_all feat
  gate
  assert_eq 0 "$STATUS" "status"
  assert_contains "$OUT" "no baseline at base"
}

test_new_rule_exempt() {
  mkrepo
  printf 'TODO here\n' > a.ts
  commit_all main-debt
  must git checkout -q -b feat6
  rule todo paths='**/*.ts'
  cases_of todo 'TODO x'
  rebaseline
  assert_eq 0 "$STATUS" "feat baseline"
  commit_all feat
  gate
  assert_eq 0 "$STATUS" "status"
  assert_not_contains "$OUT" "[new]"
}

test_dirty_tree_refuses() {
  gate_setup 'ok'
  printf 'TODO fix\n' > a.ts
  gate
  assert_eq 2 "$STATUS" "status"
  assert_contains "$OUT" "commit or stash first"
}

# section_of <name> <output>: the lines of one report section, from its header
# up to the [time] section.
section_of() {
  printf '%s\n' "$2" | awk -v want="$1" '
    $0 == want { on = 1; next }
    $0 == "[time]" { on = 0 }
    on
  '
}

test_bad_severity_fails_closed() {
  gate_setup 'ok' severity=blok
  printf 'TODO fix\n' > a.ts
  rebaseline
  commit_all feat
  gate
  assert_eq 2 "$STATUS" "status"
  assert_contains "$OUT" "bad severity [blok]"
}

test_four_new_occurrences_count_four() {
  gate_setup 'ok'
  printf 'TODO 1\nTODO 2\nTODO 3\nTODO 4\n' > a.ts
  rebaseline
  commit_all feat
  gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "FAIL (4 problems)"
}

test_rule_named_baseline_counts_as_a_rule() {
  mkrepo
  printf 'ok\n' > a.ts
  rule baseline paths='**/*.ts'
  rebaseline
  commit_all main
  must git checkout -q -b feat
  printf 'TODO fix\n' > a.ts
  commit_all feat
  gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "FAIL (2 problems)"
}

test_baseline_diff_is_reproducible() {
  gate_setup 'TODO here'
  : > .gauntlet/baseline.tsv
  commit_all lie
  gate
  first=$(section_of "[baseline]" "$OUT")
  gate
  second=$(section_of "[baseline]" "$OUT")
  assert_eq "$first" "$second" "baseline section"
  assert_contains "$first" "--- .gauntlet/baseline.tsv"
  assert_contains "$first" "+++ measured"
  assert_not_contains "$first" "/tmp"
}

test_baseline_diff_capped_at_20_lines() {
  gate_setup 'ok'
  i=1
  while [ "$i" -le 30 ]; do
    printf 'TODO %s\n' "$i"
    i=$((i + 1))
  done > a.ts
  commit_all feat
  gate
  section=$(section_of "[baseline]" "$OUT")
  diff_lines=$(printf '%s\n' "$section" | awk 'NR > 1 { n++ } END { print n + 0 }')
  assert_eq 20 "$diff_lines" "diff lines"
}

test_missing_baseline_prints_message() {
  gate_setup 'TODO here'
  must git rm -q .gauntlet/baseline.tsv
  commit_all drop-baseline
  gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" ".gauntlet/baseline.tsv is missing; run gauntlet baseline and commit it"
  assert_not_contains "$OUT" "--- .gauntlet/baseline.tsv"
}

test_stacked_branch_judged_on_own_changes() {
  gate_setup 'ok'
  must git checkout -q -b layer-a
  printf 'TODO a\n' > a.ts
  rebaseline
  commit_all layer-a
  must git checkout -q -b layer-b
  printf 'ok\n' > b.txt
  rebaseline
  commit_all layer-b
  run "$G" check --ci --base layer-a
  assert_eq 0 "$STATUS" "against its own base"
  run "$G" check --ci --base main
  assert_eq 1 "$STATUS" "against main"
}

test_deleted_rule_passes() {
  gate_setup 'TODO here'
  must git rm -q .gauntlet/rules/todo.md
  run "$G" remove todo "rule retired"
  assert_eq 0 "$STATUS" "remove status"
  rebaseline
  commit_all drop-rule
  gate
  assert_eq 0 "$STATUS" "status"
  assert_not_contains "$OUT" "[new]"
}

test_failing_run_leaves_no_temp_dir() {
  gate_setup 'ok'
  printf 'TODO fix\n' > a.ts
  commit_all feat
  mkdir -p "$TMP/tt"
  export TMPDIR="$TMP/tt"
  gate
  assert_eq 1 "$STATUS" "status"
  assert_eq "" "$(ls -A "$TMP/tt")" "leftover temp entries"
}

test_untracked_file_not_measured() {
  gate_setup 'ok'
  printf 'TODO u\n' > u.ts
  run "$G" baseline
  assert_eq 0 "$STATUS" "baseline status"
  assert_eq "" "$(cat .gauntlet/baseline.tsv)" "baseline"
  gate
  assert_eq 0 "$STATUS" "check status"
  assert_not_contains "$OUT" "u.ts"
}

test_added_file_is_measured() {
  gate_setup 'ok'
  printf 'TODO v\n' > v.ts
  must git add v.ts
  rebaseline
  assert_contains "$(cat .gauntlet/baseline.tsv)" "v.ts"
}

# touched_on: turn the touched gate on for the branch under test.
touched_on() {
  printf 'touched=on\n' > .gauntlet/config
}

test_touched_off_by_default() {
  gate_setup 'TODO here'
  printf 'TODO here\nok\n' > a.ts
  rebaseline
  commit_all feat
  gate
  assert_eq 0 "$STATUS" "status"
  assert_not_contains "$OUT" "[touched]"
}

test_touched_requires_decrease() {
  gate_setup 'TODO here'
  touched_on
  printf 'TODO here\nok\n' > a.ts
  rebaseline
  commit_all feat
  gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "[touched]"
  assert_contains "$OUT" "  a.ts  1 → 1  (must go down)"
  assert_contains "$OUT" "FAIL (1 problems)"
}

test_touched_path_with_space() {
  mkrepo
  mkdir -p "my dir"
  printf 'TODO here\n' > "my dir/ä b.ts"
  rule todo paths='**/*.ts'
  rebaseline
  commit_all main
  must git checkout -q -b feat
  touched_on
  printf 'TODO here\nok\n' > "my dir/ä b.ts"
  rebaseline
  commit_all feat
  gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "  my dir/ä b.ts  1 → 1  (must go down)"
}

test_pay_one_any_rule_passes() {
  mkrepo
  printf 'TODO here\nFIXME here\n' > a.ts
  rule todo paths='**/*.ts'
  rule fixme paths='**/*.ts' detector="rg --with-filename --line-number --no-heading 'FIXME' {files}"
  rebaseline
  commit_all main
  must git checkout -q -b feat
  touched_on
  printf 'FIXME here\n' > a.ts
  rebaseline
  commit_all feat
  gate
  assert_eq 0 "$STATUS" "status"
  assert_not_contains "$OUT" "[touched]"
}

test_added_file_must_be_zero() {
  gate_setup 'ok'
  touched_on
  printf 'TODO x\n' > c.ts
  rebaseline
  commit_all feat
  gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "[touched]"
  assert_contains "$OUT" "  c.ts  0 → 1  (must be 0)"
}

test_pure_rename_skipped() {
  gate_setup 'TODO here'
  touched_on
  must git mv a.ts b.ts
  rebaseline
  commit_all feat
  gate
  assert_not_contains "$OUT" "[touched]"
}

test_rename_with_edit_follows_old_path() {
  gate_setup 'TODO here'
  touched_on
  must git mv a.ts b.ts
  printf 'TODO here\nok\n' > b.ts
  rebaseline
  commit_all feat
  gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "  b.ts  1 → 1  (must go down)"
}

test_onboarding_branch_skips_touched() {
  mkrepo
  printf 'TODO here\n' > a.ts
  rule todo paths='**/*.ts'
  must git rm -q .gauntlet/baseline.tsv
  commit_all main-no-baseline
  must git checkout -q -b feat7
  touched_on
  printf 'TODO here\nok\n' > a.ts
  rebaseline
  commit_all feat
  gate
  assert_eq 0 "$STATUS" "status"
  assert_contains "$OUT" "no baseline at base"
  assert_not_contains "$OUT" "[touched]"
}

test_rule_added_here_not_counted() {
  gate_setup 'TODO here'
  touched_on
  printf 'ok\nFIXME one\nFIXME two\n' > a.ts
  rule fixme paths='**/*.ts' detector="rg --with-filename --line-number --no-heading 'FIXME' {files}"
  cases_of fixme 'FIXME x'
  rebaseline
  commit_all feat
  gate
  assert_eq 0 "$STATUS" "status"
  assert_not_contains "$OUT" "[touched]"
}

test_new_file_two_todos_counts_two() {
  gate_setup 'ok'
  touched_on
  printf 'TODO a\nTODO b\n' > c.ts
  rebaseline
  commit_all feat
  gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "FAIL (2 problems)"
  assert_contains "$OUT" "  c.ts  0 → 2  (must be 0)"
}

test_touched_judges_quoted_path() {
  mkrepo
  printf 'TODO here\n' > 'q"x.ts'
  rule todo paths='**/*.ts'
  rebaseline
  commit_all main
  must git checkout -q -b feat
  touched_on
  printf 'TODO here\nok\n' > 'q"x.ts'
  rebaseline
  commit_all feat
  gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "  q\"x.ts  1 → 1  (must go down)"
}

test_touched_judges_backslash_path() {
  mkrepo
  printf 'TODO here\n' > 'b\s.ts'
  rule todo paths='**/*.ts'
  rebaseline
  commit_all main
  must git checkout -q -b feat
  touched_on
  printf 'TODO here\nok\n' > 'b\s.ts'
  rebaseline
  commit_all feat
  gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "  b\s.ts  1 → 1  (must go down)"
}

test_touched_rejects_unknown_mode() {
  gate_setup 'TODO here'
  printf 'touched=ON\n' > .gauntlet/config
  rebaseline
  commit_all feat
  gate
  assert_eq 2 "$STATUS" "status"
  assert_contains "$OUT" "touched must be on or off, got [ON]"
}

test_shadow_and_track_not_counted() {
  mkrepo
  printf 'TODO here\n' > a.ts
  rule todo paths='**/*.ts'
  rule fixme paths='**/*.ts' severity=shadow detector="rg --with-filename --line-number --no-heading 'FIXME' {files}"
  rule xxx paths='**/*.ts' severity=track detector="rg --with-filename --line-number --no-heading 'XXX' {files}"
  rebaseline
  commit_all main
  must git checkout -q -b feat
  touched_on
  printf 'FIXME x\nXXX y\nFIXME z\n' > a.ts
  rebaseline
  commit_all feat
  gate
  assert_eq 0 "$STATUS" "status"
  assert_not_contains "$OUT" "[touched]"
}

test_base_zero_file_gaining_debt_must_stay_zero() {
  gate_setup 'ok'
  touched_on
  printf 'ok\nTODO x\n' > a.ts
  rebaseline
  commit_all feat
  gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "[touched]"
  assert_contains "$OUT" "  a.ts  0 → 1  (must stay 0)"
  assert_contains "$OUT" "FAIL (1 problems)"
}

test_rule_change_runs_cases() {
  mkrepo
  printf 'x\n' > a.ts
  rule todo paths='**/*.ts'
  cases_of todo 'TODO x'
  rebaseline
  commit_all main
  must git checkout -q -b feat
  rule todo paths='**/*.ts' detector="rg --with-filename --line-number --no-heading 'TODO|ok' {files}"
  rebaseline
  commit_all feat
  gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "[rule-tests]"
  assert_contains "$OUT" "todo.good.txt  good case flagged"
}

test_formats_change_runs_rule_tests() {
  mkrepo
  printf 'x\n' > a.ts
  rule todo paths='**/*.ts'
  cases_of todo 'TODO x'
  rebaseline
  commit_all main
  must git checkout -q -b feat
  mkdir -p .gauntlet/formats
  printf 'no cases\n' > .gauntlet/formats/bare.md
  commit_all feat
  gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "[rule-tests]"
  assert_contains "$OUT" "  bare  sample  no cases"
  assert_contains "$(section_of "[time]" "$OUT")" "  rule-tests  "
}

test_rule_tests_silent_without_rule_change() {
  mkrepo
  printf 'x\n' > a.ts
  rule todo paths='**/*.ts'
  mkdir -p .gauntlet/formats
  printf 'no cases\n' > .gauntlet/formats/bare.md
  rebaseline
  commit_all main
  must git checkout -q -b feat
  printf 'ok\n' > b.txt
  commit_all feat
  gate
  assert_eq 0 "$STATUS" "status"
  assert_not_contains "$OUT" "[rule-tests]"
}

test_each_failed_check_and_rule_test_line_counts() {
  mkrepo
  printf 'x\n' > a.ts
  rule todo paths='**/*.ts'
  cases_of todo 'TODO x'
  rebaseline
  commit_all main
  must git checkout -q -b feat
  mkdir -p .gauntlet/formats
  printf 'no cases\n' > .gauntlet/formats/bare.md
  printf 'check.t=false\n' > .gauntlet/config
  commit_all feat
  gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "FAIL (3 problems)"
}

test_declared_check_runs_on_scope() {
  gate_setup 'x'
  printf 'check.t=false\ncheck.t.paths=src/\n' > .gauntlet/config
  mkdir -p src
  printf 'y\n' > src/a
  commit_all feat
  gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "[checks]"
  assert_contains "$OUT" "  t  exit 1"
  assert_contains "$OUT" "FAIL (1 problems)"
}

test_declared_check_skipped_off_scope() {
  gate_setup 'x'
  printf 'check.t=false\ncheck.t.paths=src/\n' > .gauntlet/config
  mkdir -p docs
  printf 'y\n' > docs/x
  commit_all feat
  gate
  assert_eq 0 "$STATUS" "status"
  assert_not_contains "$OUT" "[checks]"
}

test_scope_prefix_matches_path_with_space() {
  gate_setup 'x'
  printf 'check.t=false\ncheck.t.paths=src/\n' > .gauntlet/config
  mkdir -p src
  printf 'y\n' > "src/a b"
  commit_all feat
  gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "  t  exit 1"
}

test_ci_env_runs_only_ci_on() {
  gate_setup 'x'
  printf 'check.t=false\ncheck.t.paths=src/\n' > .gauntlet/config
  mkdir -p src
  printf 'y\n' > src/a
  commit_all feat
  run env CI=true "$G" check --ci --base main
  assert_eq 0 "$STATUS" "status"
  assert_not_contains "$OUT" "[checks]"
}

test_ci_env_runs_ci_on() {
  gate_setup 'x'
  printf 'check.t=false\ncheck.t.paths=src/\ncheck.t.ci=on\n' > .gauntlet/config
  mkdir -p src
  printf 'y\n' > src/a
  commit_all feat
  run env CI=true "$G" check --ci --base main
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "  t  exit 1"
}

test_failed_check_prints_last_20_lines() {
  gate_setup 'x'
  printf 'check.t=seq 1 25; exit 3\n' > .gauntlet/config
  commit_all feat
  gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "  t  exit 3"
  assert_eq 1 "$(printf '%s\n' "$OUT" | grep -c -x '    6')" "line 6 shown"
  assert_eq 1 "$(printf '%s\n' "$OUT" | grep -c -x '    25')" "line 25 shown"
  assert_eq 0 "$(printf '%s\n' "$OUT" | grep -c -x '    5')" "line 5 hidden"
}

test_check_time_listed() {
  gate_setup 'x'
  printf 'check.t=true\n' > .gauntlet/config
  commit_all feat
  gate
  assert_eq 0 "$STATUS" "status"
  assert_contains "$(section_of "[time]" "$OUT")" "  check:t  "
}

test_check_runs_from_repo_root() {
  gate_setup 'x'
  printf 'check.t=test -f marker\n' > .gauntlet/config
  printf 'm\n' > marker
  commit_all feat
  mkdir -p sub
  cd sub || fail "cannot enter sub"
  gate
  assert_eq 0 "$STATUS" "status"
}

test_bad_check_key_exits_2() {
  gate_setup 'x'
  printf 'check.t.x=true\n' > .gauntlet/config
  commit_all feat
  gate
  assert_eq 2 "$STATUS" "status"
  assert_contains "$OUT" "bad check key check.t.x"
}

test_checks_run_on_onboarding_branch() {
  mkrepo
  printf 'x\n' > a.ts
  rule todo paths='**/*.ts'
  cases_of todo 'TODO x'
  must git rm -q .gauntlet/baseline.tsv
  commit_all main-no-baseline
  must git checkout -q -b feat
  printf 'check.t=false\n' > .gauntlet/config
  commit_all feat
  gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "no baseline at base"
  assert_contains "$OUT" "  t  exit 1"
}

test_renamed_away_triggers_scoped_check() {
  mkrepo
  printf 'x\n' > a.ts
  rule todo paths='**/*.ts'
  cases_of todo 'TODO x'
  mkdir -p src
  printf 'y\n' > src/z
  rebaseline
  commit_all main
  must git checkout -q -b feat
  mkdir -p docs
  printf 'check.t=false\ncheck.t.paths=src/\n' > .gauntlet/config
  must git mv src/z docs/z
  commit_all feat
  gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "  t  exit 1"
}

test_renamed_out_of_rules_triggers_rule_tests() {
  mkrepo
  printf 'x\n' > a.ts
  rule todo paths='**/*.ts'
  rule x paths='**/*.ts'
  rebaseline
  commit_all main
  must git checkout -q -b feat
  mkdir -p docs
  must git mv .gauntlet/rules/x.md docs/x.md
  commit_all feat
  gate
  assert_contains "$OUT" "[rule-tests]"
  assert_contains "$OUT" "  todo  bad  no cases"
}

test_deleted_file_triggers_scoped_check() {
  mkrepo
  printf 'x\n' > a.ts
  rule todo paths='**/*.ts'
  cases_of todo 'TODO x'
  mkdir -p src
  printf 'y\n' > src/a
  rebaseline
  commit_all main
  must git checkout -q -b feat
  printf 'check.t=false\ncheck.t.paths=src/\n' > .gauntlet/config
  must git rm -q src/a
  commit_all feat
  gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "  t  exit 1"
}

test_check_stdin_is_devnull() {
  gate_setup 'x'
  # a reads stdin; b must still run after it, so a stdin reader cannot eat the table.
  printf 'check.a=cat; true\ncheck.b=false\n' > .gauntlet/config
  commit_all feat
  # A stdin that never closes: a check that reads it would hang, so with_timeout ends it.
  with_timeout 10 "$G" check --ci --base main < <(sleep 30 2> /dev/null) > "$TMP/out" 2>&1
  STATUS=$?
  OUT=$(cat "$TMP/out")
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "  b  exit 1"
}

test_rule_tests_broken_detector_exits_2() {
  gate_setup 'x'
  rule broken paths='**/*.ts' engine=script detector="sh -c 'for f; do case \$f in *.txt) exit 2;; esac; done' sh {files}"
  cases_of broken 'TODO x'
  commit_all feat
  gate
  assert_eq 2 "$STATUS" "status"
  assert_contains "$OUT" "rule tests could not run"
}

test_bad_check_key_says_why() {
  gate_setup 'x'
  printf 'check.t=\n' > .gauntlet/config
  commit_all feat
  gate
  assert_eq 2 "$STATUS" "empty command"
  assert_contains "$OUT" "bad check key check.t: empty command"
  printf 'check.t=true\ncheck.t.ci=maybe\n' > .gauntlet/config
  commit_all feat2
  gate
  assert_eq 2 "$STATUS" "ci value"
  assert_contains "$OUT" "bad check key check.t.ci: .ci must be on or off, got [maybe]"
  printf 'check.u.paths=src/\n' > .gauntlet/config
  commit_all feat3
  gate
  assert_eq 2 "$STATUS" "attribute alone"
  assert_contains "$OUT" "bad check key check.u.paths: attribute without a command"
}

test_bad_check_key_first_in_sorted_order() {
  gate_setup 'x'
  # The attribute orphan is found first by the awk pass; sorted, check.a is first.
  printf 'check.z.paths=x\ncheck.a=\n' > .gauntlet/config
  commit_all feat
  gate
  assert_eq 2 "$STATUS" "status"
  assert_contains "$OUT" "bad check key check.a: empty command"
  assert_not_contains "$OUT" "check.z.paths"
}

# Renames carry their debt (R23, FRD-03 section 4.6): a renamed file's base rows are
# read under its new path, so existing debt never fails the gate by itself.

test_pure_rename_of_debt_passes() {
  gate_setup 'TODO here'
  must git mv a.ts b.ts
  rebaseline
  assert_eq 0 "$STATUS" "feat baseline"
  commit_all feat
  gate
  assert_eq 0 "$STATUS" "status"
  assert_not_contains "$OUT" "[new]"
  assert_eq 'todo	b.ts	TODO here	1' "$(cat .gauntlet/baseline.tsv)" "baseline rows follow the rename"
}

test_rename_with_unchanged_debt_line_passes() {
  gate_setup "$(printf 'alpha\nbeta\ngamma\nTODO here')"
  must git mv a.ts b.ts
  printf 'alpha\nbeta\ngamma\nTODO here\nnew line\n' > b.ts
  rebaseline
  assert_eq 0 "$STATUS" "feat baseline"
  commit_all feat
  gate
  assert_eq 0 "$STATUS" "status"
  assert_not_contains "$OUT" "[new]"
}

test_rename_with_changed_debt_line_is_new_at_new_path() {
  gate_setup "$(printf 'alpha\nbeta\ngamma\nTODO here')"
  must git mv a.ts b.ts
  printf 'alpha\nbeta\ngamma\nTODO changed\n' > b.ts
  rebaseline
  commit_all feat
  gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "  b.ts:4  todo  TODO changed"
  assert_contains "$OUT" "[new]"
}

test_rename_of_path_with_space_passes() {
  mkrepo
  mkdir -p "my dir"
  printf 'TODO here\n' > "my dir/a b.ts"
  rule todo paths='**/*.ts'
  cases_of todo 'TODO x'
  rebaseline
  commit_all main
  must git checkout -q -b feat
  must git mv "my dir/a b.ts" "my dir/c d.ts"
  rebaseline
  commit_all feat
  gate
  assert_eq 0 "$STATUS" "status"
  assert_not_contains "$OUT" "[new]"
  assert_contains "$(cat .gauntlet/baseline.tsv)" "my dir/c d.ts"
}

test_copy_of_debt_file_is_new() {
  gate_setup 'TODO here'
  cp a.ts c.ts
  rebaseline
  assert_eq 0 "$STATUS" "feat baseline"
  commit_all feat
  gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "  c.ts:1  todo  TODO here"
}

test_two_renames_in_one_commit_pass() {
  mkrepo
  printf 'TODO one\n' > a.ts
  printf 'TODO two\n' > c.ts
  rule todo paths='**/*.ts'
  cases_of todo 'TODO x'
  rebaseline
  commit_all main
  must git checkout -q -b feat
  must git mv a.ts b.ts
  must git mv c.ts d.ts
  rebaseline
  commit_all feat
  gate
  assert_eq 0 "$STATUS" "status"
  assert_not_contains "$OUT" "[new]"
  assert_eq "$(printf 'todo\tb.ts\tTODO one\t1\ntodo\td.ts\tTODO two\t1')" "$(cat .gauntlet/baseline.tsv)" "exact"
}
