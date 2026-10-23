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
  assert_contains "$OUT" "FAIL (1 problem)"
}

# R29: waive, loosen and remove run from the repo root whatever the working directory.
# The row for a path is root-relative, so waive finds pkg/sub/f.ts from pkg/sub too.
test_waive_from_a_subdirectory_writes_the_root_row() {
  exc_setup 'ok'
  must mkdir -p pkg/sub
  printf 'x\n' > pkg/sub/f.ts
  must cd pkg/sub
  run "$G" waive pkg/sub/f.ts "from below"
  assert_eq 0 "$STATUS" "waive from pkg/sub: $OUT"
  must cd ../..
  assert_contains "$(cat .gauntlet/exceptions.tsv)" "waive	pkg/sub/f.ts	from below	"
  if [ -e pkg/sub/.gauntlet ]; then fail "a .gauntlet directory appeared in pkg/sub"; fi
}

test_loosen_and_remove_from_a_subdirectory_write_the_root_rows() {
  exc_setup 'ok'
  must mkdir -p pkg/sub
  must cd pkg/sub
  run "$G" loosen todo "severity block -> track" "from below"
  assert_eq 0 "$STATUS" "loosen from pkg/sub: $OUT"
  run "$G" remove todo "from below"
  assert_eq 0 "$STATUS" "remove from pkg/sub: $OUT"
  must cd ../..
  assert_contains "$(cat .gauntlet/exceptions.tsv)" "loosen	todo: severity block -> track	from below	"
  assert_contains "$(cat .gauntlet/exceptions.tsv)" "remove	todo	from below	"
  if [ -e pkg/sub/.gauntlet ]; then fail "a .gauntlet directory appeared in pkg/sub"; fi
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
  assert_contains "$OUT" "FAIL (1 problem)"
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
  assert_contains "$OUT" "FAIL (1 problem)"
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
  script_row todo
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
  assert_contains "$OUT" "FAIL (1 problem)"
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
  script_row todo
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
  script_row todo
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
  script_row todo
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
  script_row todo
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
  script_row todo
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
  script_row todo
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

# R29: every repo command runs from the repo root, so a subdirectory changes nothing.
# exc_sub_setup: main with the todo rule at block, then feat with it at track (an
# unexcepted loosening), plus a pkg/sub directory to run from.
exc_sub_setup() {
  exc_setup 'ok'
  must mkdir -p "pkg/sub"
  printf 'ok\n' > "pkg/sub/x.ts"
  exc_commit sub
  rule todo paths='**/*.ts' severity=track
  exc_rebase
  exc_commit feat
}

# exc_untimed <text>: the text without its timing lines, which differ on every run.
exc_untimed() {
  printf '%s\n' "$1" | grep -v ' ms$' | grep -v '^gauntlet  [a-z]* · '
}

test_ci_loosening_is_found_from_a_subdirectory() {
  exc_sub_setup
  exc_gate
  assert_eq 1 "$STATUS" "from the root: $OUT"
  assert_contains "$OUT" "  todo  severity block → track"
  want=$(exc_untimed "$OUT")
  must cd pkg/sub
  exc_gate
  assert_eq 1 "$STATUS" "from pkg/sub: $OUT"
  assert_contains "$OUT" "[loosened]"
  assert_contains "$OUT" "FAIL (1 problem)"
  assert_eq "$want" "$(exc_untimed "$OUT")" "same report as from the root"
}

test_staged_gate_from_a_subdirectory_matches_the_root() {
  exc_setup 'ok'
  must mkdir -p "pkg/sub"
  printf 'TODO fix\n' > "pkg/sub/n.ts"
  must git add -A
  run "$G" check --staged
  assert_eq 1 "$STATUS" "from the root: $OUT"
  assert_contains "$OUT" "pkg/sub/n.ts:1"
  want=$(exc_untimed "$OUT")
  must cd pkg/sub
  run "$G" check --staged
  assert_eq 1 "$STATUS" "from pkg/sub: $OUT"
  assert_eq "$want" "$(exc_untimed "$OUT")" "same report as from the root"
}

test_baseline_from_a_subdirectory_writes_the_root_file() {
  exc_setup 'TODO one'
  must mkdir -p "pkg/sub"
  printf 'TODO two\nTODO three\n' > "pkg/sub/a b.ts"
  must git add -A
  run "$G" baseline
  assert_eq 0 "$STATUS" "from the root: $OUT"
  must cp .gauntlet/baseline.tsv "$TMP/want.tsv"
  must git checkout -q -- .gauntlet/baseline.tsv
  must cd pkg/sub
  run "$G" baseline
  assert_eq 0 "$STATUS" "from pkg/sub: $OUT"
  must cmp "$TMP/want.tsv" "$TMP/repo/.gauntlet/baseline.tsv"
  [ ! -e .gauntlet ] || fail "baseline created a .gauntlet in the subdirectory"
}

test_test_rules_from_a_subdirectory_matches_the_root() {
  exc_setup 'ok'
  must mkdir -p "pkg/sub"
  printf 'fine\n' > .gauntlet/rules/todo.bad.txt
  run "$G" test-rules
  assert_eq 1 "$STATUS" "from the root: $OUT"
  assert_contains "$OUT" "bad case not flagged"
  want=$OUT
  must cd pkg/sub
  run "$G" test-rules
  assert_eq 1 "$STATUS" "from pkg/sub: $OUT"
  assert_eq "$want" "$OUT" "same report as from the root"
}

test_status_from_a_subdirectory_writes_the_root_file() {
  exc_setup 'ok'
  must mkdir -p "pkg/sub"
  run "$G" status
  assert_eq 0 "$STATUS" "from the root: $OUT"
  want=$OUT
  must rm .gauntlet/STATUS.md
  must cd pkg/sub
  run "$G" status
  assert_eq 0 "$STATUS" "from pkg/sub: $OUT"
  assert_eq "$want" "$OUT" "same text as from the root"
  [ -f "$TMP/repo/.gauntlet/STATUS.md" ] || fail "STATUS.md was not written at the root"
  [ ! -e .gauntlet ] || fail "status created a .gauntlet in the subdirectory"
}

test_doctor_from_a_subdirectory_matches_the_root() {
  exc_setup 'ok'
  must mkdir -p "pkg/sub"
  run "$G" doctor
  want=$OUT
  want_status=$STATUS
  must cd pkg/sub
  run "$G" doctor
  assert_eq "$want_status" "$STATUS" "status: $OUT"
  assert_eq "$want" "$OUT" "same report as from the root"
}

test_promote_from_a_subdirectory_edits_the_root_rule() {
  exc_setup 'ok' severity=shadow
  must mkdir -p "pkg/sub"
  must cd pkg/sub
  run "$G" promote todo
  assert_eq 0 "$STATUS" "from pkg/sub: $OUT"
  assert_contains "$(cat "$TMP/repo/.gauntlet/rules/todo.md")" "severity: block"
}

# Outside a repo every repo command says so and exits 2; git's own usage text for
# `diff --no-index` never reaches the user.
test_repo_commands_outside_a_repo_exit_2_with_one_message() {
  must mkdir -p "$TMP/plain"
  must cd "$TMP/plain"
  for c in "check --ci" "check --staged" baseline test-rules status doctor "promote x" \
    "waive a b" "loosen a b c" "remove a b" base install install-hooks; do
    # shellcheck disable=SC2086 # the words of $c are separate arguments
    run "$G" $c
    assert_eq 2 "$STATUS" "gauntlet $c: $OUT"
    assert_contains "$OUT" "not inside a git repository"
    assert_not_contains "$OUT" "no-index"
  done
  run "$G" --version
  assert_eq 0 "$STATUS" "--version needs no repo: $OUT"
  run "$G" nonsense
  assert_eq 2 "$STATUS" "unknown command: $OUT"
  assert_contains "$OUT" "unknown command: nonsense"
}

# The base's rule list is read with --full-tree and --: a library call from a
# subdirectory still sees .gauntlet/rules, and bin/gauntlet's cd is not the only guard.
test_cmp_loosened_lists_base_rules_from_a_subdirectory() {
  exc_sub_setup
  # shellcheck source=lib/core.sh
  . "$ROOT/lib/core.sh"
  # shellcheck source=lib/rules.sh
  . "$ROOT/lib/rules.sh"
  # shellcheck source=lib/detect.sh
  . "$ROOT/lib/detect.sh"
  # shellcheck source=lib/base.sh
  . "$ROOT/lib/base.sh"
  # shellcheck source=lib/exceptions.sh
  . "$ROOT/lib/exceptions.sh"
  # shellcheck source=lib/paths.sh
  . "$ROOT/lib/paths.sh"
  # shellcheck source=lib/check.sh
  . "$ROOT/lib/check.sh"
  sha=$(git merge-base HEAD main)
  must cd pkg/sub
  OUT=$(cmp_loosened "$sha") || fail "cmp_loosened failed"
  assert_contains "$OUT" "todo"
  assert_contains "$OUT" "severity block → track"
}

# R32 at the format file: when the listing of it fails, at the base or at HEAD, the
# gate stops at exit 2 instead of calling the file added or removed.
exc_format_setup() {
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
}

test_failed_listing_of_the_format_file_at_the_base_is_exit_2() {
  exc_format_setup
  git_fails ls-tree .gauntlet/formats/path-line.md "$(git rev-parse main)"
  run "$G" check --ci --base main
  assert_eq 2 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "simulated failure"
  assert_not_contains "$OUT" "format file"
}

test_failed_listing_of_the_format_file_at_head_is_exit_2() {
  exc_format_setup
  git_fails ls-tree .gauntlet/formats/path-line.md HEAD
  run "$G" check --ci --base main
  assert_eq 2 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "simulated failure"
  assert_not_contains "$OUT" "format file"
}

# R36: loosen and remove name a rule that exists, so a typo cannot write a row that covers
# nothing. A rule exists when its file is in the working tree, in HEAD, or at the merge-base.
test_loosen_rejects_an_unknown_rule() {
  exc_setup 'ok'
  run "$G" loosen nope "severity to shadow" "why"
  assert_eq 2 "$STATUS" "loosen: $OUT"
  assert_eq "gauntlet: no rule nope" "$OUT" "message"
  # An id is a file stem, not a path: ../notes would name .gauntlet/notes.md.
  printf 'x\n' > .gauntlet/notes.md
  run "$G" loosen ../notes "severity to shadow" "why"
  assert_eq 2 "$STATUS" "a path is not a rule id: $OUT"
  assert_eq "" "$(cat .gauntlet/exceptions.tsv)" "no row was written"
}

test_remove_rejects_an_unknown_rule() {
  exc_setup 'ok'
  run "$G" remove nope "why"
  assert_eq 2 "$STATUS" "remove: $OUT"
  assert_eq "gauntlet: no rule nope" "$OUT" "message"
  assert_eq "" "$(cat .gauntlet/exceptions.tsv)" "no row was written"
}

# EXC-AC4 still comes first for a rule that does not exist: the reason is wrong either way.
test_an_empty_reason_for_an_unknown_rule_is_exit_2() {
  exc_setup 'ok'
  run "$G" loosen nope "what" ""
  assert_eq 2 "$STATUS" "loosen: $OUT"
  run "$G" remove nope ""
  assert_eq 2 "$STATUS" "remove: $OUT"
  assert_eq "" "$(cat .gauntlet/exceptions.tsv)" "no row was written"
}

test_loosen_and_remove_accept_a_rule_in_the_working_tree() {
  exc_setup 'ok'
  run "$G" loosen todo "severity to shadow" "why"
  assert_eq 0 "$STATUS" "loosen: $OUT"
  run "$G" remove todo "why"
  assert_eq 0 "$STATUS" "remove: $OUT"
}

# A human may delete the rule file first and run the command after: HEAD still has it.
test_loosen_and_remove_accept_a_rule_only_head_has() {
  exc_setup 'ok'
  must rm .gauntlet/rules/todo.md
  run "$G" loosen todo "severity to shadow" "why"
  assert_eq 0 "$STATUS" "loosen: $OUT"
  run "$G" remove todo "why"
  assert_eq 0 "$STATUS" "remove: $OUT"
}

# ... or after committing the deletion: only the merge-base has it.
test_loosen_and_remove_accept_a_rule_only_the_base_has() {
  exc_setup 'ok'
  must git rm -q .gauntlet/rules/todo.md
  exc_commit drop-rule
  run "$G" loosen todo "severity to shadow" "why"
  assert_eq 0 "$STATUS" "loosen: $OUT"
  run "$G" remove todo "why"
  assert_eq 0 "$STATUS" "remove: $OUT"
}

# The pseudo-rule @config stands for .gauntlet/config: it can be loosened, never removed.
test_loosen_accepts_the_config_pseudo_rule_and_remove_does_not() {
  exc_setup 'ok'
  run "$G" loosen @config "touched on -> off" "why"
  assert_eq 0 "$STATUS" "loosen: $OUT"
  assert_contains "$(cat .gauntlet/exceptions.tsv)" "loosen	@config: touched on -> off	why	"
  run "$G" remove @config "why"
  assert_eq 2 "$STATUS" "remove: $OUT"
  assert_eq "gauntlet: no rule @config" "$OUT" "message"
}

# R32: a rule lookup that git cannot answer is exit 2, never "no such rule".
test_a_failed_lookup_of_the_rule_in_head_is_exit_2() {
  exc_setup 'ok'
  must rm .gauntlet/rules/todo.md
  git_fails ls-tree .gauntlet/rules/todo.md HEAD
  run "$G" loosen todo "severity to shadow" "why"
  assert_eq 2 "$STATUS" "loosen: $OUT"
  assert_contains "$OUT" "simulated failure"
  assert_not_contains "$OUT" "no rule"
}

test_a_failed_lookup_of_the_rule_at_the_base_is_exit_2() {
  exc_setup 'ok'
  must git rm -q .gauntlet/rules/todo.md
  exc_commit drop-rule
  git_fails ls-tree .gauntlet/rules/todo.md "$(git rev-parse main)"
  run "$G" remove todo "why"
  assert_eq 2 "$STATUS" "remove: $OUT"
  assert_contains "$OUT" "simulated failure"
  assert_not_contains "$OUT" "no rule"
}

# A repo that never ran gauntlet install has no .gauntlet/: the commands say so instead
# of showing the shell's redirect error.
test_exception_commands_without_a_gauntlet_directory() {
  must mkdir -p "$TMP/plain"
  must cd "$TMP/plain"
  must git init -q .
  must git symbolic-ref HEAD refs/heads/main
  printf 'x\n' > a.ts
  for c in "waive a.ts why" "loosen todo what why" "remove todo why" "loosen @config what why"; do
    # shellcheck disable=SC2086 # the words of $c are separate arguments
    run "$G" $c
    assert_eq 2 "$STATUS" "gauntlet $c: $OUT"
    assert_eq "gauntlet: no .gauntlet/ directory; run gauntlet install" "$OUT" "gauntlet $c"
  done
  [ ! -e .gauntlet ] || fail "a .gauntlet directory appeared"
}

# A loosening that a new row covers passes, and says so: a reviewer reading the CI log sees
# what was relaxed and why. One note per covered item; the exit code is not touched.
test_a_covered_loosening_prints_a_note_and_passes() {
  exc_setup 'ok'
  rule todo paths='**/*.ts' severity=shadow
  run "$G" loosen todo "severity to shadow" "generated code"
  assert_eq 0 "$STATUS" "loosen status"
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_contains "$OUT" 'note: loosened todo: severity block → shadow; covered by "generated code"'
  assert_contains "$OUT" "gauntlet: ok"
  assert_not_contains "$OUT" "[loosened]"
}

test_each_covered_item_gets_its_own_note() {
  mkrepo
  mkdir -p src lib
  printf 'ok\n' > src/a.ts
  rule todo paths='src/** lib/**'
  cases_of todo 'TODO FIXME x'
  exc_rebase
  exc_commit main
  must git checkout -q -b feat
  rule todo paths='src/**' severity=shadow
  run "$G" loosen todo "narrower and shadow" "legacy tree"
  assert_eq 0 "$STATUS" "loosen status"
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_contains "$OUT" 'note: loosened todo: severity block → shadow; covered by "legacy tree"'
  assert_contains "$OUT" 'note: loosened todo: paths narrowed: lib/**; covered by "legacy tree"'
  assert_eq 2 "$(printf '%s\n' "$OUT" | grep -c '^note: loosened ')" "one note per item"
}

test_a_covered_rule_removal_prints_a_note() {
  exc_setup 'ok'
  must git rm -q .gauntlet/rules/todo.md
  run "$G" remove todo "rule retired"
  assert_eq 0 "$STATUS" "remove status"
  exc_rebase
  exc_commit drop-rule
  exc_gate
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_contains "$OUT" 'note: loosened todo: rule file removed; covered by "rule retired"'
}

# Only what a row covers is noted; what it does not cover keeps failing, in the old words.
test_an_uncovered_loosening_prints_no_note_and_still_fails() {
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
  rule ab paths='**/*.ts' severity=shadow
  run "$G" loosen ab "severity to shadow" "reason ab"
  assert_eq 0 "$STATUS" "loosen status"
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 1 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "[loosened]"
  assert_contains "$OUT" "  a  severity block → shadow"
  assert_contains "$OUT" 'note: loosened ab: severity block → shadow; covered by "reason ab"'
  assert_not_contains "$OUT" "note: loosened a:"
  assert_contains "$OUT" "FAIL (1 problem)"
}

# The note is the same on a laptop and in CI: the owner's rule is that the two never differ.
test_the_covered_note_is_the_same_in_ci() {
  exc_setup 'ok'
  rule todo paths='**/*.ts' severity=shadow
  run "$G" loosen todo "severity to shadow" "generated code"
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 0 "$STATUS" "local: $OUT"
  want=$(exc_untimed "$OUT")
  CI=true exc_gate
  assert_eq 0 "$STATUS" "CI: $OUT"
  assert_eq "$want" "$(exc_untimed "$OUT")" "same report with CI=true"
}

# A row edited by hand may lack its reason; it still covers, and the note shows the empty one.
test_a_row_with_an_empty_reason_still_covers() {
  exc_setup 'ok'
  rule todo paths='**/*.ts' severity=shadow
  printf 'loosen\ttodo: severity to shadow\t\t2026-10-22\t-\n' >> .gauntlet/exceptions.tsv
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_contains "$OUT" 'note: loosened todo: severity block → shadow; covered by ""'
}

# R34: .gauntlet/config is judged like a rule file. A change that lets the branch off
# something the base enforced is a loosening, and a new `loosen @config` row covers it.
# exc_cfg <base config> <head config>: main holds the first config, feat the second, and
# the gate has run against main ($OUT and $STATUS). The todo rule is clean, so the config
# is the only thing under test.
exc_cfg() {
  mkrepo
  printf 'ok\n' > a.ts
  rule todo paths='**/*.ts'
  cases_of todo 'TODO x'
  printf '%s' "$1" > .gauntlet/config
  exc_rebase
  exc_commit main
  must git checkout -q -b feat
  printf '%s' "$2" > .gauntlet/config
  exc_rebase
  exc_commit feat
  exc_gate
}

# exc_cfg_loosened <base config> <head config> <line>...: the gate fails on exactly these
# @config lines.
exc_cfg_loosened() {
  local base=$1 head=$2 line n=0
  shift 2
  exc_cfg "$base" "$head"
  assert_eq 1 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "[loosened]"
  for line in "$@"; do
    assert_contains "$OUT" "  @config  $line"
    n=$((n + 1))
  done
  assert_eq "$n" "$(printf '%s\n' "$OUT" | grep -c '^  @config  ')" "number of @config lines in: $OUT"
  if [ "$n" -eq 1 ]; then
    assert_contains "$OUT" "FAIL (1 problem)"
  else
    assert_contains "$OUT" "FAIL ($n problems)"
  fi
}

# exc_cfg_free <base config> <head config>: the gate passes and reports nothing loosened.
exc_cfg_free() {
  exc_cfg "$1" "$2"
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_not_contains "$OUT" "[loosened]"
  assert_not_contains "$OUT" "@config"
}

test_a_changed_base_is_loosening() {
  exc_cfg_loosened $'base=origin/dev\n' $'base=origin/main\n' "base origin/dev → origin/main"
}

test_a_base_added_to_the_config_is_loosening() {
  exc_cfg_loosened $'touched=off\n' $'touched=off\nbase=origin/dev\n' "base (unset) → origin/dev"
}

test_a_base_removed_from_the_config_is_loosening() {
  exc_cfg_loosened $'base=origin/dev\n' $'touched=off\n' "base origin/dev → (unset)"
}

test_touched_on_to_off_is_loosening() {
  exc_cfg_loosened $'touched=on\n' $'touched=off\n' "touched on → off"
}

# The default is off (touched_mode), so deleting the line of an enabled gate turns it off.
test_deleting_touched_on_is_loosening() {
  exc_cfg_loosened $'touched=on\n' $'# gone\n' "touched on → off"
}

# The last line wins, as the runner reads it: the effective value went from on to off.
test_the_effective_touched_value_is_the_last_line() {
  exc_cfg_loosened $'touched=on\n' $'touched=on\ntouched=off\n' "touched on → off"
}

test_a_removed_check_is_loosening() {
  exc_cfg_loosened $'check.lint=true\ncheck.unit=true\n' $'check.unit=true\n' "check lint removed"
}

test_a_check_turned_off_for_ci_is_loosening() {
  exc_cfg_loosened $'check.lint=true\ncheck.lint.ci=on\n' $'check.lint=true\ncheck.lint.ci=off\n' "check lint ci on → off"
}

# The default of .ci is off, so deleting the line of a check that ran in CI turns it off.
test_deleting_a_check_ci_line_is_loosening() {
  exc_cfg_loosened $'check.lint=true\ncheck.lint.ci=on\n' $'check.lint=true\n' "check lint ci on → off"
}

test_narrowed_check_paths_are_loosening() {
  exc_cfg_loosened $'check.lint=true\ncheck.lint.paths=src/ lib/\n' $'check.lint=true\ncheck.lint.paths=src/\n' \
    "check lint paths narrowed: lib/"
}

# A prefix that was in scope and no longer is: src/ became src/api/.
test_a_deeper_check_prefix_is_narrowing() {
  exc_cfg_loosened $'check.lint=true\ncheck.lint.paths=src/\n' $'check.lint=true\ncheck.lint.paths=src/api/\n' \
    "check lint paths narrowed: src/"
}

# An empty value means every change: empty to non-empty narrows.
test_check_paths_from_empty_to_a_prefix_is_narrowing() {
  exc_cfg_loosened $'check.lint=true\n' $'check.lint=true\ncheck.lint.paths=src/\n' \
    "check lint paths narrowed: all files → src/"
}

test_a_changed_check_command_is_loosening() {
  exc_cfg_loosened $'check.lint=true\n' $'check.lint=exit 0\n' "check lint command changed"
}

test_every_item_of_a_changed_config_is_its_own_line() {
  exc_cfg_loosened $'base=origin/dev\ntouched=on\ncheck.lint=true\ncheck.unit=true\ncheck.unit.ci=on\n' \
    $'touched=off\ncheck.unit=exit 0\n' \
    "base origin/dev → (unset)" "touched on → off" "check lint removed" "check unit ci on → off" "check unit command changed"
}

# A config deleted by the branch: every key that mattered is a loosening.
test_a_deleted_config_loosens_everything_that_mattered() {
  mkrepo
  printf 'ok\n' > a.ts
  rule todo paths='**/*.ts'
  cases_of todo 'TODO x'
  printf 'touched=on\ncheck.lint=true\n' > .gauntlet/config
  exc_rebase
  exc_commit main
  must git checkout -q -b feat
  must git rm -q .gauntlet/config
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 1 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "  @config  touched on → off"
  assert_contains "$OUT" "  @config  check lint removed"
}

# A base with rules but no config reads as all defaults: a base= is a change.
test_a_config_added_with_a_base_is_loosening() {
  mkrepo
  printf 'ok\n' > a.ts
  rule todo paths='**/*.ts'
  cases_of todo 'TODO x'
  must git rm -q -f .gauntlet/config
  exc_rebase
  exc_commit main
  must git checkout -q -b feat
  printf 'base=origin/dev\n' > .gauntlet/config
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 1 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "  @config  base (unset) → origin/dev"
}

# Not loosening: each of these keeps every guarantee the base had, or adds one.
test_a_stage_change_in_a_rule_is_not_loosening() {
  mkrepo
  printf 'ok\n' > a.ts
  rule todo paths='**/*.ts' stage=push
  cases_of todo 'TODO x'
  exc_rebase
  exc_commit main
  must git checkout -q -b feat
  rule todo paths='**/*.ts' stage=commit
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 0 "$STATUS" "commit to push: $OUT"
  assert_not_contains "$OUT" "[loosened]"
  rule todo paths='**/*.ts' stage=push
  exc_rebase
  exc_commit back
  exc_gate
  assert_eq 0 "$STATUS" "push to commit: $OUT"
  assert_not_contains "$OUT" "[loosened]"
}

test_adding_a_check_is_not_loosening() {
  exc_cfg_free $'touched=off\n' $'touched=off\ncheck.lint=true\n'
}

test_turning_a_check_on_for_ci_is_not_loosening() {
  exc_cfg_free $'check.lint=true\ncheck.lint.ci=off\n' $'check.lint=true\ncheck.lint.ci=on\n'
}

test_a_check_ci_line_added_with_off_is_not_loosening() {
  exc_cfg_free $'check.lint=true\n' $'check.lint=true\ncheck.lint.ci=off\n'
}

test_widened_check_paths_are_not_loosening() {
  exc_cfg_free $'check.lint=true\ncheck.lint.paths=src/api/\n' $'check.lint=true\ncheck.lint.paths=src/\n'
}

test_more_check_prefixes_are_not_loosening() {
  exc_cfg_free $'check.lint=true\ncheck.lint.paths=src/\n' $'check.lint=true\ncheck.lint.paths=src/ lib/\n'
}

test_check_paths_cleared_are_not_loosening() {
  exc_cfg_free $'check.lint=true\ncheck.lint.paths=src/\n' $'check.lint=true\n'
}

test_reordered_check_prefixes_are_not_loosening() {
  exc_cfg_free $'check.lint=true\ncheck.lint.paths=src/ lib/\n' $'check.lint=true\ncheck.lint.paths=lib/ src/\n'
}

test_touched_off_to_on_is_not_loosening() {
  exc_cfg_free $'touched=off\n' $'touched=on\n'
}

test_deleting_touched_off_is_not_loosening() {
  exc_cfg_free $'touched=off\n' $'# nothing\n'
}

test_comments_blank_lines_and_spacing_are_not_loosening() {
  exc_cfg_free $'touched=on\ncheck.lint=true\ncheck.lint.paths=src/\n' \
    $'# the gate\n\n  touched = on  \ncheck.lint =true\n\n# scope\ncheck.lint.paths =  src/  \n'
}

# A CRLF config reads like an LF one, in either direction.
test_crlf_and_lf_configs_are_the_same_config() {
  exc_cfg_free $'touched=on\ncheck.lint=true\ncheck.lint.ci=on\n' $'touched=on\r\ncheck.lint=true\r\ncheck.lint.ci=on\r\n'
}

test_an_lf_config_after_a_crlf_one_is_the_same_config() {
  exc_cfg_free $'touched=on\r\ncheck.lint=true\r\n' $'touched=on\ncheck.lint=true\n'
}

# A byte-order mark before a comment changes no value. Before a key the runner has always
# ignored the key (doctor says so); the gate judges the effective value, so that is a loosening.
test_a_byte_order_mark_before_a_comment_is_not_loosening() {
  exc_cfg_free $'# gauntlet config\ntouched=on\n' $'\357\273\277# gauntlet config\ntouched=on\n'
}

test_a_byte_order_mark_before_a_key_is_judged_as_the_runner_reads_it() {
  exc_cfg_loosened $'touched=on\n' $'\357\273\277touched=on\n' "touched on → off"
}

# Covered, uncovered, and the row that is too old.
test_a_config_loosening_passes_with_a_new_config_row() {
  mkrepo
  printf 'ok\n' > a.ts
  rule todo paths='**/*.ts'
  cases_of todo 'TODO x'
  printf 'touched=on\n' > .gauntlet/config
  exc_rebase
  exc_commit main
  must git checkout -q -b feat
  printf 'touched=off\n' > .gauntlet/config
  run "$G" loosen @config "touched on -> off" "the gate was too slow"
  assert_eq 0 "$STATUS" "loosen status: $OUT"
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_contains "$OUT" 'note: loosened @config: touched on → off; covered by "the gate was too slow"'
  assert_not_contains "$OUT" "[loosened]"
}

# One row covers every @config item, as one loosen row covers every change to a rule.
test_one_config_row_covers_every_config_item() {
  mkrepo
  printf 'ok\n' > a.ts
  rule todo paths='**/*.ts'
  cases_of todo 'TODO x'
  printf 'touched=on\ncheck.lint=true\n' > .gauntlet/config
  exc_rebase
  exc_commit main
  must git checkout -q -b feat
  printf 'touched=off\n' > .gauntlet/config
  run "$G" loosen @config "touched off, lint gone" "moved to CI"
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_contains "$OUT" 'note: loosened @config: touched on → off; covered by "moved to CI"'
  assert_contains "$OUT" 'note: loosened @config: check lint removed; covered by "moved to CI"'
}

test_an_old_config_row_does_not_cover_a_new_config_loosening() {
  mkrepo
  printf 'ok\n' > a.ts
  rule todo paths='**/*.ts'
  cases_of todo 'TODO x'
  printf 'touched=on\n' > .gauntlet/config
  run "$G" loosen @config "an earlier change" "reason"
  assert_eq 0 "$STATUS" "loosen status: $OUT"
  exc_rebase
  exc_commit main
  must git checkout -q -b feat
  printf 'touched=off\n' > .gauntlet/config
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 1 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "  @config  touched on → off"
}

# exc_both_loosened <row-id> <what> <reason>: main enforces touched=on and the todo rule at
# block; feat turns both off, and only one new row, for <row-id>, covers anything.
exc_both_loosened() {
  mkrepo
  printf 'ok\n' > a.ts
  rule todo paths='**/*.ts'
  cases_of todo 'TODO x'
  printf 'touched=on\n' > .gauntlet/config
  exc_rebase
  exc_commit main
  must git checkout -q -b feat
  printf 'touched=off\n' > .gauntlet/config
  rule todo paths='**/*.ts' severity=shadow
  run "$G" loosen "$1" "$2" "$3"
  assert_eq 0 "$STATUS" "loosen status: $OUT"
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 1 "$STATUS" "status: $OUT"
}

test_a_rule_row_does_not_cover_the_config() {
  exc_both_loosened todo "severity to shadow" "rule reason"
  assert_contains "$OUT" "  @config  touched on → off"
  assert_contains "$OUT" 'note: loosened todo: severity block → shadow; covered by "rule reason"'
  assert_not_contains "$OUT" "  todo  severity"
}

test_a_config_row_does_not_cover_a_rule() {
  exc_both_loosened @config "touched off" "config reason"
  assert_contains "$OUT" "  todo  severity block → shadow"
  assert_contains "$OUT" 'note: loosened @config: touched on → off; covered by "config reason"'
  assert_not_contains "$OUT" "  @config  touched"
}

# The first install is not judged: with no rules and no config at the base there is nothing to loosen.
test_the_onboarding_branch_may_set_a_base_without_a_row() {
  must mkdir -p "$TMP/repo"
  must cd "$TMP/repo"
  must git init -q .
  must git symbolic-ref HEAD refs/heads/main
  must git config user.name "Test User"
  must git config user.email "test@example.com"
  must git config commit.gpgsign false
  printf 'ok\n' > a.ts
  exc_commit main
  must git checkout -q -b feat
  must mkdir -p .gauntlet/rules
  printf 'base=origin/dev\ntouched=on\n' > .gauntlet/config
  must touch .gauntlet/baseline.tsv .gauntlet/exceptions.tsv
  exc_commit onboarding
  exc_gate
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_not_contains "$OUT" "@config"
}

# R29: from a subdirectory and with CI=true the report is the one the root run makes.
test_the_config_loosening_report_is_the_same_from_a_subdirectory_and_in_ci() {
  exc_cfg $'touched=on\ncheck.lint=true\n' $'touched=off\n'
  assert_eq 1 "$STATUS" "from the root: $OUT"
  want=$(exc_untimed "$OUT")
  must mkdir -p pkg/sub
  must cd pkg/sub
  exc_gate
  assert_eq 1 "$STATUS" "from pkg/sub: $OUT"
  assert_eq "$want" "$(exc_untimed "$OUT")" "same report from a subdirectory"
  must cd ../..
  CI=true exc_gate
  assert_eq 1 "$STATUS" "CI=true: $OUT"
  assert_eq "$want" "$(exc_untimed "$OUT")" "same report with CI=true"
}

# A base with a config and no rule yet is still compared: the declared checks it enforces
# are not an onboarding matter.
test_the_config_is_judged_when_the_base_has_no_rules() {
  mkrepo
  printf 'ok\n' > a.ts
  printf 'check.lint=true\n' > .gauntlet/config
  exc_rebase
  exc_commit main
  must git checkout -q -b feat
  printf 'touched=off\n' > .gauntlet/config
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 1 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "  @config  check lint removed"
}

# The lines come out in one order whatever order awk walks its arrays in: by check name.
test_removed_checks_are_listed_by_name() {
  exc_cfg $'check.zeta=true\ncheck.beta=true\ncheck.alpha=true\ncheck.mid=true\ncheck.omega=true\ncheck.delta=true\n' $'touched=off\n'
  assert_eq 1 "$STATUS" "status: $OUT"
  got=$(printf '%s\n' "$OUT" | grep '^  @config  check ' | tr '\n' '|')
  assert_eq "  @config  check alpha removed|  @config  check beta removed|  @config  check delta removed|  @config  check mid removed|  @config  check omega removed|  @config  check zeta removed|" "$got" "order"
}

# R32 for blob_changed: a detector file or format file that git cannot list, at the base or at
# HEAD, is exit 2 and never "unchanged" or "changed". exc_script_rule <detector>: main holds
# tools/find.sh (a script that finds TODO) and the todo rule over it with that detector, then a
# feat branch.
exc_script_rule() {
  mkrepo
  must mkdir -p tools "my tools"
  printf '#!/bin/sh\nrg --with-filename --line-number --no-heading TODO "$@"\n' > tools/find.sh
  cp tools/find.sh "my tools/find.sh"
  printf 'ok\n' > a.ts
  rule todo paths='**/*.ts' engine=script "detector=$1"
  script_row todo
  exc_rebase
  exc_commit main
  must git checkout -q -b feat
}

# exc_tool_commit: a commit on feat that touches nothing the rule reads.
exc_tool_commit() {
  printf 'x\n' > b.txt
  exc_rebase
  exc_commit feat
}

test_an_unreadable_detector_file_at_the_base_is_exit_2() {
  exc_script_rule 'bash tools/find.sh {files}'
  exc_tool_commit
  git_fails ls-tree tools/find.sh "$(git rev-parse main)"
  exc_gate
  assert_eq 2 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "simulated failure"
  assert_not_contains "$OUT" "detector file"
}

test_an_unreadable_detector_file_at_head_is_exit_2() {
  exc_script_rule 'bash tools/find.sh {files}'
  exc_tool_commit
  git_fails ls-tree tools/find.sh HEAD
  exc_gate
  assert_eq 2 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "simulated failure"
  assert_not_contains "$OUT" "detector file"
}

# The second listing of the format file is the one that tells added from removed from changed;
# the first belongs to blob_changed, which the two tests that fail the first listing now meet.
test_a_failed_second_listing_of_the_format_file_at_the_base_is_exit_2() {
  exc_format_setup
  git_fails ls-tree .gauntlet/formats/path-line.md "$(git rev-parse main)" 2
  run "$G" check --ci --base main
  assert_eq 2 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "simulated failure"
  assert_not_contains "$OUT" "format file"
}

test_a_failed_second_listing_of_the_format_file_at_head_is_exit_2() {
  exc_format_setup
  git_fails ls-tree .gauntlet/formats/path-line.md HEAD 2
  run "$G" check --ci --base main
  assert_eq 2 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "simulated failure"
  assert_not_contains "$OUT" "format file"
}

# The same format file, unreadable at the first listing: a guard on the listing blob_changed makes.
test_an_unreadable_format_file_is_exit_2_in_blob_changed_too() {
  exc_format_setup
  git_fails ls-tree .gauntlet/formats/path-line.md "$(git rev-parse main)" 1
  run "$G" check --ci --base main
  assert_eq 2 "$STATUS" "at the base: $OUT"
  assert_not_contains "$OUT" "format file"
}

# What the callers are told: 0 changed, 1 the same, 2 unreadable.
test_blob_changed_answers_changed_same_and_unreadable() {
  exc_script_rule 'bash tools/find.sh {files}'
  # shellcheck source=lib/core.sh
  . "$ROOT/lib/core.sh"
  # shellcheck source=lib/rules.sh
  . "$ROOT/lib/rules.sh"
  # shellcheck source=lib/detect.sh
  . "$ROOT/lib/detect.sh"
  # shellcheck source=lib/base.sh
  . "$ROOT/lib/base.sh"
  # shellcheck source=lib/exceptions.sh
  . "$ROOT/lib/exceptions.sh"
  # shellcheck source=lib/paths.sh
  . "$ROOT/lib/paths.sh"
  # shellcheck source=lib/check.sh
  . "$ROOT/lib/check.sh"
  mb=$(git rev-parse main)
  exc_tool_commit
  rc=0
  blob_changed "$mb" tools/find.sh || rc=$?
  assert_eq 1 "$rc" "same file on both sides"
  rc=0
  blob_changed "$mb" tools/missing.sh || rc=$?
  assert_eq 1 "$rc" "absent on both sides"
  printf '#!/bin/sh\ntrue\n' > tools/find.sh
  exc_rebase
  exc_commit changed
  rc=0
  blob_changed "$mb" tools/find.sh || rc=$?
  assert_eq 0 "$rc" "changed file"
  rc=0
  blob_changed "$mb" b.txt || rc=$?
  assert_eq 0 "$rc" "added file"
  git_fails ls-tree tools/find.sh HEAD
  rc=0
  blob_changed "$mb" tools/find.sh 2> "$TMP/err" || rc=$?
  assert_eq 2 "$rc" "unreadable: $(cat "$TMP/err")"
  assert_contains "$(cat "$TMP/err")" "simulated failure"
}

# A detector word is any text: most of it names no file of the repository. Such a word is
# absent, never an unreadable one. "." is the root, ".." and an absolute path leave the tree,
# and a leading ":" is git's pathspec magic.
test_detector_words_that_name_no_file_in_the_tree_are_not_read() {
  mkrepo
  must mkdir -p tools
  printf '#!/bin/sh\nexit 1\n' > tools/quiet.sh
  printf 'ok\n' > a.ts
  rule todo paths='**/*.ts' engine=script 'detector=bash tools/quiet.sh {files} . ./ .. ../x /tmp/ran.marker :\(glob\)x sub/../../y -v --'
  script_row todo
  exc_rebase
  exc_commit main
  must git checkout -q -b feat
  exc_tool_commit
  exc_gate
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_not_contains "$OUT" "detector file"
  assert_not_contains "$OUT" "cannot read"
}

# A quoted word keeps its parentheses and its colon: git's pathspec magic is not read as a
# path whatever way the word is quoted.
test_a_quoted_pathspec_magic_word_is_not_a_file_of_the_tree() {
  mkrepo
  must mkdir -p tools
  printf '#!/bin/sh\nexit 1\n' > tools/quiet.sh
  printf 'ok\n' > a.ts
  rule todo paths='**/*.ts' engine=script "detector=bash tools/quiet.sh {files} ':(glob)x' \":(top)y\""
  script_row todo
  exc_rebase
  exc_commit main
  must git checkout -q -b feat
  exc_tool_commit
  exc_gate
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_not_contains "$OUT" "detector file"
  assert_not_contains "$OUT" "cannot read"
}

# An absolute word is outside the repository, whatever the tree holds under the same name.
test_an_absolute_detector_word_is_not_a_file_of_the_tree() {
  mkrepo
  must mkdir -p tools
  printf '#!/bin/sh\nexit 1\n' > tools/quiet.sh
  printf 'one\n' > tools/other.sh
  printf 'ok\n' > a.ts
  rule todo paths='**/*.ts' engine=script 'detector=bash tools/quiet.sh {files} /tools/other.sh'
  script_row todo
  exc_rebase
  exc_commit main
  must git checkout -q -b feat
  printf 'two\n' > tools/other.sh
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_not_contains "$OUT" "detector file"
}

# The detector file of a rule is read the way the shell reads the command: quotes come off a
# word, a directory is no file, and a symlink is its target's content as well as its text.

# exc_change_tool <file>: change a tool the detector runs, on the branch, and run the gate.
exc_change_tool() {
  printf '#!/bin/sh\ntrue\n' > "$1"
  exc_rebase
  exc_commit feat
  exc_gate
}

test_a_quoted_detector_file_is_found() {
  exc_script_rule 'bash "tools/find.sh" {files}'
  exc_change_tool tools/find.sh
  assert_eq 1 "$STATUS" "double quotes: $OUT"
  assert_contains "$OUT" "  todo  detector file tools/find.sh changed"
}

test_a_single_quoted_detector_file_is_found() {
  exc_script_rule "bash 'tools/find.sh' {files}"
  exc_change_tool tools/find.sh
  assert_eq 1 "$STATUS" "single quotes: $OUT"
  assert_contains "$OUT" "  todo  detector file tools/find.sh changed"
}

test_a_quoted_detector_file_with_a_space_is_one_word() {
  exc_script_rule 'bash "my tools/find.sh" {files}'
  exc_change_tool "my tools/find.sh"
  assert_eq 1 "$STATUS" "quoted space: $OUT"
  assert_contains "$OUT" "  todo  detector file my tools/find.sh changed"
}

test_an_escaped_space_and_joined_quoted_parts_are_one_word() {
  exc_script_rule 'bash my\ tools/find.sh {files}'
  exc_change_tool "my tools/find.sh"
  assert_eq 1 "$STATUS" "escaped space: $OUT"
  assert_contains "$OUT" "  todo  detector file my tools/find.sh changed"
}

test_quote_parts_joined_into_one_word_name_the_file() {
  exc_script_rule 'bash "tools"/'"'"'find'"'"'.sh {files}'
  exc_change_tool tools/find.sh
  assert_eq 1 "$STATUS" "joined parts: $OUT"
  assert_contains "$OUT" "  todo  detector file tools/find.sh changed"
}

test_an_unchanged_quoted_detector_file_is_not_loosening() {
  exc_script_rule 'bash "tools/find.sh" {files}'
  printf 'x\n' > b.txt
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_not_contains "$OUT" "[loosened]"
}

# A backslash before a quote inside double quotes keeps the quote in the word: the file is
# named we"ird.sh.
test_a_backslash_in_double_quotes_escapes_only_what_the_shell_lets_it() {
  exc_script_rule 'bash "we\"ird.sh" {files}'
  printf '#!/bin/sh\nrg --with-filename --line-number --no-heading TODO "$@"\n' > 'we"ird.sh'
  exc_rebase
  exc_commit weird
  must git checkout -q main
  must git merge -q --ff-only feat
  must git checkout -q -b feat2
  exc_change_tool 'we"ird.sh'
  assert_eq 1 "$STATUS" "status: $OUT"
  assert_contains "$OUT" '  todo  detector file we"ird.sh changed'
}

# A word that is a directory names no file: a change under it is not a detector file change.
test_a_directory_word_is_not_a_detector_file() {
  exc_script_rule 'bash tools/find.sh {files} tools/'
  printf 'more\n' > tools/other.txt
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_not_contains "$OUT" "detector file"
}

test_a_directory_word_without_a_slash_is_not_a_detector_file() {
  exc_script_rule 'bash tools/find.sh {files} tools'
  printf 'more\n' > tools/other.txt
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_not_contains "$OUT" "detector file"
}

# ... while the file beside it is still judged.
test_a_directory_word_does_not_hide_the_script_beside_it() {
  exc_script_rule 'bash tools/find.sh {files} tools/'
  exc_change_tool tools/find.sh
  assert_eq 1 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "  todo  detector file tools/find.sh changed"
  assert_not_contains "$OUT" "detector file tools/ changed"
}

# exc_link_rule [chain]: main holds tools/find.sh as a symlink to real.sh and the rule runs it;
# with an argument the rule runs tools/entry.sh, a link to that link.
exc_link_rule() {
  local det=tools/find.sh
  mkrepo
  must mkdir -p tools
  printf '#!/bin/sh\nrg --with-filename --line-number --no-heading TODO "$@"\n' > tools/real.sh
  chmod +x tools/real.sh
  ln -s real.sh tools/find.sh
  if [ "$#" -gt 0 ]; then
    ln -s find.sh tools/entry.sh
    det=tools/entry.sh
  fi
  printf 'ok\n' > a.ts
  rule todo paths='**/*.ts' engine=script "detector=$det"
  script_row todo
  exc_rebase
  exc_commit main
  must git checkout -q -b feat
}

test_a_symlink_detector_whose_target_changed_is_loosening() {
  exc_link_rule
  exc_change_tool tools/real.sh
  assert_eq 1 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "  todo  detector file tools/find.sh changed"
}

# Only the link text changed: both targets hold the same bytes.
test_a_symlink_detector_pointed_elsewhere_is_loosening() {
  exc_link_rule
  cp tools/real.sh tools/other.sh
  must ln -sf other.sh tools/find.sh
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 1 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "  todo  detector file tools/find.sh changed"
}

# A link to a link: the end of the chain is what runs.
test_a_chain_of_symlinks_is_followed_to_the_file() {
  exc_link_rule chain
  exc_change_tool tools/real.sh
  assert_eq 1 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "  todo  detector file tools/entry.sh changed"
}

# A link into another directory, written with ..
test_a_symlink_into_another_directory_is_followed() {
  mkrepo
  must mkdir -p tools lib
  printf '#!/bin/sh\nrg --with-filename --line-number --no-heading TODO "$@"\n' > lib/real.sh
  chmod +x lib/real.sh
  ln -s ../lib/real.sh tools/find.sh
  printf 'ok\n' > a.ts
  rule todo paths='**/*.ts' engine=script detector=tools/find.sh
  script_row todo
  exc_rebase
  exc_commit main
  must git checkout -q -b feat
  exc_change_tool lib/real.sh
  assert_eq 1 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "  todo  detector file tools/find.sh changed"
}

# Neither the link nor its target moved: an unrelated commit loosens nothing (the old pin,
# now with the target read as well).
test_a_symlink_detector_with_an_unchanged_target_is_not_loosening() {
  exc_link_rule
  printf 'x\n' > b.txt
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_not_contains "$OUT" "[loosened]"
}

# A link that leaves the repository has only its text to compare.
test_a_symlink_to_an_absolute_path_is_judged_by_its_text() {
  mkrepo
  must mkdir -p tools
  ln -s /bin/true tools/find.sh
  printf 'ok\n' > a.ts
  rule todo paths='**/*.ts' engine=script detector=tools/find.sh
  script_row todo
  exc_rebase
  exc_commit main
  must git checkout -q -b feat
  printf 'x\n' > b.txt
  exc_rebase
  exc_commit feat
  exc_gate
  assert_eq 0 "$STATUS" "unchanged link: $OUT"
  must ln -sf /usr/bin/true tools/find.sh
  exc_rebase
  exc_commit relink
  exc_gate
  assert_eq 1 "$STATUS" "retargeted link: $OUT"
  assert_contains "$OUT" "  todo  detector file tools/find.sh changed"
}

# A link that loops cannot hang the gate.
test_a_symlink_loop_does_not_hang_the_gate() {
  local rc=0
  mkrepo
  must mkdir -p tools
  ln -s b.sh tools/a.sh
  ln -s a.sh tools/b.sh
  printf 'ok\n' > a.ts
  rule todo paths='**/*.ts' engine=script detector='true tools/a.sh {files}'
  script_row todo
  exc_rebase
  exc_commit main
  must git checkout -q -b feat
  printf 'x\n' > b.txt
  exc_rebase
  exc_commit feat
  with_timeout 30 "$G" check --ci --base main > "$TMP/loop.out" 2>&1 || rc=$?
  [ "$rc" -ne 124 ] || fail "the gate hung on a symlink loop"
  assert_eq 0 "$rc" "status: $(cat "$TMP/loop.out")"
}

# R32: the file a link leads to, unreadable at either side, is exit 2.
test_an_unreadable_symlink_target_at_the_base_is_exit_2() {
  exc_link_rule
  exc_tool_commit
  git_fails ls-tree tools/real.sh "$(git rev-parse main)"
  exc_gate
  assert_eq 2 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "simulated failure"
}

test_an_unreadable_symlink_target_at_head_is_exit_2() {
  exc_link_rule
  exc_tool_commit
  git_fails ls-tree tools/real.sh HEAD
  exc_gate
  assert_eq 2 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "simulated failure"
}
