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
  gate_setup 'ok'
  rule todo paths='**/*.ts' severity=blok
  printf 'TODO fix\n' > a.ts
  rebaseline
  assert_eq 2 "$STATUS" "baseline refuses the rule too"
  commit_all feat
  gate
  assert_eq 2 "$STATUS" "status"
  assert_contains "$OUT" "rule todo: severity must be block, shadow or track, got [blok]; run gauntlet doctor"
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
  assert_contains "$OUT" "FAIL (1 problem)"
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
  assert_contains "$OUT" "FAIL (1 problem)"
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

# A detector that prints nothing and exits 1 says "no matches": on a bad case that is a
# failure, with a message, at test-rules and at the gate.
test_a_bad_case_with_no_output_from_the_detector_fails_the_rule_tests() {
  mkrepo
  printf 'x\n' > a.ts
  rule todo paths='**/*.ts' 'detector=sh -c "exit 1" ignored {files}'
  cases_of todo 'TODO x'
  rebaseline
  commit_all main
  must git checkout -q -b feat
  printf '# changed\n' >> .gauntlet/rules/todo.md
  rebaseline
  commit_all feat
  gate
  assert_eq 1 "$STATUS" "check --ci: $OUT"
  assert_contains "$OUT" "todo  todo.bad.txt  bad case not flagged"
  assert_contains "$OUT" "FAIL (1 problem)"
  run "$G" test-rules
  assert_eq 1 "$STATUS" "test-rules: $OUT"
  assert_contains "$OUT" "todo  todo.bad.txt  bad case not flagged"
}

# The gate takes a failing run_rule_tests (status 1) as a problem even when it printed no
# line to count: the status is what says the tests failed, not the number of lines. No
# real run prints nothing and fails; the function is replaced here to say so.
test_rule_tests_status_1_without_output_still_fails_the_gate() {
  mkrepo
  printf 'x\n' > a.ts
  rule todo paths='**/*.ts'
  cases_of todo 'TODO x'
  rebaseline
  commit_all main
  must git checkout -q -b feat
  printf '# changed\n' >> .gauntlet/rules/todo.md
  rebaseline
  commit_all feat
  run bash -c '
    set -eu
    for f in core rules paths detect measure cases base exceptions check; do . "$1/lib/$f.sh"; done
    run_rule_tests() { return 1; }
    check_ci --ci --base main
  ' _ "$ROOT"
  assert_eq 1 "$STATUS" "check --ci: $OUT"
  assert_contains "$OUT" "[rule-tests]"
  assert_contains "$OUT" "FAIL (1 problem)"
  assert_not_contains "$OUT" "gauntlet: ok"
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
  assert_contains "$OUT" "FAIL (1 problem)"
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

# A check called BAD is a check: the word is what the key parser used to tag a bad key
# with, so it was taken for one and refused with a message about nothing.
test_a_check_named_BAD_is_an_ordinary_check() {
  gate_setup 'x'
  printf 'check.BAD=true\n' > .gauntlet/config
  commit_all feat
  gate
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "check:BAD"
}

# A name outside letters, digits, - and _ says what a name may hold.
test_an_invalid_check_name_says_what_a_name_may_hold() {
  gate_setup 'x'
  local row key shown
  for row in 'check.my check=true|check.my check|name [my check] must use' 'check.a.b=true|check.a.b|name [a.b] must use' \
    'check.=true|check.|name is empty; it must use' 'check.x y.paths=src/|check.x y.paths|name [x y] must use'; do
    printf '%s\n' "${row%%|*}" > .gauntlet/config
    key=${row#*|}
    shown=${key#*|}
    key=${key%%|*}
    commit_all "config $shown"
    gate
    assert_eq 2 "$STATUS" "status for [$key]: $OUT"
    assert_contains "$OUT" "bad check key $key: $shown letters, digits, - and _"
    assert_not_contains "$OUT" "check name"
  done
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
  # The limit is far above a run on a loaded machine and below the sleep, so only a hang trips it.
  with_timeout 60 "$G" check --ci --base main < <(sleep 70 2> /dev/null) > "$TMP/out" 2>&1
  STATUS=$?
  OUT=$(cat "$TMP/out")
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "  b  exit 1"
}

test_rule_tests_broken_detector_exits_2() {
  gate_setup 'x'
  rule broken paths='**/*.ts' engine=script detector="sh -c 'for f; do case \$f in *.txt) exit 2;; esac; done' sh {files}"
  script_row broken
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

# A second copy of a line the baseline already holds is the new occurrence; the first
# copy is the one that was there before.
test_second_copy_of_a_baselined_line_is_the_new_one() {
  gate_setup 'TODO fix'
  printf 'TODO fix\nTODO fix\n' > a.ts
  rebaseline
  commit_all feat
  gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "  a.ts:2  todo  TODO fix"
  assert_not_contains "$OUT" "a.ts:1"
  assert_contains "$OUT" "FAIL (1 problem)"
}

# A declared check's paths match from the start of the path: x/src/a and mysrc/a are not
# under src/, so the failing check does not run for them.
test_scope_prefix_is_not_a_substring_match() {
  gate_setup 'x'
  printf 'check.t=false\ncheck.t.paths=src/\n' > .gauntlet/config
  mkdir -p x/src mysrc
  printf 'y\n' > x/src/a
  printf 'y\n' > mysrc/a
  commit_all feat
  gate
  assert_eq 0 "$STATUS" "status"
  assert_not_contains "$OUT" "[checks]"
}

# A change staged but not committed is a dirty tree too: check --ci measures what HEAD
# holds, so it refuses.
test_staged_only_change_refuses() {
  gate_setup 'ok'
  printf 'TODO fix\n' > a.ts
  must git add a.ts
  gate
  assert_eq 2 "$STATUS" "status"
  assert_contains "$OUT" "commit or stash first"
}

# A baseline row left on a path the base does not have (a file deleted without a new
# baseline) must not hide a new occurrence in the file a rename creates at that path.
test_stale_base_row_on_rename_destination_is_dropped() {
  mkrepo
  printf 'alpha\nbeta\ngamma\nTODO x\n' > a.ts
  # Two copies, so the stale row is the larger count: the base holds one count per key,
  # and a kept stale row would hide the new copy.
  printf 'TODO x\nTODO x\n' > b.ts
  rule todo paths='**/*.ts'
  cases_of todo 'TODO x'
  rebaseline
  commit_all main
  must git rm -q b.ts
  commit_all "drop b without a new baseline"
  must git checkout -q -b feat
  must git mv a.ts b.ts
  printf 'alpha\nbeta\ngamma\nTODO x\nTODO x\n' > b.ts
  rebaseline
  commit_all feat
  gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "  b.ts:5  todo  TODO x"
  assert_contains "$OUT" "[new]"
}

# A pure rename of shadow-rule debt is still the same debt: nothing is reported as
# would-have-failed at the new path.
test_pure_rename_of_shadow_debt_prints_no_shadow_line() {
  gate_setup 'TODO here' severity=shadow
  must git mv a.ts b.ts
  rebaseline
  commit_all feat
  gate
  assert_eq 0 "$STATUS" "status"
  assert_not_contains "$OUT" "would have failed"
}

# R27: baseline, check --staged and check --ci validate every rule before they
# measure. rv_broken <kind> [stage] writes .gauntlet/rules/bad.md broken one way.
rv_broken() {
  local stage=${2:-commit}
  case "$1" in
    # detecter: for detector:, so the detector is an empty command.
    typo)
      printf -- '---\nid: bad\nseverity: block\nstage: %s\nengine: rg\ndetecter: rg --with-filename --line-number --no-heading TODO {files}\npaths: **\nexclude:\nfix: remove it\nsource: pending\nsince: 2026-10-22\n---\nBroken.\n' "$stage" > .gauntlet/rules/bad.md ;;
    # a wrong id, and no fix, source or since.
    wrongid)
      printf -- '---\nid: wrongid\nseverity: block\nstage: %s\nengine: rg\ndetector: rg --with-filename --line-number --no-heading TODO {files}\npaths: **\nexclude:\n---\nBroken.\n' "$stage" > .gauntlet/rules/bad.md ;;
    unclosed)
      printf -- '---\nid: bad\nseverity: block\nstage: %s\n' "$stage" > .gauntlet/rules/bad.md ;;
    script)
      rule bad engine=script stage="$stage" ;;
    *) fail "rv_broken: unknown kind $1" ;;
  esac
}

