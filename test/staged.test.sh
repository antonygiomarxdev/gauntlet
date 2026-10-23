# shellcheck shell=bash
# shellcheck disable=SC2153 # ROOT, G and STATUS are set by test/lib.sh
# Tests for check --staged, the commit gate run from pre-commit: new violations
# block, a commit that lowers debt carries the lowered baseline, partial staging
# skips auto-tighten, push-stage rules do not run, and the budget only warns. Each
# commit test installs the pre-commit hook by hand and runs a real git commit.

# staged_setup <content> [rule options...]: a main branch with one todo rule over
# **/*.ts, a baseline committed on it, the pre-commit hook installed, then branch
# feat. <content> is the first version of a.ts.
staged_setup() {
  local content=$1
  shift
  mkrepo
  printf '%s\n' "$content" > a.ts
  rule todo paths='**/*.ts' "$@"
  staged_baseline
  must git add -A
  must git commit -q -m main
  staged_hook
  must git checkout -q -b feat
}

# staged_baseline: stage everything, then regenerate the baseline. A file only
# counts once it is in the index, so stage before measuring.
staged_baseline() {
  must git add -A
  run "$G" baseline
  assert_eq 0 "$STATUS" "baseline"
}

# staged_hook: install the pre-commit hook by hand, running this gauntlet's
# check --staged from the repo root.
staged_hook() {
  printf '#!/bin/sh\nexec "%s" check --staged\n' "$G" > .git/hooks/pre-commit || fail "cannot write hook"
  must chmod +x .git/hooks/pre-commit
}

# staged_committed_baseline: the baseline as HEAD carries it.
staged_committed_baseline() {
  git show "HEAD:.gauntlet/baseline.tsv"
}

test_staged_new_violation_blocks() {
  staged_setup 'ok'
  printf 'TODO fix\n' > a.ts
  must git add a.ts
  local before
  before=$(git rev-parse HEAD)
  run git commit -q -m "feat: add todo"
  assert_eq 1 "$STATUS" "commit status"
  assert_contains "$OUT" "[new]"
  assert_contains "$OUT" "a.ts:1  todo  TODO fix"
  assert_contains "$OUT" "fix: remove it"
  assert_eq "$before" "$(git rev-parse HEAD)" "HEAD after a blocked commit"
}

test_blocked_commit_keeps_head_and_message() {
  staged_setup 'ok'
  printf 'TODO fix\n' > a.ts
  must git add a.ts
  local before subject
  before=$(git rev-parse HEAD)
  subject=$(git log -1 --format=%s)
  run git commit -q -m "feat: blocked change"
  assert_eq 1 "$STATUS" "commit status"
  assert_eq "$before" "$(git rev-parse HEAD)" "HEAD"
  assert_eq "$subject" "$(git log -1 --format=%s)" "subject"
  assert_eq "a.ts" "$(git diff --cached --name-only)" "still staged, baseline not staged"
}

test_fix_lands_with_lower_baseline_same_commit() {
  staged_setup 'TODO here'
  printf 'ok\n' > a.ts
  must git add a.ts
  run git commit -q -m "fix: remove todo"
  assert_eq 0 "$STATUS" "commit status"
  assert_contains "$(git show --stat --format= HEAD)" ".gauntlet/baseline.tsv"
  assert_not_contains "$(staged_committed_baseline)" "a.ts"
  assert_eq "" "$(git status --short)" "clean tree"
}

test_commit_a_flag_also_tightens() {
  staged_setup 'TODO here'
  printf 'ok\n' > a.ts
  run git commit -q -a -m "fix: remove todo"
  assert_eq 0 "$STATUS" "commit status"
  assert_contains "$(git show --stat --format= HEAD)" ".gauntlet/baseline.tsv"
  assert_not_contains "$(staged_committed_baseline)" "a.ts"
  assert_eq "" "$(git status --short)" "clean tree"
}

test_partial_stage_skips_tighten() {
  staged_setup "$(printf 'TODO one\nTODO two')"
  printf 'TODO one\nok\n' > a.ts
  must git add a.ts
  printf 'ok\n' > a.ts
  run git commit -q -m "fix: partial"
  assert_eq 0 "$STATUS" "commit status"
  assert_contains "$OUT" "partially staged; run gauntlet baseline before pushing"
  assert_not_contains "$(git show --stat --format= HEAD)" ".gauntlet/baseline.tsv"
  assert_contains "$(staged_committed_baseline)" "TODO two"
  assert_eq " M a.ts" "$(git status --short)" "the unstaged change stays"
}

