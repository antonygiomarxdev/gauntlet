# shellcheck shell=bash
# shellcheck disable=SC2153 # ROOT, G and STATUS are set by test/lib.sh
# Tests for human-only exceptions: the waive, loosen and remove commands, the
# waiver filter in check --ci, and the no-loosening check. Helpers are prefixed
# exc_ because run.sh sources every group into one shell.

# exc_commit <msg>: stage and commit everything, untracked files included.
exc_commit() {
  must git add -A
  must git commit -q -m "$1"
}

# exc_setup <a.ts content> [rule options...]: main with one todo rule over
# **/*.ts and a committed baseline, then a feat branch.
exc_setup() {
  local content=$1
  shift
  mkrepo
  printf '%s\n' "$content" > a.ts
  rule todo paths='**/*.ts' "$@"
  # Both words: the bad case is flagged by the todo and the fixme detector, so
  # a test that swaps the detector still has its case passing.
  cases_of todo 'TODO FIXME x'
  exc_rebase
  assert_eq 0 "$STATUS" "main baseline"
  exc_commit main
  must git checkout -q -b feat
}

# exc_rebase: stage everything, then regenerate the baseline.
exc_rebase() {
  must git add -A
  run "$G" baseline
}

# exc_gate: run check --ci against main; result in $OUT and $STATUS. These tests
# are about [loosened] alone, so their rules must pass their cases: a
# [rule-tests] section here is a test fixture gap, never the thing under test.
exc_gate() {
  run "$G" check --ci --base main
  assert_not_contains "$OUT" "[rule-tests]"
}

test_waive_exempts_new_on_branch() {
  exc_setup 'ok'
  printf 'TODO fix\n' > a.ts
  run "$G" waive a.ts "rewrite scheduled"
  assert_eq 0 "$STATUS" "waive status"
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 1 "$STATUS" "status"
  assert_not_contains "$OUT" "[new]"
  assert_contains "$OUT" "[global]"
  assert_contains "$OUT" "FAIL (1 problems)"
}

test_waived_global_rise_counts_once() {
  exc_setup 'ok'
  printf 'TODO 1\nTODO 2\n' > a.ts
  run "$G" waive a.ts "rewrite scheduled"
  assert_eq 0 "$STATUS" "waive status"
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "[global]"
  assert_contains "$OUT" "todo  0 → 2"
  assert_contains "$OUT" "FAIL (1 problems)"
}

test_waive_other_branch_ignored() {
  exc_setup 'ok'
  printf 'type\ttarget\treason\tdate\tbranch\nwaive\ta.ts\told\t2026-10-22\tg\n' > .gauntlet/exceptions.tsv
  exc_commit other-branch-row
  printf 'TODO fix\n' > a.ts
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "[new]"
  assert_contains "$OUT" "a.ts:1"
}

test_waive_detached_ci() {
  exc_setup 'ok'
  printf 'TODO fix\n' > a.ts
  run "$G" waive a.ts "rewrite scheduled"
  assert_eq 0 "$STATUS" "waive status"
  exc_rebase
  exc_commit feat
  must git checkout -q --detach
  export GITHUB_HEAD_REF=feat
  exc_gate
  assert_not_contains "$OUT" "[new]"
  unset GITHUB_HEAD_REF
  exc_gate
  assert_contains "$OUT" "[new]"
}

test_waive_path_with_space() {
  exc_setup 'ok'
  mkdir -p "my dir"
  printf 'TODO fix\n' > "my dir/ä b.ts"
  run "$G" waive "my dir/ä b.ts" "rewrite scheduled"
  assert_eq 0 "$STATUS" "waive status"
  exc_rebase
  exc_commit feat
  exc_gate
  assert_not_contains "$OUT" "[new]"
  assert_contains "$(cat .gauntlet/exceptions.tsv)" "my dir/ä b.ts"
}

test_waive_exempts_touched_path() {
  exc_setup 'TODO here'
  touched_on_exc
  printf 'TODO here\nok\n' > a.ts
  run "$G" waive a.ts "rewrite scheduled"
  assert_eq 0 "$STATUS" "waive status"
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 0 "$STATUS" "status"
  assert_not_contains "$OUT" "[touched]"
}

# touched_on_exc: turn the touched gate on for the branch under test.
touched_on_exc() {
  printf 'touched=on\n' > .gauntlet/config
}