# rv_gates <kind> <message>: with the rule broken that way and a new TODO, every
# gate exits 2, prints the message and never says ok.
rv_gates() {
  gate_setup 'ok'
  rv_broken "$1"
  printf 'TODO x\n' > a.ts
  must git add -A
  run "$G" baseline
  assert_eq 2 "$STATUS" "baseline: $OUT"
  assert_contains "$OUT" "$2"
  run "$G" check --staged
  assert_eq 2 "$STATUS" "check --staged: $OUT"
  assert_contains "$OUT" "$2"
  assert_not_contains "$OUT" "gauntlet: ok"
  commit_all feat
  gate
  assert_eq 2 "$STATUS" "check --ci: $OUT"
  assert_contains "$OUT" "$2"
  assert_not_contains "$OUT" "gauntlet: ok"
}

test_gates_refuse_a_misspelled_detector_key() {
  rv_gates typo "rule bad: detector must not be empty; run gauntlet doctor"
}

test_gates_refuse_a_wrong_id_and_a_missing_fix() {
  rv_gates wrongid "rule bad: id [wrongid] must equal the file stem [bad]; run gauntlet doctor"
  assert_contains "$OUT" "rule bad: fix must not be empty; run gauntlet doctor"
  assert_contains "$OUT" "rule bad: source must not be empty; run gauntlet doctor"
  assert_contains "$OUT" "rule bad: since must be YYYY-MM-DD, got []; run gauntlet doctor"
}

test_gates_refuse_an_unclosed_frontmatter() {
  rv_gates unclosed "rule bad: frontmatter not closed; run gauntlet doctor"
}

test_gates_refuse_a_script_rule_without_a_script_row() {
  rv_gates script "rule bad: engine=script needs a script row for [bad] in .gauntlet/exceptions.tsv; run gauntlet doctor"
}

# The row is all that is asked for: with it the same rule passes every gate.
test_gates_accept_a_script_rule_with_its_script_row() {
  gate_setup 'ok'
  rv_broken script
  cases_of bad 'TODO x'
  script_row bad
  rebaseline
  assert_eq 0 "$STATUS" "baseline: $OUT"
  run "$G" check --staged
  assert_eq 0 "$STATUS" "check --staged: $OUT"
  commit_all feat
  gate
  assert_eq 0 "$STATUS" "check --ci: $OUT"
}