test_deleted_file_rows_removed() {
  mkrepo
  printf 'TODO here\n' > a.ts
  printf 'ok\n' > b.ts
  rule todo paths='**/*.ts'
  staged_baseline
  must git add -A
  must git commit -q -m main
  staged_hook
  must git checkout -q -b feat
  must git rm -q a.ts
  run git commit -q -m "chore: remove a.ts"
  assert_eq 0 "$STATUS" "commit status"
  assert_not_contains "$(staged_committed_baseline)" "a.ts"
  assert_eq "" "$(git status --short)" "clean tree"
}

test_unstaged_path_rows_kept() {
  mkrepo
  printf 'TODO here\n' > a.ts
  printf 'TODO there\n' > b.ts
  rule todo paths='**/*.ts'
  staged_baseline
  must git add -A
  must git commit -q -m main
  staged_hook
  must git checkout -q -b feat
  printf 'ok\n' > a.ts
  must git add a.ts
  run git commit -q -m "fix: a only"
  assert_eq 0 "$STATUS" "commit status"
  assert_not_contains "$(staged_committed_baseline)" "a.ts"
  assert_contains "$(staged_committed_baseline)" "b.ts"
}

test_push_stage_rules_not_run_at_commit() {
  mkrepo
  printf 'ok\n' > a.ts
  rule todo paths='**/*.ts'
  rule pushy paths='**/*.ts' stage=push detector="rg --with-filename --line-number --no-heading 'FIXME' {files}"
  staged_baseline
  must git add -A
  must git commit -q -m main
  staged_hook
  must git checkout -q -b feat
  printf 'FIXME x\n' > a.ts
  must git add a.ts
  run git commit -q -m "chore: push-only finding"
  assert_eq 0 "$STATUS" "commit status"
  assert_not_contains "$OUT" "pushy"
}

test_first_commit_passes_with_note() {
  must mkdir -p "$TMP/repo"
  must cd "$TMP/repo"
  must git init -q .
  must git symbolic-ref HEAD refs/heads/main
  must git config user.name "Test User"
  must git config user.email "test@example.com"
  must git config commit.gpgsign false
  must mkdir -p .gauntlet/rules
  must touch .gauntlet/config .gauntlet/baseline.tsv .gauntlet/exceptions.tsv
  printf 'TODO here\n' > a.ts
  rule todo paths='**/*.ts'
  must git add -A
  staged_hook
  run git commit -q -m "chore: first commit"
  assert_eq 0 "$STATUS" "commit status"
  assert_contains "$OUT" "no HEAD"
  must git rev-parse -q --verify HEAD > /dev/null
}

test_over_budget_warns_not_fails() {
  staged_setup 'ok'
  printf 'still ok\n' > a.ts
  must git add a.ts
  run env GAUNTLET_COMMIT_BUDGET_MS=1 git commit -q -m "chore: tweak"
  assert_eq 0 "$STATUS" "commit status"
  assert_contains "$OUT" "[slow] over the 5 s commit budget"
}

test_rename_drops_old_rows_adds_new() {
  staged_setup "$(printf 'alpha\nbeta\ngamma\ndelta\nTODO here')" severity=shadow
  must git mv a.ts b.ts
  must git add -A
  run git commit -q -m "refactor: rename a.ts"
  assert_eq 0 "$STATUS" "commit status"
  assert_not_contains "$(staged_committed_baseline)" "a.ts"
  assert_contains "$(staged_committed_baseline)" "b.ts"
}

test_rename_with_fix_drops_old_rows() {
  staged_setup "$(printf 'alpha\nbeta\ngamma\ndelta\nTODO here')"
  must git mv a.ts b.ts
  printf 'alpha\nbeta\ngamma\ndelta\nok\n' > b.ts
  must git add -A
  run git commit -q -m "refactor: rename and fix"
  assert_eq 0 "$STATUS" "commit status"
  assert_not_contains "$(staged_committed_baseline)" "a.ts"
  assert_eq "" "$(git status --short)" "clean tree"
}

