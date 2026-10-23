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
# over **/*.ts and a committed baseline, then a feat branch.
gate_setup() {
  local content=$1
  shift
  mkrepo
  printf '%s\n' "$content" > a.ts
  rule todo paths='**/*.ts' "$@"
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
