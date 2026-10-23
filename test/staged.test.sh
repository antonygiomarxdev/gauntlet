# shellcheck shell=bash
# shellcheck disable=SC2153 # ROOT, G and STATUS are set by test/lib.sh
# Tests for check --staged, the commit gate run from pre-commit: new violations
# block, a commit carries the baseline it measures, partial staging and unstaged
# baseline edits skip auto-tighten, push-stage rules do not run, and the budget
# only warns. Each commit test installs the pre-commit hook by hand and runs a
# real git commit.

# staged_setup <content> [rule options...]: a main branch with one todo rule over
# **/*.ts, a baseline committed on it, the pre-commit hook installed, then branch
# feat. <content> is the first version of a.ts.
staged_setup() {
  local content=$1
  shift
  mkrepo
  printf '%s\n' "$content" > a.ts
  rule todo paths='**/*.ts' "$@"
  cases_of todo 'TODO x'
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

# staged_assert_exact [rule-regex]: on a clean tree, a fresh measure matches the
# committed baseline, whole file or only the rules the regex names. The commit gate
# never measures push-stage rules, so fixtures that have one compare commit rows only.
staged_assert_exact() {
  assert_eq "" "$(git status --short)" "clean tree"
  run "$G" baseline
  assert_eq 0 "$STATUS" "fresh baseline"
  if [ "$#" -eq 0 ]; then
    run git diff --exit-code -- .gauntlet/baseline.tsv
    assert_eq 0 "$STATUS" "committed baseline equals a fresh measure"
    return 0
  fi
  local want got
  want=$(grep -E "^($1)"$'\t' .gauntlet/baseline.tsv || true)
  got=$(staged_committed_baseline | grep -E "^($1)"$'\t' || true)
  assert_eq "$want" "$got" "commit-stage rows equal a fresh measure"
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
  assert_eq "M  a.ts" "$(git status --short)" "only the change is staged; the baseline is untouched"
}

test_fix_lands_with_lower_baseline_same_commit() {
  staged_setup 'TODO here'
  printf 'ok\n' > a.ts
  must git add a.ts
  run git commit -q -m "fix: remove todo"
  assert_eq 0 "$STATUS" "commit status"
  assert_contains "$(git show --stat --format= HEAD)" ".gauntlet/baseline.tsv"
  assert_not_contains "$(staged_committed_baseline)" "a.ts"
  staged_assert_exact
}

test_commit_a_flag_also_tightens() {
  staged_setup 'TODO here'
  printf 'ok\n' > a.ts
  run git commit -q -a -m "fix: remove todo"
  assert_eq 0 "$STATUS" "commit status"
  assert_contains "$(git show --stat --format= HEAD)" ".gauntlet/baseline.tsv"
  assert_not_contains "$(staged_committed_baseline)" "a.ts"
  staged_assert_exact
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

test_partial_notice_printed_on_failure() {
  staged_setup 'TODO here'
  printf 'TODO here\nok\n' > a.ts
  must git add a.ts
  printf 'TODO here\nTODO fix\n' > a.ts
  run git commit -q -m "feat: blocked partial"
  assert_eq 1 "$STATUS" "commit status"
  assert_contains "$OUT" "[new]"
  assert_contains "$OUT" "partially staged; run gauntlet baseline before pushing"
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
  staged_assert_exact
}

test_commit_a_removes_deleted_file_and_tightens() {
  staged_setup 'TODO here'
  rm -f a.ts
  run git commit -q -a -m "chore: delete a.ts"
  assert_eq 0 "$STATUS" "commit status"
  assert_not_contains "$OUT" "partially staged"
  assert_not_contains "$OUT" "broken detector"
  assert_not_contains "$(staged_committed_baseline)" "a.ts"
  staged_assert_exact
}

test_staged_then_deleted_file_does_not_fail() {
  staged_setup 'ok'
  printf 'ok\n' > n.ts
  must git add n.ts
  rm -f n.ts
  run git commit -q -m "chore: staged then deleted"
  assert_eq 0 "$STATUS" "commit status"
  assert_not_contains "$OUT" "broken detector"
  assert_contains "$OUT" "partially staged"
}

test_modified_then_deleted_file_does_not_fail() {
  staged_setup 'TODO here'
  printf 'TODO here\nok\n' > a.ts
  must git add a.ts
  rm -f a.ts
  run git commit -q -m "chore: modified then deleted"
  assert_eq 0 "$STATUS" "commit status"
  assert_not_contains "$OUT" "broken detector"
  assert_contains "$OUT" "partially staged"
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
  staged_assert_exact
}

test_measure_sees_only_staged_paths() {
  mkrepo
  printf 'ok\n' > a.ts
  printf 'ok\n' > b.ts
  cat > seen.sh <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >> .git/seen.log
exec rg --with-filename --line-number --no-heading TODO "$@"
EOF
  rule seen paths='**/*.ts' severity=shadow detector='sh ./seen.sh {files}'
  staged_baseline
  must git add -A
  must git commit -q -m main
  staged_hook
  must git checkout -q -b feat
  rm -f .git/seen.log
  printf 'TODO a\n' > a.ts
  must git add a.ts
  printf 'TODO b\n' > b.ts
  run git commit -q -m "feat: a only"
  assert_eq 0 "$STATUS" "commit status"
  assert_contains "$(cat .git/seen.log)" "a.ts"
  assert_not_contains "$(cat .git/seen.log)" "b.ts"
}

test_whole_program_rows_not_appended() {
  mkrepo
  printf 'ok\n' > a.ts
  printf 'ok\n' > b.ts
  rule whole paths='**/*.ts' severity=shadow detector="rg --with-filename --line-number --no-heading 'TODO' ."
  staged_baseline
  must git add -A
  must git commit -q -m main
  staged_hook
  must git checkout -q -b feat
  printf 'TODO a\n' > a.ts
  must git add a.ts
  printf 'TODO b\n' > b.ts
  run git commit -q -m "feat: first"
  assert_eq 0 "$STATUS" "first commit status"
  printf 'TODO a2\n' > a.ts
  must git add a.ts
  run git commit -q -m "feat: second"
  assert_eq 0 "$STATUS" "second commit status"
  assert_eq $'whole\ta.ts\tTODO a2\t1' "$(staged_committed_baseline)"
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
  staged_assert_exact todo
}

test_new_rule_baseline_survives_hook() {
  staged_setup 'ok'
  rule fixme paths='**/*.ts' detector="rg --with-filename --line-number --no-heading 'FIXME' {files}"
  cases_of fixme 'FIXME x'
  printf 'FIXME x\n' > a.ts
  must git add .gauntlet/rules/fixme.md .gauntlet/rules/fixme.bad.txt .gauntlet/rules/fixme.good.txt a.ts
  run "$G" baseline
  assert_eq 0 "$STATUS" "regenerate"
  run git commit -q -m "feat: add fixme rule"
  assert_eq 0 "$STATUS" "commit status"
  assert_contains "$OUT" "baseline.tsv has unstaged changes"
  assert_contains "$(cat .gauntlet/baseline.tsv)" "fixme"
  must git add .gauntlet/baseline.tsv
  run git commit -q -m "chore: regenerate baseline"
  assert_eq 0 "$STATUS" "advised commit status"
  assert_contains "$(staged_committed_baseline)" $'fixme\ta.ts\tFIXME x\t1'
  run "$G" check --ci --base main
  assert_eq 0 "$STATUS" "check --ci"
  assert_contains "$OUT" "gauntlet: ok"
}

test_regenerated_baseline_staged_with_commit_is_kept() {
  staged_setup 'ok'
  rule fixme paths='**/*.ts' detector="rg --with-filename --line-number --no-heading 'FIXME' {files}"
  cases_of fixme 'FIXME x'
  printf 'FIXME x\n' > a.ts
  must git add -A
  run "$G" baseline
  assert_eq 0 "$STATUS" "regenerate"
  must git add -A
  run git commit -q -m "feat: add fixme rule"
  assert_eq 0 "$STATUS" "commit status"
  assert_contains "$(staged_committed_baseline)" $'fixme\ta.ts\tFIXME x\t1'
  staged_assert_exact
}

test_push_rule_baseline_survives_hook() {
  staged_setup 'ok'
  rule pushy paths='**/*.ts' stage=push detector="rg --with-filename --line-number --no-heading 'FIXME' {files}"
  cases_of pushy 'FIXME x'
  printf 'FIXME x\n' > a.ts
  must git add .gauntlet/rules/pushy.md .gauntlet/rules/pushy.bad.txt .gauntlet/rules/pushy.good.txt a.ts
  run "$G" baseline
  assert_eq 0 "$STATUS" "regenerate"
  run git commit -q -m "feat: push-only rule"
  assert_eq 0 "$STATUS" "commit status"
  assert_contains "$OUT" "baseline.tsv has unstaged changes"
  assert_contains "$(cat .gauntlet/baseline.tsv)" "pushy"
  must git add .gauntlet/baseline.tsv
  run git commit -q -m "chore: regenerate baseline"
  assert_eq 0 "$STATUS" "advised commit status"
  assert_contains "$(staged_committed_baseline)" $'pushy\ta.ts\tFIXME x\t1'
  run "$G" check --ci --base main
  assert_eq 0 "$STATUS" "check --ci"
  assert_contains "$OUT" "gauntlet: ok"
}

test_empty_commit_leaves_unstaged_baseline() {
  staged_setup 'TODO here'
  printf 'TODO here\nTODO two\n' > a.ts
  run "$G" baseline
  assert_eq 0 "$STATUS" "regenerate"
  must cp .gauntlet/baseline.tsv "$TMP/regen.tsv"
  local head_before
  head_before=$(git show HEAD:.gauntlet/baseline.tsv)
  run git commit -q --allow-empty -m "chore: empty commit"
  assert_eq 0 "$STATUS" "commit status"
  assert_contains "$OUT" "baseline.tsv has unstaged changes"
  assert_not_contains "$OUT" "baseline updated"
  must cmp -s .gauntlet/baseline.tsv "$TMP/regen.tsv"
  assert_eq "$head_before" "$(git show HEAD:.gauntlet/baseline.tsv)" "HEAD baseline unchanged"
}

test_partial_commit_by_path_skips_tighten() {
  mkrepo
  printf 'TODO here\n' > a.ts
  printf 'ok\n' > c.ts
  rule todo paths='**/*.ts'
  staged_baseline
  must git add -A
  must git commit -q -m main
  staged_hook
  must git checkout -q -b feat
  printf 'ok\n' > a.ts
  printf 'ok two\n' > c.ts
  run git commit -q -m "fix: c only" c.ts
  assert_eq 0 "$STATUS" "commit status"
  assert_contains "$OUT" "partial commit by path; run gauntlet baseline before pushing"
  assert_contains "$(staged_committed_baseline)" "a.ts"
  assert_eq " M a.ts" "$(git status --short)" "no baseline change is left behind"
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

test_no_baseline_at_head_skips_checks() {
  mkrepo
  rule todo paths='**/*.ts'
  must git add -A
  must git commit -q -m "rules"
  must git rm -q .gauntlet/baseline.tsv
  must git commit -q -m "drop baseline"
  staged_hook
  must git checkout -q -b feat
  printf 'TODO fix\n' > a.ts
  must git add a.ts
  run git commit -q -m "feat: change without a baseline at HEAD"
  assert_eq 0 "$STATUS" "commit status"
  assert_contains "$OUT" "no baseline at HEAD"
  assert_not_contains "$(git show --stat --format= HEAD)" "baseline.tsv"
}

test_over_budget_warns_not_fails() {
  mkrepo
  printf 'ok\n' > a.ts
  # The commit must take a second: a seconds clock (BSD date) reads less as 0 ms.
  rule slow "detector=sh -c 'sleep 1' {files}"
  must git add -A
  must git commit -q -m main
  staged_hook
  printf 'still ok\n' > a.ts
  must git add a.ts
  run env GAUNTLET_COMMIT_BUDGET_MS=1 git commit -q -m "chore: tweak"
  assert_eq 0 "$STATUS" "commit status"
  assert_contains "$OUT" "[slow] over the 1 ms commit budget"
}

test_normal_run_is_not_slow() {
  staged_setup 'ok'
  printf 'ok two\n' > a.ts
  must git add a.ts
  run git commit -q -m "chore: normal"
  assert_eq 0 "$STATUS" "commit status"
  assert_not_contains "$OUT" "[slow]"
}

test_huge_budget_is_quiet() {
  staged_setup 'ok'
  printf 'ok two\n' > a.ts
  must git add a.ts
  run env GAUNTLET_COMMIT_BUDGET_MS=99999999999999999999 git commit -q -m "chore: huge budget"
  assert_eq 0 "$STATUS" "commit status"
  assert_not_contains "$OUT" "integer expression"
  assert_not_contains "$OUT" "[slow]"
}

test_rename_drops_old_rows_adds_new() {
  staged_setup "$(printf 'alpha\nbeta\ngamma\ndelta\nTODO here')" severity=shadow
  must git mv a.ts b.ts
  must git add -A
  run git commit -q -m "refactor: rename a.ts"
  assert_eq 0 "$STATUS" "commit status"
  assert_not_contains "$(staged_committed_baseline)" "a.ts"
  assert_contains "$(staged_committed_baseline)" "b.ts"
  staged_assert_exact
}

test_rename_with_fix_drops_old_rows() {
  staged_setup "$(printf 'alpha\nbeta\ngamma\ndelta\nTODO here')"
  must git mv a.ts b.ts
  printf 'alpha\nbeta\ngamma\ndelta\nok\n' > b.ts
  must git add -A
  run git commit -q -m "refactor: rename and fix"
  assert_eq 0 "$STATUS" "commit status"
  assert_not_contains "$(staged_committed_baseline)" "a.ts"
  staged_assert_exact
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
  staged_assert_exact
}

test_mixed_case_paths_sort_in_c_locale() {
  if ! locale -a 2>/dev/null | grep -qiE '^en_US\.utf-?8$'; then
    skip "en_US.UTF-8 is not installed; the locale check did not run"
    return 77
  fi
  mkrepo
  printf 'TODO a\nTODO a2\n' > a.ts
  printf 'TODO B\n' > B.ts
  rule todo paths='**/*.ts'
  staged_baseline
  must git add -A
  must git commit -q -m main
  staged_hook
  must git checkout -q -b feat
  printf 'TODO a\nok\n' > a.ts
  must git add a.ts
  run env LC_ALL=en_US.UTF-8 git commit -q -m "feat: drop a2"
  assert_eq 0 "$STATUS" "commit status"
  assert_eq "$(printf 'todo\tB.ts\tTODO B\t1\ntodo\ta.ts\tTODO a\t1')" "$(staged_committed_baseline)" \
    "rows in C order, as baseline writes them"
  staged_assert_exact
}

test_track_partial_totals_at_commit() {
  mkrepo
  printf 'XXX a\n' > a.ts
  printf 'XXX b\n' > b.ts
  rule xxx paths='**/*.ts' severity=track detector="rg --with-filename --line-number --no-heading 'XXX' {files}"
  staged_baseline
  must git add -A
  must git commit -q -m main
  staged_hook
  must git checkout -q -b feat
  printf 'XXX a\nXXX a2\n' > a.ts
  must git add a.ts
  printf 'XXX b\nXXX b2\n' > b.ts
  run git commit -q -m "feat: a2"
  assert_eq 0 "$STATUS" "commit status"
  assert_contains "$OUT" "  xxx  2 → 3 (+1); consider promoting"
  assert_eq "$(printf 'xxx\ta.ts\tXXX a\t1\nxxx\ta.ts\tXXX a2\t1\nxxx\tb.ts\tXXX b\t1')" \
    "$(staged_committed_baseline)" "committed rows: staged a.ts, index b.ts"
}

test_shadow_rise_is_tightened() {
  staged_setup 'ok' severity=shadow
  printf 'TODO fix\n' > a.ts
  must git add a.ts
  run git commit -q -m "feat: shadow todo"
  assert_eq 0 "$STATUS" "commit status"
  assert_contains "$OUT" "[shadow] would have failed"
  assert_contains "$(staged_committed_baseline)" "TODO fix"
  staged_assert_exact
}

test_unchanged_baseline_prints_no_update() {
  staged_setup 'TODO here'
  printf 'TODO here\nok\n' > a.ts
  must git add a.ts
  run git commit -q -m "chore: same debt"
  assert_eq 0 "$STATUS" "commit status"
  assert_not_contains "$OUT" "baseline updated"
  staged_assert_exact
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
  staged_assert_exact
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

test_one_name_status_call_per_run() {
  staged_setup 'TODO here'
  run env GIT_TRACE="$TMP/trace.off" "$G" check --ci --base main
  assert_eq 0 "$STATUS" "check --ci status with touched=off"
  assert_eq 1 "$(grep -c 'name-status' "$TMP/trace.off")" "one diff call with touched=off"
  printf 'touched=on\n' > .gauntlet/config
  must git add .gauntlet/config
  must git commit -q -m "chore: touched on"
  run env GIT_TRACE="$TMP/trace.on" "$G" check --ci --base main
  assert_eq 1 "$(grep -c 'name-status' "$TMP/trace.on")" "one diff call with touched=on"
  printf 'ok\n' > a.ts
  must git add a.ts
  run env GIT_TRACE="$TMP/trace.staged" "$G" check --staged
  assert_eq 0 "$STATUS" "check --staged status"
  assert_eq 1 "$(grep -c 'name-status' "$TMP/trace.staged")" "one diff call at commit"
}

test_new_rule_exempt_at_commit_rows_added() {
  staged_setup 'ok'
  rule fixme paths='**/*.ts' detector="rg --with-filename --line-number --no-heading 'FIXME' {files}"
  printf 'FIXME x\n' > a.ts
  must git add -A
  run git commit -q -m "feat: new rule"
  assert_eq 0 "$STATUS" "commit status"
  assert_contains "$(staged_committed_baseline)" "fixme"
  staged_assert_exact
}

test_detached_head_checks_without_waivers() {
  staged_setup 'ok'
  printf 'waive\ta.ts\taccepted\t2026-10-22\tHEAD\n' >> .gauntlet/exceptions.tsv
  must git add .gauntlet/exceptions.tsv
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
  assert_contains "$OUT" "rule todo: stage must be commit or push, got [sometimes]; run gauntlet doctor"
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

test_pure_rename_of_debt_commits_moved_rows() {
  staged_setup 'TODO here'
  must git mv a.ts b.ts
  run git commit -q -m "refactor: rename a.ts"
  assert_eq 0 "$STATUS" "commit status"
  assert_not_contains "$OUT" "[new]"
  assert_eq $'todo\tb.ts\tTODO here\t1' "$(staged_committed_baseline)" "old rows gone, new path's rows in"
  staged_assert_exact
}

test_rename_with_unchanged_debt_line_commits() {
  staged_setup "$(printf 'alpha\nbeta\ngamma\nTODO here')"
  must git mv a.ts b.ts
  printf 'alpha\nbeta\ngamma\nTODO here\nnew line\n' > b.ts
  must git add -A
  run git commit -q -m "refactor: rename and edit"
  assert_eq 0 "$STATUS" "commit status"
  assert_not_contains "$OUT" "[new]"
  assert_eq $'todo\tb.ts\tTODO here\t1' "$(staged_committed_baseline)"
  staged_assert_exact
}

test_rename_with_changed_debt_line_is_new_at_commit() {
  staged_setup "$(printf 'alpha\nbeta\ngamma\nTODO here')"
  must git mv a.ts b.ts
  printf 'alpha\nbeta\ngamma\nTODO changed\n' > b.ts
  must git add -A
  run git commit -q -m "refactor: rename and change the debt"
  assert_eq 1 "$STATUS" "commit status"
  assert_contains "$OUT" "  b.ts:4  todo  TODO changed"
}

test_rename_of_path_with_space_commits() {
  mkrepo
  mkdir -p "my dir"
  printf 'TODO here\n' > "my dir/a b.ts"
  rule todo paths='**/*.ts'
  staged_baseline
  must git add -A
  must git commit -q -m main
  staged_hook
  must git checkout -q -b feat
  must git mv "my dir/a b.ts" "my dir/c d.ts"
  run git commit -q -m "refactor: rename spaced path"
  assert_eq 0 "$STATUS" "commit status"
  assert_not_contains "$OUT" "[new]"
  assert_eq $'todo\tmy dir/c d.ts\tTODO here\t1' "$(staged_committed_baseline)"
  staged_assert_exact
}

test_copy_of_debt_file_is_new_at_commit() {
  staged_setup 'TODO here'
  cp a.ts c.ts
  must git add c.ts
  run git commit -q -m "feat: copy a.ts"
  assert_eq 1 "$STATUS" "commit status"
  assert_contains "$OUT" "  c.ts:1  todo  TODO here"
}

test_two_renames_in_one_commit_commit() {
  mkrepo
  printf 'TODO one\n' > a.ts
  printf 'TODO two\n' > c.ts
  rule todo paths='**/*.ts'
  staged_baseline
  must git add -A
  must git commit -q -m main
  staged_hook
  must git checkout -q -b feat
  must git mv a.ts b.ts
  must git mv c.ts d.ts
  run git commit -q -m "refactor: two renames"
  assert_eq 0 "$STATUS" "commit status"
  assert_not_contains "$OUT" "[new]"
  assert_eq "$(printf 'todo\tb.ts\tTODO one\t1\ntodo\td.ts\tTODO two\t1')" "$(staged_committed_baseline)"
  staged_assert_exact
}

# The [slow] line names the budget that was set: 5 s for the default, else the
# milliseconds. A line that always said 5 s was wrong under GAUNTLET_COMMIT_BUDGET_MS.
test_budget_label_names_the_real_budget() {
  # shellcheck source=lib/core.sh
  . "$ROOT/lib/core.sh"
  # shellcheck source=lib/check.sh
  . "$ROOT/lib/check.sh"
  assert_eq "5 s" "$(budget_label 5000)" "the default"
  assert_eq "1 ms" "$(budget_label 1)" "a short budget"
  assert_eq "5001 ms" "$(budget_label 5001)" "a neighbour of the default"
  assert_eq "300 ms" "$(budget_label 300)" "a budget below a second"
}

# The real thing the variables come from: git sets them for the hook of
# `git --glob-pathspecs commit`.
test_commit_with_a_pathspec_switch_runs_the_gate() {
  staged_setup 'ok'
  printf 'fine\n' > b.ts
  must git add b.ts
  run git --glob-pathspecs commit -q -m "feat: b under --glob-pathspecs"
  assert_eq 0 "$STATUS" "commit under --glob-pathspecs: $OUT"
  printf 'TODO x\n' > c.ts
  must git add c.ts
  run git --icase-pathspecs commit -q -m "feat: c under --icase-pathspecs"
  assert_eq 1 "$STATUS" "a violation still blocks under --icase-pathspecs: $OUT"
  assert_contains "$OUT" "c.ts:1  todo  TODO x"
}
