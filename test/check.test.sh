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
  run "$G" baseline
  assert_eq 0 "$STATUS" "main baseline"
  commit_all main
  must git checkout -q -b feat
}

# gate: run check --ci against main; result in $OUT and $STATUS.
gate() {
  run "$G" check --ci --base main
}

test_new_violation_fails() {
  gate_setup 'ok'
  printf 'TODO fix\n' > a.ts
  run "$G" baseline
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
  run "$G" baseline
  commit_all feat
  gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "my dir/ä b.ts:1"
}

test_moved_line_passes() {
  gate_setup 'TODO here'
  printf 'ok\nTODO here\n' > a.ts
  run "$G" baseline
  commit_all moved
  gate
  assert_eq 0 "$STATUS" "status"
  assert_not_contains "$OUT" "[new]"
}

test_global_rise_fails() {
  gate_setup 'TODO x'
  printf 'TODO x\n' > b.ts
  run "$G" baseline
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
  run "$G" baseline
  commit_all feat
  gate
  assert_eq 0 "$STATUS" "status"
  assert_contains "$OUT" "would have failed"
}

test_track_rise_reports() {
  gate_setup 'ok' severity=track
  printf 'TODO fix\n' > a.ts
  run "$G" baseline
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
  run "$G" baseline
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
  run "$G" baseline
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