test_waive_missing_path_rejected() {
  exc_setup 'ok'
  run "$G" waive nope.ts "reason"
  assert_eq 2 "$STATUS" "status"
  assert_contains "$OUT" "not a path in git or the working tree: nope.ts"
  assert_eq "" "$(cat .gauntlet/exceptions.tsv)" "exceptions file"
}

test_exception_rows_are_written() {
  exc_setup 'ok'
  rm -f .gauntlet/exceptions.tsv
  run "$G" waive a.ts "rewrite scheduled"
  assert_eq 0 "$STATUS" "waive status"
  run "$G" loosen todo "severity to shadow" "generated code"
  assert_eq 0 "$STATUS" "loosen status"
  run "$G" remove todo "rule retired"
  assert_eq 0 "$STATUS" "remove status"
  today=$(date +%Y-%m-%d)
  header=$(printf 'type\ttarget\treason\tdate\tbranch')
  expected=$(printf '%s\nwaive\ta.ts\trewrite scheduled\t%s\tfeat\nloosen\ttodo: severity to shadow\tgenerated code\t%s\t-\nremove\ttodo\trule retired\t%s\t-' \
    "$header" "$today" "$today" "$today")
  assert_eq "$expected" "$(cat .gauntlet/exceptions.tsv)" "rows"
}

test_empty_reason_rejected() {
  exc_setup 'ok'
  run "$G" waive a.ts ""
  assert_eq 2 "$STATUS" "waive status"
  run "$G" loosen todo "what" ""
  assert_eq 2 "$STATUS" "loosen status"
  run "$G" remove todo ""
  assert_eq 2 "$STATUS" "remove status"
  assert_eq "" "$(cat .gauntlet/exceptions.tsv)" "exceptions file"
}

test_tab_or_newline_in_text_rejected() {
  exc_setup 'ok'
  run "$G" waive a.ts "$(printf 'a\tb')"
  assert_eq 2 "$STATUS" "waive tab status"
  run "$G" loosen todo "$(printf 'x\ny')" "reason"
  assert_eq 2 "$STATUS" "loosen newline status"
  run "$G" remove todo "$(printf 'a\tb')"
  assert_eq 2 "$STATUS" "remove tab status"
  assert_eq "" "$(cat .gauntlet/exceptions.tsv)" "exceptions file"
}

test_trailer_not_a_waiver() {
  exc_setup 'ok'
  printf 'TODO fix\n' > a.ts
  exc_rebase
  must git add -A
  must git commit -q -m "$(printf 'feat\n\nStandards-waiver: a.ts — x')"
  exc_gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "[new]"
  assert_contains "$OUT" "a.ts:1"
}

test_lower_severity_fails_without_row() {
  exc_setup 'ok'
  rule todo paths='**/*.ts' severity=shadow
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "[loosened]"
  assert_contains "$OUT" "  todo  severity block → shadow"
  assert_contains "$OUT" "FAIL (1 problems)"
}

test_lower_severity_passes_with_new_row() {
  exc_setup 'ok'
  rule todo paths='**/*.ts' severity=shadow
  run "$G" loosen todo "severity to shadow" "generated code"
  assert_eq 0 "$STATUS" "loosen status"
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 0 "$STATUS" "status"
  assert_not_contains "$OUT" "[loosened]"
}

test_old_loosen_row_does_not_cover_new_loosening() {
  exc_setup 'ok'
  must git checkout -q main
  run "$G" loosen todo "earlier change" "reason"
  assert_eq 0 "$STATUS" "loosen status"
  exc_rebase
  exc_commit main-row
  must git checkout -q -b feat2
  rule todo paths='**/*.ts' severity=shadow
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "  todo  severity block → shadow"
}

test_widen_paths_is_not_loosening() {
  mkrepo
  mkdir -p src
  printf 'ok\n' > src/a.ts
  rule todo paths='src/**'
  cases_of todo 'TODO FIXME x'
  exc_rebase
  exc_commit main
  must git checkout -q -b feat
  rule todo paths='src/** lib/**'
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 0 "$STATUS" "status"
  assert_not_contains "$OUT" "[loosened]"
}