# A push-stage rule is not measured at commit, but it is validated there: the setup
# is broken for the push gate and for CI, and the commit gate says so early.
test_commit_gate_refuses_a_broken_push_stage_rule() {
  gate_setup 'ok'
  rv_broken typo push
  printf 'TODO x\n' > a.ts
  must git add -A
  run "$G" check --staged
  assert_eq 2 "$STATUS" "check --staged: $OUT"
  assert_contains "$OUT" "rule bad: detector must not be empty; run gauntlet doctor"
}

# The message lists the problems of every broken rule, not just the first.
test_gates_report_every_broken_rule() {
  gate_setup 'ok'
  rv_broken typo
  rule worse severity=hard
  must git add -A
  run "$G" check --staged
  assert_eq 2 "$STATUS" "check --staged: $OUT"
  assert_contains "$OUT" "rule bad: detector must not be empty; run gauntlet doctor"
  assert_contains "$OUT" "rule worse: severity must be block, shadow or track, got [hard]; run gauntlet doctor"
}

# R28: a gate result is the one a fresh clone produces. clone_gate <branch>: clone
# the repo at $TMP/repo (what a push publishes) into $TMP/clone and run check --ci there.
clone_gate() {
  must git clone -q --branch "$1" "$TMP/repo" "$TMP/clone"
  must cd "$TMP/clone"
  run "$G" check --ci --base origin/main
}

# A detector with no {files} walks the disk. Its rows are kept only for tracked
# files, so an ignored build output and an untracked scratch file leave no debt that
# a clone cannot reproduce, and `gauntlet baseline` does not write it again.
test_whole_program_rows_skip_untracked_and_ignored_files() {
  mkrepo
  printf 'dist/\n' > .gitignore
  printf 'TODO tracked\n' > b.ts
  must mkdir dist
  printf 'TODO generated\n' > dist/gen.txt
  printf 'TODO loose\n' > "loose file.txt"
  rule prog stage=push "detector=rg --no-ignore --with-filename --line-number --no-heading TODO ."
  must git add .gitignore b.ts .gauntlet
  run "$G" baseline
  assert_eq 0 "$STATUS" "baseline: $OUT"
  want=$(cat .gauntlet/baseline.tsv)
  assert_contains "$want" "b.ts"
  assert_not_contains "$want" "dist/gen.txt"
  assert_not_contains "$want" "loose file.txt"
  # Commit by name: git add -A would track the loose file and change the answer.
  must git add .gauntlet/baseline.tsv
  must git commit -q -m main
  must git checkout -q -b feat
  printf 'fine\n' > c.ts
  must git add c.ts
  must git commit -q -m feat
  gate
  assert_eq 0 "$STATUS" "check --ci in the dev checkout: $OUT"
  clone_gate feat
  assert_eq 0 "$STATUS" "check --ci in a fresh clone: $OUT"
}

# The rule tests of the gate read the cases git tracks: untracked case files exist
# only on this machine, so a rule committed without them fails in a clone and here.
test_ci_rule_tests_read_tracked_case_files_only() {
  gate_setup 'ok'
  rule newrule paths='**/*.ts'
  cases_of newrule 'TODO y'
  must git add .gauntlet/rules/newrule.md
  must git commit -q -m "feat: newrule without its cases"
  gate
  assert_eq 1 "$STATUS" "check --ci: $OUT"
  assert_contains "$OUT" "[rule-tests]"
  assert_contains "$OUT" "newrule  bad  no cases"
  clone_gate feat
  assert_eq 1 "$STATUS" "check --ci in a fresh clone: $OUT"
  assert_contains "$OUT" "newrule  bad  no cases"
}

# Authoring is the other way round: standalone test-rules reads untracked cases, so a
# rule can be tried before anything is committed.
test_standalone_test_rules_reads_untracked_case_files() {
  gate_setup 'ok'
  rule newrule paths='**/*.ts'
  cases_of newrule 'TODO y'
  run "$G" test-rules
  assert_eq 0 "$STATUS" "test-rules: $OUT"
}

# A developer's ripgrep config (smart-case here) must not change what a detector finds.
test_ripgrep_config_does_not_change_the_baseline() {
  mkrepo
  printf 'TODO upper\ntodo lower\n' > a.ts
  rule low paths='**/*.ts' "detector=rg --with-filename --line-number --no-heading todo {files}"
  must git add -A
  run "$G" baseline
  assert_eq 0 "$STATUS" "baseline: $OUT"
  must cp .gauntlet/baseline.tsv "$TMP/plain.tsv"
  assert_eq 1 "$(wc -l < "$TMP/plain.tsv" | tr -d ' ')" "one row without the config"
  printf -- '--smart-case\n' > "$TMP/rg.conf"
  run env RIPGREP_CONFIG_PATH="$TMP/rg.conf" "$G" baseline
  assert_eq 0 "$STATUS" "baseline with a ripgrep config: $OUT"
  must cmp "$TMP/plain.tsv" .gauntlet/baseline.tsv
}

# R32: an unreadable base is not an absent one. With the base's baseline blob gone, the
# tree still lists it: the gate exits 2 and never drops to onboarding, which would turn
# off the new, global, shadow and track checks.
test_ci_unreadable_base_baseline_is_exit_2_not_onboarding() {
  gate_setup 'TODO x'
  printf 'TODO x\nTODO y\n' > a.ts
  rebaseline
  commit_all feat
  unreadable_object main:.gauntlet/baseline.tsv
  gate
  assert_eq 2 "$STATUS" "check --ci: $OUT"
  assert_contains "$OUT" "gauntlet: cannot read .gauntlet/baseline.tsv at $(git rev-parse main)"
  assert_not_contains "$OUT" "fatal:"
  assert_not_contains "$OUT" "no baseline at base"
  assert_not_contains "$OUT" "gauntlet: ok"
}