test_path_with_space_tightens() {
  mkrepo
  mkdir -p "my dir"
  printf 'TODO here\n' > "my dir/ä b.ts"
  rule todo paths='**/*.ts'
  staged_baseline
  must git add -A
  must git commit -q -m main
  staged_hook
  must git checkout -q -b feat
  printf 'ok\n' > "my dir/ä b.ts"
  must git add -A
  run git commit -q -m "fix: spaced path"
  assert_eq 0 "$STATUS" "commit status"
  assert_not_contains "$(staged_committed_baseline)" "my dir"
  assert_eq "" "$(git status --short)" "clean tree"
}

test_shadow_rise_is_tightened() {
  staged_setup 'ok' severity=shadow
  printf 'TODO fix\n' > a.ts
  must git add a.ts
  run git commit -q -m "feat: shadow todo"
  assert_eq 0 "$STATUS" "commit status"
  assert_contains "$OUT" "[shadow] would have failed"
  assert_contains "$(staged_committed_baseline)" "TODO fix"
  assert_eq "" "$(git status --short)" "clean tree"
}

test_track_rise_reported_at_commit() {
  mkrepo
  printf 'ok\n' > a.ts
  rule todo paths='**/*.ts'
  rule xxx paths='**/*.ts' severity=track detector="rg --with-filename --line-number --no-heading 'XXX' {files}"
  staged_baseline
  must git add -A
  must git commit -q -m main
  staged_hook
  must git checkout -q -b feat
  printf 'XXX y\n' > a.ts
  must git add a.ts
  run git commit -q -m "feat: track todo"
  assert_eq 0 "$STATUS" "commit status"
  assert_contains "$OUT" "consider promoting"
  assert_contains "$(staged_committed_baseline)" "XXX y"
}

test_waived_new_violation_passes() {
  staged_setup 'ok'
  must "$G" waive a.ts "accepted for the spike"
  must git add .gauntlet/exceptions.tsv
  printf 'TODO fix\n' > a.ts
  must git add a.ts
  run git commit -q -m "feat: waived todo"
  assert_eq 0 "$STATUS" "commit status"
  assert_not_contains "$OUT" "[new]"
}

test_touched_gate_blocks_at_commit() {
  staged_setup 'TODO here'
  printf 'touched=on\n' > .gauntlet/config
  printf 'TODO here\nok\n' > a.ts
  must git add .gauntlet/config a.ts
  run git commit -q -m "feat: touched without progress"
  assert_eq 1 "$STATUS" "commit status"
  assert_contains "$OUT" "[touched]"
  assert_contains "$OUT" "  a.ts  1 → 1  (must go down)"
  assert_contains "$OUT" "FAIL (1 problems)"
}

test_new_rule_exempt_at_commit_rows_added() {
  staged_setup 'ok'
  rule fixme paths='**/*.ts' detector="rg --with-filename --line-number --no-heading 'FIXME' {files}"
  printf 'FIXME x\n' > a.ts
  must git add -A
  run git commit -q -m "feat: new rule"
  assert_eq 0 "$STATUS" "commit status"
  assert_contains "$(staged_committed_baseline)" "fixme"
}

test_detached_head_checks_without_waivers() {
  staged_setup 'ok'
  must git checkout -q --detach
  printf 'TODO fix\n' > a.ts
  must git add a.ts
  run git commit -q -m "feat: detached"
  assert_eq 1 "$STATUS" "commit status"
  assert_contains "$OUT" "[new]"
}

test_nothing_staged_passes() {
  staged_setup 'ok'
  run "$G" check --staged
  assert_eq 0 "$STATUS" "status"
  assert_contains "$OUT" "gauntlet: ok"
}

test_bad_stage_exits_2() {
  mkrepo
  printf 'ok\n' > a.ts
  rule todo paths='**/*.ts' stage=sometimes
  must git add -A
  run "$G" check --staged
  assert_eq 2 "$STATUS" "status"
  assert_contains "$OUT" "bad stage [sometimes]"
}

test_bad_budget_exits_2() {
  mkrepo
  printf 'ok\n' > a.ts
  rule todo paths='**/*.ts'
  must git add -A
  run env GAUNTLET_COMMIT_BUDGET_MS=soon "$G" check --staged
  assert_eq 2 "$STATUS" "status"
  assert_contains "$OUT" "whole number of milliseconds"
}

test_check_staged_rejects_extra_arguments() {
  mkrepo
  run "$G" check --staged extra
  assert_eq 2 "$STATUS" "status"
  assert_contains "$OUT" "usage: gauntlet check --staged"
}