test_format_change_is_loosening() {
  mkrepo
  printf 'ok\n' > a.ts
  rule todo paths='**/*.ts'
  rule fixme paths='**/*.ts' detector="rg --with-filename --line-number --no-heading 'FIXME' {files}"
  cases_of todo 'TODO FIXME x'
  cases_of fixme 'TODO FIXME x'
  exc_rebase
  exc_commit main
  must git checkout -q -b feat
  mkdir -p .gauntlet/formats
  # The built-in format, as a project file: it has samples, so the format
  # tests pass and only the loosening is under test.
  cp "$ROOT/lib/formats/path-line.md" .gauntlet/formats/path-line.md
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "  todo  format file .gauntlet/formats/path-line.md added"
  assert_contains "$OUT" "  fixme  format file .gauntlet/formats/path-line.md added"
}

test_default_format_written_out_is_not_a_change() {
  exc_setup 'ok'
  rule todo paths='**/*.ts' format=path-line
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 0 "$STATUS" "status"
  assert_not_contains "$OUT" "[loosened]"
}

test_new_rule_never_loosened() {
  exc_setup 'ok'
  rule fixme paths='**/*.ts' severity=track detector="rg --with-filename --line-number --no-heading 'FIXME' {files}"
  cases_of fixme 'FIXME x'
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 0 "$STATUS" "status"
  assert_not_contains "$OUT" "[loosened]"
}

test_remove_rule_needs_remove_row() {
  exc_setup 'ok'
  must git rm -q .gauntlet/rules/todo.md
  exc_rebase
  exc_commit drop-rule
  exc_gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "  todo  rule file removed"
  run "$G" remove todo "rule retired"
  assert_eq 0 "$STATUS" "remove status"
  exc_rebase
  exc_commit remove-row
  exc_gate
  assert_eq 0 "$STATUS" "status with remove row"
  assert_not_contains "$OUT" "[loosened]"
}

test_loosen_runs_on_onboarding_branch() {
  mkrepo
  printf 'ok\n' > a.ts
  rule todo paths='**/*.ts'
  cases_of todo 'TODO x'
  must git rm -q .gauntlet/baseline.tsv
  exc_commit main-no-baseline
  must git checkout -q -b feat
  rule todo paths='**/*.ts' severity=shadow
  exc_commit feat
  exc_gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "no baseline at base"
  assert_contains "$OUT" "  todo  severity block → shadow"
}

test_detector_file_change_is_loosening() {
  mkrepo
  mkdir -p tools
  printf '#!/bin/sh\nrg --with-filename --line-number --no-heading TODO "$@"\n' > tools/find.sh
  chmod +x tools/find.sh
  printf 'ok\n' > a.ts
  rule todo paths='**/*.ts' engine=script detector=tools/find.sh
  exc_rebase
  exc_commit main
  must git checkout -q -b feat
  printf '#!/bin/sh\nrg --with-filename --line-number --no-heading "TO" "$@" | rg -v "x"\n' > tools/find.sh
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "  todo  detector file tools/find.sh changed"
}

test_narrow_paths_and_widen_exclude_are_loosening() {
  mkrepo
  mkdir -p src lib
  printf 'ok\n' > src/a.ts
  rule todo paths='src/** lib/**'
  cases_of todo 'TODO FIXME x'
  exc_rebase
  exc_commit main
  must git checkout -q -b feat
  rule todo paths='src/**' exclude='src/gen/**'
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "  todo  paths narrowed: lib/**"
  assert_contains "$OUT" "  todo  exclude widened: src/gen/**"
  assert_contains "$OUT" "FAIL (2 problems)"
}

test_engine_and_detector_change_are_loosening() {
  exc_setup 'ok'
  rule todo paths='**/*.ts' detector="rg --with-filename --line-number --no-heading 'FIXME' {files}"
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "  todo  detector changed"
  assert_contains "$OUT" "FAIL (1 problems)"
}

test_wrong_argument_count_exits_2() {
  exc_setup 'ok'
  run "$G" waive
  assert_eq 2 "$STATUS" "waive with none"
  assert_contains "$OUT" "usage: gauntlet waive"
  run "$G" waive a.ts
  assert_eq 2 "$STATUS" "waive with one"
  run "$G" waive a.ts r extra
  assert_eq 2 "$STATUS" "waive with three"
  run "$G" loosen todo "what"
  assert_eq 2 "$STATUS" "loosen with two"
  assert_contains "$OUT" "usage: gauntlet loosen"
  run "$G" remove todo
  assert_eq 2 "$STATUS" "remove with one"
  assert_contains "$OUT" "usage: gauntlet remove"
  run "$G" remove todo r extra
  assert_eq 2 "$STATUS" "remove with three"
  assert_eq "" "$(cat .gauntlet/exceptions.tsv)" "exceptions file"
}