test_staged_unreadable_head_baseline_is_exit_2_not_onboarding() {
  gate_setup 'TODO x
TODO z'
  printf 'TODO x\n' > a.ts
  rebaseline
  must git add .gauntlet/baseline.tsv
  unreadable_object HEAD:.gauntlet/baseline.tsv
  run "$G" check --staged
  assert_eq 2 "$STATUS" "check --staged: $OUT"
  assert_not_contains "$OUT" "no baseline at HEAD"
  assert_not_contains "$OUT" "gauntlet: ok"
}

# r32_ci_setup: main with one TODO and its baseline, feat with two; the gate has
# something to compare. r32_refused: the gate stopped at exit 2 with git's error and
# did not fall back to onboarding.
r32_ci_setup() {
  gate_setup 'TODO x'
  printf 'TODO x\nTODO y\n' > a.ts
  rebaseline
  commit_all feat
}

r32_refused() {
  assert_eq 2 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "simulated failure"
  assert_not_contains "$OUT" "no baseline at"
  assert_not_contains "$OUT" "gauntlet: ok"
}

# Each read of the base has its own site in the gate. A listing that fails at any of
# them is exit 2: absent and unreadable are different answers.
test_ci_failed_listing_of_a_rule_at_base_is_exit_2() {
  r32_ci_setup
  git_fails ls-tree .gauntlet/rules/todo.md
  gate
  r32_refused
}

test_ci_failed_listing_of_the_baseline_at_base_is_exit_2() {
  r32_ci_setup
  git_fails ls-tree .gauntlet/baseline.tsv "$(git rev-parse main)"
  gate
  r32_refused
}

test_ci_failed_listing_of_the_rules_dir_at_base_is_exit_2() {
  r32_ci_setup
  git_fails ls-tree .gauntlet/rules
  gate
  r32_refused
}

test_staged_failed_listing_of_a_rule_at_head_is_exit_2() {
  gate_setup 'TODO x'
  printf 'TODO x\n' > b.ts
  must git add b.ts
  git_fails ls-tree .gauntlet/rules/todo.md HEAD
  run "$G" check --staged
  r32_refused
}

test_staged_failed_listing_of_the_baseline_at_head_is_exit_2() {
  gate_setup 'TODO x'
  printf 'TODO x\n' > b.ts
  must git add b.ts
  git_fails ls-tree .gauntlet/baseline.tsv HEAD
  run "$G" check --staged
  r32_refused
}

test_staged_failed_listing_of_the_baseline_in_the_index_is_exit_2() {
  gate_setup 'TODO x'
  printf 'TODO x\n' > b.ts
  must git add b.ts
  git_fails ls-files .gauntlet/baseline.tsv
  run "$G" check --staged
  r32_refused
}

# A hook inherits the pathspec switches of `git --glob-pathspecs commit` (and the other
# three) in its environment. The gates read the base and the index by exact path, so
# none of them may change the answer on a valid repo.
test_gates_ignore_pathspec_switches_in_the_environment() {
  gate_setup 'ok'
  local v
  for v in GIT_GLOB_PATHSPECS GIT_ICASE_PATHSPECS GIT_NOGLOB_PATHSPECS GIT_LITERAL_PATHSPECS; do
    run env "$v=1" "$G" check --ci --base main
    assert_eq 0 "$STATUS" "check --ci under $v: $OUT"
  done
  printf 'fine\n' > b.ts
  must git add b.ts
  for v in GIT_GLOB_PATHSPECS GIT_ICASE_PATHSPECS GIT_NOGLOB_PATHSPECS GIT_LITERAL_PATHSPECS; do
    run env "$v=1" "$G" check --staged
    assert_eq 0 "$STATUS" "check --staged under $v: $OUT"
  done
}

# R31 through the gates: a tab or a newline in a tracked path is exit 2 naming the path,
# never a corrupt baseline and never a silent skip. odd_path_repo <name>
# puts such a file on top of a repo whose gates pass (printf %b escapes: \t, \n).
odd_path_repo() {
  gate_setup 'ok'
  printf 'x\n' > "$(printf '%b' "$1")"
}

odd_path_refused() {
  assert_eq 2 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "$1"
  assert_contains "$OUT" "rename the file"
  assert_not_contains "$OUT" "gauntlet: ok"
}

test_gates_refuse_a_tab_in_a_path() {
  odd_path_repo 'a\tb.ts'
  must git add -A
  run "$G" baseline
  odd_path_refused 'a\tb.ts'
  assert_eq "" "$(cat .gauntlet/baseline.tsv)" "the baseline is not written"
  run "$G" check --staged
  odd_path_refused 'a\tb.ts'
  commit_all feat
  gate
  odd_path_refused 'a\tb.ts'
}

# The same through a gate: nothing a file name holds reaches the terminal as a control byte.
test_a_refused_path_with_escape_sequences_prints_none() {
  odd_path_repo 'x\t\033[2J\033]0;pwned\ay.ts'
  must git add -A
  run "$G" baseline
  odd_path_refused 'x\t\x1b[2J\x1b]0;pwned\x07y.ts'
  assert_eq "" "$(printf '%s' "$OUT" | LC_ALL=C tr -d '\n' | LC_ALL=C tr -d '[:print:]')" "control bytes in the output"
}