test_waive_glob_and_dot_slash_rejected() {
  exc_setup 'ok'
  run "$G" waive '*.ts' "reason"
  assert_eq 2 "$STATUS" "glob status"
  run "$G" waive './a.ts' "reason"
  assert_eq 2 "$STATUS" "dot-slash status"
  assert_contains "$OUT" "without ./"
  run "$G" waive 'a/' "reason"
  assert_eq 2 "$STATUS" "trailing slash status"
  assert_eq "" "$(cat .gauntlet/exceptions.tsv)" "exceptions file"
}

test_row_appended_after_missing_newline() {
  exc_setup 'ok'
  header=$(printf 'type\ttarget\treason\tdate\tbranch')
  printf '%s' "$header" > .gauntlet/exceptions.tsv
  run "$G" waive a.ts "rewrite scheduled"
  assert_eq 0 "$STATUS" "waive status"
  today=$(date +%Y-%m-%d)
  expected=$(printf '%s\nwaive\ta.ts\trewrite scheduled\t%s\tfeat' "$header" "$today")
  assert_eq "$expected" "$(cat .gauntlet/exceptions.tsv)" "rows"
}

test_loosen_of_ab_does_not_cover_a() {
  mkrepo
  printf 'ok\n' > a.ts
  rule a paths='**/*.ts'
  rule ab paths='**/*.ts'
  cases_of a 'TODO x'
  cases_of ab 'TODO x'
  exc_rebase
  exc_commit main
  must git checkout -q -b feat
  rule a paths='**/*.ts' severity=shadow
  run "$G" loosen ab "severity to shadow" "reason"
  assert_eq 0 "$STATUS" "loosen status"
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "  a  severity block → shadow"
}

test_reordered_paths_and_exclude_are_not_loosening() {
  mkrepo
  mkdir -p src lib
  printf 'ok\n' > src/a.ts
  rule todo paths='src/** lib/**' exclude='x/** y/**'
  cases_of todo 'TODO FIXME x'
  exc_rebase
  exc_commit main
  must git checkout -q -b feat
  rule todo paths='lib/** src/**' exclude='y/** x/**'
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 0 "$STATUS" "status"
  assert_not_contains "$OUT" "[loosened]"
}

test_detector_args_file_change_is_loosening() {
  mkrepo
  mkdir -p tools
  printf '#!/bin/sh\nrg --with-filename --line-number --no-heading TODO "$@"\n' > tools/find.sh
  printf 'TODO\n' > a.ts
  rule todo paths='**/*.ts' engine=script detector='bash tools/find.sh {files}'
  exc_rebase
  exc_commit main
  must git checkout -q -b feat
  printf '#!/bin/sh\ntrue\n' > tools/find.sh
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "  todo  detector file tools/find.sh changed"
}

test_detector_args_file_removed_is_loosening() {
  mkrepo
  mkdir -p tools
  printf '#!/bin/sh\ntrue\n' > tools/find.sh
  printf 'ok\n' > a.ts
  rule todo paths='**/*.ts' engine=script detector='true tools/find.sh {files}'
  exc_rebase
  exc_commit main
  must git checkout -q -b feat
  must git rm -q tools/find.sh
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "  todo  detector file tools/find.sh changed"
}

test_detector_file_removed_with_bash_fails_closed() {
  mkrepo
  mkdir -p tools
  printf '#!/bin/sh\ntrue\n' > tools/find.sh
  printf 'ok\n' > a.ts
  rule todo paths='**/*.ts' engine=script detector='bash tools/find.sh {files}'
  exc_rebase
  exc_commit main
  must git checkout -q -b feat
  must git rm -q tools/find.sh
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 2 "$STATUS" "status: a broken detector stops the gate"
}

test_symlinked_detector_unrelated_commit_not_loosened() {
  mkrepo
  mkdir -p tools
  printf '#!/bin/sh\nrg --with-filename --line-number --no-heading TODO\n' > tools/real.sh
  chmod +x tools/real.sh
  ln -s real.sh tools/find.sh
  printf 'ok\n' > a.ts
  rule todo paths='**/*.ts' engine=script detector=tools/find.sh
  exc_rebase
  exc_commit main
  must git checkout -q -b feat
  printf 'x\n' > b.txt
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 0 "$STATUS" "status"
  assert_not_contains "$OUT" "[loosened]"
}