test_gates_refuse_a_newline_in_a_path() {
  odd_path_repo 'c\nd.ts'
  must git add -A
  run "$G" baseline
  odd_path_refused 'c\nd.ts'
  assert_eq "" "$(cat .gauntlet/baseline.tsv)" "the baseline is not written"
  run "$G" check --staged
  odd_path_refused 'c\nd.ts'
  commit_all feat
  gate
  odd_path_refused 'c\nd.ts'
}

# C1: R31 refuses an odd path that is still in the tree, never the change that removes it.
# odd_base_repo: main tracks 'a<TAB>b.ts' (committed before the gate existed, so the baseline
# was written without it) and r.ts with one violation; branch feat is checked out, clean.
odd_base_repo() {
  mkrepo
  printf 'ok\n' > a.ts
  printf 'TODO old\n' > r.ts
  rule todo paths='**/*.ts'
  cases_of todo 'TODO x'
  rebaseline
  assert_eq 0 "$STATUS" "main baseline"
  printf 'x\n' > "$(printf 'a\tb.ts')"
  commit_all main
  must git checkout -q -b feat
}

# odd_path_gone: after the change, no odd path is left in the tree.
odd_path_gone() {
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_not_contains "$OUT" "rename the file"
  assert_not_contains "$OUT" "path with a tab"
}

test_a_branch_can_rename_an_odd_path_away() {
  odd_base_repo
  must git mv "$(printf 'a\tb.ts')" ab.ts
  must git mv r.ts r2.ts
  rebaseline
  assert_eq 0 "$STATUS" "feat baseline: $OUT"
  run "$G" check --staged
  odd_path_gone
  commit_all rename
  gate
  odd_path_gone
  assert_contains "$OUT" "gauntlet: ok"
  assert_not_contains "$OUT" "[new]"
}

test_a_branch_can_delete_an_odd_path() {
  odd_base_repo
  must git rm -q "$(printf 'a\tb.ts')"
  rebaseline
  assert_eq 0 "$STATUS" "feat baseline: $OUT"
  run "$G" check --staged
  odd_path_gone
  commit_all delete
  gate
  odd_path_gone
  assert_contains "$OUT" "gauntlet: ok"
}

test_a_branch_can_delete_a_newline_path() {
  mkrepo
  printf 'ok\n' > a.ts
  rule todo paths='**/*.ts'
  cases_of todo 'TODO x'
  rebaseline
  printf 'x\n' > "$(printf 'c\nd.ts')"
  commit_all main
  must git checkout -q -b feat
  must git rm -q "$(printf 'c\nd.ts')"
  rebaseline
  run "$G" check --staged
  odd_path_gone
  commit_all delete
  gate
  odd_path_gone
  assert_contains "$OUT" "gauntlet: ok"
}

# The base's own rule listing is a tree listing too: a rule file with an odd name that the
# branch removes does not make the gate refuse the change. The removal is read as a removal.
test_a_branch_can_remove_a_rule_file_with_an_odd_name() {
  gate_setup 'ok'
  must git checkout -q main
  printf 'junk\n' > ".gauntlet/rules/$(printf 'x\ty').md"
  commit_all odd-rule
  must git checkout -q -b feat2
  must git rm -q ".gauntlet/rules/$(printf 'x\ty').md"
  rebaseline
  commit_all remove-odd-rule
  gate
  assert_not_contains "$OUT" "path with a tab"
  assert_contains "$OUT" "rule file removed"
}

# An unstaged edit of a tracked odd file is in the unstaged diff only to be compared with the
# staged paths; the commit that does not stage it goes through.
test_an_unstaged_edit_of_an_odd_path_does_not_stop_a_commit() {
  odd_base_repo
  printf 'more\n' >> "$(printf 'a\tb.ts')"
  printf 'more\n' >> a.ts
  must git add a.ts
  run "$G" check --staged
  assert_eq 0 "$STATUS" "check --staged: $OUT"
  assert_not_contains "$OUT" "path with a tab"
}

test_renaming_into_an_odd_name_is_still_refused() {
  odd_base_repo
  must git mv a.ts "$(printf 'e\tf.ts')"
  run "$G" check --staged
  odd_path_refused 'e\tf.ts'
  commit_all rename
  gate
  odd_path_refused 'e\tf.ts'
}

test_an_odd_path_that_survives_is_still_refused() {
  odd_base_repo
  printf 'more\n' >> a.ts
  must git add -A
  run "$G" check --staged
  assert_eq 0 "$STATUS" "check --staged ignores a tracked odd path it does not stage: $OUT"
  run "$G" baseline
  odd_path_refused 'a\tb.ts'
  commit_all edit
  gate
  odd_path_refused 'a\tb.ts'
}

# I5: a tracked symlink to nothing is not a file the detectors can read; with the stock rg rule it
# made every run exit 2 ("rg: dangling.ts: No such file or directory"). It is left out, and the
# other files count as usual.
test_a_dangling_symlink_does_not_break_the_gates() {
  gate_setup 'ok'
  printf 'TODO here\n' > b.ts
  must ln -s /nonexistent/target dangling.ts
  rebaseline
  assert_eq 0 "$STATUS" "baseline: $OUT"
  assert_eq "$(printf 'todo\tb.ts\tTODO here\t1')" "$(cat .gauntlet/baseline.tsv)" "the other file counts, the link does not"
  run "$G" check --staged
  assert_eq 1 "$STATUS" "check --staged sees the new violation in b.ts, not a broken detector: $OUT"
  assert_contains "$OUT" "b.ts:1"
  assert_not_contains "$OUT" "broken detector"
  commit_all feat
  gate
  assert_eq 1 "$STATUS" "check --ci sees the new violation in b.ts, not a broken detector: $OUT"
  assert_contains "$OUT" "b.ts:1"
  assert_not_contains "$OUT" "broken detector"
}