test_format_file_deleted_is_loosening() {
  mkrepo
  printf 'TODO\n' > a.ts
  rule todo paths='**/*.ts'
  cases_of todo 'TODO FIXME x'
  mkdir -p .gauntlet/formats
  printf -- '---\nmatch: ^([^:]+):([0-9]+)(:[0-9]+)?(: ?(.*))?$\npath: 1\nline: 2\nmessage: 5\nignore: nomatch\n---\n' > .gauntlet/formats/path-line.md
  exc_rebase
  exc_commit main
  must git checkout -q -b feat
  must git rm -q .gauntlet/formats/path-line.md
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "  todo  format file .gauntlet/formats/path-line.md removed"
}

# waive refuses a detached HEAD: a row needs a branch to belong to.
test_waive_refused_on_detached_head() {
  exc_setup 'ok'
  must git checkout -q --detach
  run "$G" waive a.ts "rewrite scheduled"
  assert_eq 2 "$STATUS" "waive on a detached HEAD: $OUT"
  assert_contains "$OUT" "detached HEAD: check out a branch first"
  assert_eq "" "$(cat .gauntlet/exceptions.tsv)" "no row was written"
}

# A directory is not a file: waive names a file, so a directory path is refused even
# though it exists.
test_waive_existing_directory_rejected() {
  exc_setup 'ok'
  mkdir -p d
  printf 'x\n' > d/f
  run "$G" waive d/ "rewrite scheduled"
  assert_eq 2 "$STATUS" "waive of a directory: $OUT"
  assert_contains "$OUT" "must name a file"
  assert_eq "" "$(cat .gauntlet/exceptions.tsv)" "no row was written"
}

# A format is named by the rule, so a rule that reads another format loosens even when
# the two format files hold the same bytes and no format file changed.
test_format_name_change_alone_is_loosening() {
  mkrepo
  printf 'ok\n' > a.ts
  rule todo paths='**/*.ts' format=alpha
  cases_of todo 'TODO x'
  mkdir -p .gauntlet/formats
  cp "$ROOT/lib/formats/path-line.md" .gauntlet/formats/alpha.md
  cp "$ROOT/lib/formats/path-line.md" .gauntlet/formats/beta.md
  exc_rebase
  exc_commit main
  must git checkout -q -b feat
  rule todo paths='**/*.ts' format=beta
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 1 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "  todo  format alpha → beta"
}

# An engine change alone is loosening: a linter that becomes a script runs a different
# kind of check, whatever its detector says.
test_engine_only_change_is_loosening() {
  mkrepo
  printf 'ok\n' > a.ts
  rule todo paths='**/*.ts' engine=linter
  cases_of todo 'TODO x'
  exc_rebase
  exc_commit main
  must git checkout -q -b feat
  rule todo paths='**/*.ts' engine=script
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 1 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "  todo  engine linter → script"
}

# A ./ prefix names the same file: a detector that runs ./tools/find.sh is judged by that
# file, and the report names it as tools/find.sh.
test_dot_slash_detector_file_change_is_loosening() {
  mkrepo
  mkdir -p tools
  printf '#!/bin/sh\nrg --with-filename --line-number --no-heading TODO "$@"\n' > tools/find.sh
  printf 'ok\n' > a.ts
  rule todo paths='**/*.ts' engine=script "detector=bash ./tools/find.sh {files}"
  cases_of todo 'TODO x'
  exc_rebase
  exc_commit main
  must git checkout -q -b feat
  printf '#!/bin/sh\nrg --with-filename --line-number --no-heading "TO" "$@" | rg -v "x"\n' > tools/find.sh
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 1 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "  todo  detector file tools/find.sh changed"
}

# A detector word is a plain word: *.md in a detector does not name the README that the
# branch changes, so the detector is unchanged and nothing is loosened.
test_glob_word_in_detector_names_no_file() {
  mkrepo
  printf 'ok\n' > a.ts
  printf 'hello\n' > README.md
  rule todo paths='**/*.ts' "detector=rg --with-filename --line-number --no-heading 'TODO' {files} *.md"
  cases_of todo 'TODO x'
  exc_rebase
  exc_commit main
  must git checkout -q -b feat
  printf 'hello again\n' > README.md
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_not_contains "$OUT" "detector file"
}