# Counts read as English: 1 rule, 2 rules; 1 problem, 2 problems.
test_report_counts_are_singular_for_one() {
  gate_setup 'ok'
  gate
  assert_eq 0 "$STATUS" "check --ci: $OUT"
  assert_contains "$OUT" "gauntlet  ci · 1 rule · "
  assert_not_contains "$OUT" "1 rules"
  rule second paths='**/*.ts'
  cases_of second 'TODO x'
  rebaseline
  commit_all two-rules
  gate
  assert_contains "$OUT" "gauntlet  ci · 2 rules · "
}

# A CRLF config: the touched setting and a declared check read the same as with LF.
test_crlf_config_reads_like_lf() {
  gate_setup 'x'
  printf 'touched=on\r\ncheck.hello=echo hi\r\ncheck.hello.paths=src/\r\ncheck.hello.ci=on\r\n' > .gauntlet/config
  mkdir -p src
  printf 'y\n' > src/b.ts
  rebaseline
  commit_all feat
  gate
  assert_eq 0 "$STATUS" "check --ci: $OUT"
  assert_contains "$OUT" "check:hello"
  assert_not_contains "$OUT" "touched must be on or off"
  assert_not_contains "$OUT" "bad check key"
}

# R37: pre-push and CI run the branch's own vendored runner, so a branch that edits it is
# judged by what it edited. The gate cannot stop that, and says so: one note, same text
# locally and in CI, never a failure.
RUNNER_NOTE='note: the vendored runner changed in this branch (.gauntlet/bin or .gauntlet/lib differ from the base); review it'

# runner_setup: main holds a vendored runner (stand-in files: the gate only compares them),
# then a feat branch.
runner_setup() {
  mkrepo
  printf 'ok\n' > a.ts
  rule todo paths='**/*.ts'
  cases_of todo 'TODO x'
  must mkdir -p .gauntlet/bin .gauntlet/lib
  printf 'bin v1\n' > .gauntlet/bin/gauntlet
  printf 'lib v1\n' > .gauntlet/lib/core.sh
  rebaseline
  commit_all main
  must git checkout -q -b feat
}

test_an_unchanged_runner_prints_no_note() {
  runner_setup
  printf 'still ok\n' > a.ts
  rebaseline
  commit_all feat
  gate
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_not_contains "$OUT" "vendored runner"
}

test_a_changed_lib_prints_the_note_and_passes() {
  runner_setup
  printf 'lib v2\n' > .gauntlet/lib/core.sh
  rebaseline
  commit_all feat
  gate
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "$RUNNER_NOTE"
  assert_contains "$OUT" "gauntlet: ok"
}

test_a_changed_bin_prints_the_note_and_passes() {
  runner_setup
  printf 'bin v2\n' > .gauntlet/bin/gauntlet
  rebaseline
  commit_all feat
  gate
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "$RUNNER_NOTE"
}

test_a_new_file_in_the_runner_prints_the_note() {
  runner_setup
  printf 'new\n' > .gauntlet/lib/extra.sh
  rebaseline
  commit_all feat
  gate
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "$RUNNER_NOTE"
}

test_a_removed_runner_prints_the_note() {
  runner_setup
  must git rm -q -r .gauntlet/bin .gauntlet/lib
  rebaseline
  commit_all feat
  gate
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "$RUNNER_NOTE"
}

# The note is information: a branch that also breaks the gate fails for that, once.
test_the_note_does_not_change_a_failing_exit_code() {
  runner_setup
  printf 'lib v2\n' > .gauntlet/lib/core.sh
  printf 'TODO fix\n' > a.ts
  rebaseline
  commit_all feat
  gate
  assert_eq 1 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "$RUNNER_NOTE"
  assert_contains "$OUT" "FAIL (1 problem)"
}

# First install: the base has no runner, so there is nothing it could have changed.
test_a_first_install_prints_no_note() {
  gate_setup 'ok'
  must mkdir -p .gauntlet/bin .gauntlet/lib
  printf 'bin v1\n' > .gauntlet/bin/gauntlet
  printf 'lib v1\n' > .gauntlet/lib/core.sh
  rebaseline
  commit_all install
  gate
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_not_contains "$OUT" "vendored runner"
}

test_the_runner_note_is_the_same_in_ci_and_from_a_subdirectory() {
  runner_setup
  printf 'lib v2\n' > .gauntlet/lib/core.sh
  rebaseline
  commit_all feat
  gate
  assert_eq 0 "$STATUS" "status: $OUT"
  want=$(printf '%s\n' "$OUT" | grep -v ' ms$' | grep -v '^gauntlet  [a-z]* · ')
  CI=true gate
  assert_eq 0 "$STATUS" "CI: $OUT"
  assert_eq "$want" "$(printf '%s\n' "$OUT" | grep -v ' ms$' | grep -v '^gauntlet  [a-z]* · ')" "same report with CI=true"
  must mkdir -p sub
  must cd sub
  gate
  assert_eq 0 "$STATUS" "subdirectory: $OUT"
  assert_contains "$OUT" "$RUNNER_NOTE"
}

# R32: a listing git cannot answer is exit 2 on every side, never "no runner".
test_an_unreadable_runner_at_the_base_is_exit_2() {
  runner_setup
  printf 'lib v2\n' > .gauntlet/lib/core.sh
  rebaseline
  commit_all feat
  git_fails ls-tree .gauntlet/bin "$(git rev-parse main)"
  gate
  assert_eq 2 "$STATUS" "bin at the base: $OUT"
  assert_contains "$OUT" "simulated failure"
  assert_not_contains "$OUT" "vendored runner"
}

test_an_unreadable_lib_at_the_base_is_exit_2() {
  runner_setup
  printf 'lib v2\n' > .gauntlet/lib/core.sh
  rebaseline
  commit_all feat
  git_fails ls-tree .gauntlet/lib "$(git rev-parse main)"
  gate
  assert_eq 2 "$STATUS" "lib at the base: $OUT"
  assert_contains "$OUT" "simulated failure"
}

test_an_unreadable_runner_at_head_is_exit_2() {
  runner_setup
  printf 'lib v2\n' > .gauntlet/lib/core.sh
  rebaseline
  commit_all feat
  git_fails ls-tree .gauntlet/lib HEAD
  gate
  assert_eq 2 "$STATUS" "lib at HEAD: $OUT"
  assert_contains "$OUT" "simulated failure"
}

# FRD-03 section 4.11: what is checked is what is pushed. The pre-push hook passes git's
# stdin, one "<local ref> <local sha> <remote ref> <remote sha>" line per pushed ref, to
# `check --ci --pre-push`, which refuses a pushed branch tip that is not the checked-out HEAD.
ZERO=0000000000000000000000000000000000000000

# prepush_setup: main and a checked-out feat one commit ahead; $PP_HEAD is feat's tip and
# $PP_MAIN is main's.
prepush_setup() {
  gate_setup 'ok'
  printf 'more\n' > b.ts
  rebaseline
  commit_all feat
  PP_HEAD=$(git rev-parse HEAD)
  PP_MAIN=$(git rev-parse main)
}

# prepush <input>: run the gate with the given text on stdin.
prepush() {
  printf '%s' "$1" > "$TMP/prepush.in"
  run "$G" check --ci --pre-push --base main < "$TMP/prepush.in"
}

test_pre_push_judges_the_pushed_branch_when_it_is_head() {
  prepush_setup
  prepush "refs/heads/feat $PP_HEAD refs/heads/feat $ZERO"$'\n'
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "gauntlet: ok"
}

test_pre_push_refuses_a_branch_that_is_not_head() {
  prepush_setup
  prepush "refs/heads/main $PP_MAIN refs/heads/main $PP_MAIN"$'\n'
  assert_eq 1 "$STATUS" "status: $OUT"
  assert_eq "gauntlet checks the checked-out branch; check out main and push again" "$OUT" "message, and no report"
}

# One line per refused ref, all of them, in the order git sent them.
test_pre_push_names_every_refused_branch() {
  prepush_setup
  must git branch other "$PP_MAIN"
  prepush "refs/heads/other $PP_MAIN refs/heads/other $ZERO"$'\n'"refs/heads/feat $PP_HEAD refs/heads/feat $ZERO"$'\n'"refs/heads/main $PP_MAIN refs/heads/main $PP_MAIN"$'\n'
  assert_eq 1 "$STATUS" "status: $OUT"
  want="gauntlet checks the checked-out branch; check out other and push again"$'\n'"gauntlet checks the checked-out branch; check out main and push again"
  assert_eq "$want" "$OUT" "one line per refused ref"
}

# The branch to check out is the local one when the push renames it (other:release).
test_pre_push_names_the_local_branch_of_a_renaming_push() {
  prepush_setup
  must git branch other "$PP_MAIN"
  prepush "refs/heads/other $PP_MAIN refs/heads/release $ZERO"$'\n'
  assert_eq 1 "$STATUS" "status: $OUT"
  assert_eq "gauntlet checks the checked-out branch; check out other and push again" "$OUT" "message"
}

# HEAD:other pushes HEAD's tip under another name: what is checked is what is pushed.
test_pre_push_passes_head_pushed_under_another_name() {
  prepush_setup
  prepush "HEAD $PP_HEAD refs/heads/other $ZERO"$'\n'
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "gauntlet: ok"
}

# Gerrit takes a push to refs/for/<branch> as a change on that branch: what it holds is pushed
# like a branch tip.
test_pre_push_refuses_a_gerrit_push_of_a_commit_that_is_not_head() {
  prepush_setup
  must git branch other "$PP_MAIN"
  prepush "refs/heads/other $PP_MAIN refs/for/main $ZERO"$'\n'
  assert_eq 1 "$STATUS" "status: $OUT"
  assert_eq "gauntlet checks the checked-out branch; check out other and push again" "$OUT" "message"
}

test_pre_push_passes_head_pushed_to_gerrit() {
  prepush_setup
  prepush "HEAD $PP_HEAD refs/for/main $ZERO"$'\n'
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "gauntlet: ok"
}

# A local ref that is not a branch (HEAD~1, a sha) has no branch to check out: the message says
# the commit is not the checked-out one, whatever the remote ref is called.
test_pre_push_names_the_commit_when_the_local_ref_is_not_a_branch() {
  prepush_setup
  prepush "HEAD~1 $PP_MAIN refs/heads/feat $PP_HEAD"$'\n'
  assert_eq 1 "$STATUS" "status: $OUT"
  assert_eq "gauntlet checks the checked-out commit; check out the commit you are pushing and push again" "$OUT" "message"
  prepush "$PP_MAIN $PP_MAIN refs/for/main $ZERO"$'\n'
  assert_eq 1 "$STATUS" "a sha to Gerrit: $OUT"
  assert_eq "gauntlet checks the checked-out commit; check out the commit you are pushing and push again" "$OUT" "message for a sha"
}

# Every other namespace stays out of it: a pull request ref, a merge request ref, a note.
test_pre_push_skips_the_other_namespaces() {
  prepush_setup
  prepush "refs/heads/other $PP_MAIN refs/pull/7/head $ZERO"$'\n'"refs/heads/other $PP_MAIN refs/merge-requests/7/head $ZERO"$'\n'"refs/heads/other $PP_MAIN refs/changes/07/7/1 $ZERO"$'\n'
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "gauntlet: ok"
}

# A delete has the zero sha (and "(delete)" for a local ref); a tag is not a branch.
test_pre_push_skips_deletes_and_tags() {
  prepush_setup
  prepush "(delete) $ZERO refs/heads/old $PP_MAIN"$'\n'"refs/heads/gone $ZERO refs/heads/gone $PP_MAIN"$'\n'"refs/tags/v1 $PP_MAIN refs/tags/v1 $ZERO"$'\n'"refs/notes/c $PP_MAIN refs/notes/c $ZERO"$'\n'
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "gauntlet: ok"
}

# A 64-hex zero sha (SHA-256 repositories) is a delete too.
test_pre_push_reads_a_sha256_zero_sha_as_a_delete() {
  prepush_setup
  prepush "(delete) 0000000000000000000000000000000000000000000000000000000000000000 refs/heads/old $PP_MAIN"$'\n'
  assert_eq 0 "$STATUS" "status: $OUT"
}

test_pre_push_without_ref_lines_judges_head() {
  prepush_setup
  prepush ""
  assert_eq 0 "$STATUS" "empty stdin: $OUT"
  assert_contains "$OUT" "gauntlet: ok"
  prepush $'\n\n'
  assert_eq 0 "$STATUS" "blank lines: $OUT"
}

test_pre_push_fails_closed_on_a_short_line() {
  prepush_setup
  prepush "refs/heads/feat $PP_HEAD refs/heads/feat"$'\n'
  assert_eq 2 "$STATUS" "three fields: $OUT"
  assert_eq "gauntlet: unexpected pre-push input" "$OUT" "message"
  prepush "garbage"$'\n'
  assert_eq 2 "$STATUS" "one field: $OUT"
  prepush "refs/heads/feat $PP_HEAD refs/heads/feat $ZERO"$'\n'"refs/heads/main"$'\n'
  assert_eq 2 "$STATUS" "a short line after a good one: $OUT"
}

test_pre_push_reads_crlf_input_like_lf() {
  prepush_setup
  prepush $'\r\n'"refs/heads/feat $PP_HEAD refs/heads/feat $ZERO"$'\r\n'
  assert_eq 0 "$STATUS" "head, CRLF: $OUT"
  prepush "refs/heads/main $PP_MAIN refs/heads/main $PP_MAIN"$'\r\n'
  assert_eq 1 "$STATUS" "other branch, CRLF: $OUT"
  assert_eq "gauntlet checks the checked-out branch; check out main and push again" "$OUT" "message"
}

# Without the flag stdin is never read: CI and a manual run cannot be refused by input.
test_check_ci_without_the_flag_never_reads_stdin() {
  prepush_setup
  printf 'refs/heads/main %s refs/heads/main %s\n' "$PP_MAIN" "$PP_MAIN" > "$TMP/prepush.in"
  run "$G" check --ci --base main < "$TMP/prepush.in"
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "gauntlet: ok"
  CI=true run "$G" check --ci --base main < "$TMP/prepush.in"
  assert_eq 0 "$STATUS" "CI=true: $OUT"
}

# The refusal comes before the work: a branch that is not checked out is not measured.
test_pre_push_refusal_precedes_the_dirty_tree_refusal() {
  prepush_setup
  printf 'dirty\n' > b.ts
  prepush "refs/heads/main $PP_MAIN refs/heads/main $PP_MAIN"$'\n'
  assert_eq 1 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "check out main and push again"
}

# A terminal on stdin means a person ran it, not git: nothing to read, HEAD is judged. The
# refusing line is typed into the terminal, where a gate that read it would refuse.
test_pre_push_with_a_terminal_on_stdin_judges_head() {
  prepush_setup
  if ! script --version 2>&1 | grep -q util-linux; then
    skip "script is not util-linux's: no way to give the gate a terminal"
    return 77
  fi
  printf 'refs/heads/main %s refs/heads/main %s\n' "$PP_MAIN" "$PP_MAIN" > "$TMP/prepush.in"
  run script -qec "'$G' check --ci --pre-push --base main" /dev/null < "$TMP/prepush.in"
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "gauntlet: ok"
}

test_pre_push_flag_is_not_accepted_by_the_commit_gate() {
  prepush_setup
  run "$G" check --staged --pre-push
  assert_eq 2 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "usage: gauntlet check --staged"
}
