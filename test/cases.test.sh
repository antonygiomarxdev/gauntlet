# shellcheck shell=bash
# shellcheck disable=SC2153 # ROOT, G and STATUS are set by test/lib.sh
# Tests for lib/cases.sh: each rule's bad and good cases, and each output
# format's sample against its expected block, through run_rule_tests and
# bin/gauntlet test-rules.

# cases_lib: source the libraries under test into the current test subshell.
cases_lib() {
  # shellcheck source=lib/core.sh
  . "$ROOT/lib/core.sh"
  # shellcheck source=lib/rules.sh
  . "$ROOT/lib/rules.sh"
  # shellcheck source=lib/paths.sh
  . "$ROOT/lib/paths.sh"
  # shellcheck source=lib/detect.sh
  . "$ROOT/lib/detect.sh"
  # shellcheck source=lib/cases.sh
  . "$ROOT/lib/cases.sh"
}

test_bad_flagged_good_clean_passes() {
  mkrepo
  cases_lib
  rule todo
  printf 'TODO\n' > .gauntlet/rules/todo.bad.ts
  printf 'ok\n' > .gauntlet/rules/todo.good.ts
  run run_rule_tests "$TMP/repo"
  assert_eq 0 "$STATUS" "status"
  assert_eq "" "$OUT" "output"
}

test_bad_not_flagged_fails() {
  mkrepo
  cases_lib
  rule todo
  printf 'ok\n' > .gauntlet/rules/todo.bad.ts
  run run_rule_tests "$TMP/repo"
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "  todo  todo.bad.ts  bad case not flagged"
}

test_good_flagged_fails() {
  mkrepo
  cases_lib
  rule todo
  printf 'TODO\n' > .gauntlet/rules/todo.bad.ts
  printf 'TODO\n' > .gauntlet/rules/todo.good.ts
  run run_rule_tests "$TMP/repo"
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "  todo  todo.good.ts  good case flagged"
}

test_directory_case() {
  mkrepo
  cases_lib
  rule todo
  mkdir -p .gauntlet/rules/todo.bad
  printf 'ok\n' > .gauntlet/rules/todo.bad/a.ts
  printf 'TODO\n' > .gauntlet/rules/todo.bad/b.ts
  run run_rule_tests "$TMP/repo"
  assert_eq 0 "$STATUS" "status"
}

test_case_name_with_space() {
  mkrepo
  cases_lib
  rule todo
  printf 'TODO\n' > ".gauntlet/rules/todo.bad case.ts"
  run run_rule_tests "$TMP/repo"
  assert_eq 0 "$STATUS" "status"
}

test_paths_ignored_for_cases() {
  mkrepo
  cases_lib
  rule todo paths='src/**'
  printf 'TODO\n' > .gauntlet/rules/todo.bad.ts
  run run_rule_tests "$TMP/repo"
  assert_eq 0 "$STATUS" "status"
}

test_rule_without_cases_fails() {
  mkrepo
  cases_lib
  rule todo
  run run_rule_tests "$TMP/repo"
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "no cases"
}

test_format_sample_matches_expected() {
  mkrepo
  cases_lib
  mkdir -p .gauntlet/formats
  # The built-in formats must pass; a project format whose expected differs must fail.
  # shellcheck disable=SC2016 # the fence markers are literal text, not expansions
  printf -- '---\nmatch: ^([^:]+):([0-9]+): (.*)$\npath: 1\nline: 2\nmessage: 3\n---\n```sample\na.ts:1: bad\n```\n```expected\na.ts\t1\twrong\n```\n' > .gauntlet/formats/mine.md
  run run_rule_tests "$TMP/repo"
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "  mine  expected"
  assert_not_contains "$OUT" "  path-line  "
  assert_not_contains "$OUT" "  github  "
  assert_not_contains "$OUT" "  tsc  "
}

test_builtin_formats_pass() {
  mkrepo
  cases_lib
  run run_rule_tests "$TMP/repo"
  assert_eq 0 "$STATUS" "status"
  assert_eq "" "$OUT" "output"
}

test_format_without_cases_fails() {
  mkrepo
  cases_lib
  mkdir -p .gauntlet/formats
  printf -- '---\nmatch: ^([^:]+):([0-9]+): (.*)$\npath: 1\nline: 2\nmessage: 3\n---\n' > .gauntlet/formats/bare.md
  run run_rule_tests "$TMP/repo"
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "  bare  sample  no cases"
}

test_bin_test_rules_passes() {
  mkrepo
  rule todo
  printf 'TODO\n' > .gauntlet/rules/todo.bad.ts
  printf 'ok\n' > .gauntlet/rules/todo.good.ts
  run "$G" test-rules
  assert_eq 0 "$STATUS" "exit status"
}

test_bin_test_rules_fails() {
  mkrepo
  rule todo
  printf 'ok\n' > .gauntlet/rules/todo.bad.ts
  run "$G" test-rules
  assert_eq 1 "$STATUS" "exit status"
  assert_contains "$OUT" "bad case not flagged"
}

test_markdown_case_file_is_not_a_rule() {
  mkrepo
  cases_lib
  rule mdr
  printf 'TODO\n' > .gauntlet/rules/mdr.bad.md
  run run_rule_tests "$TMP/repo"
  assert_eq 0 "$STATUS" "status"
  assert_eq "" "$OUT" "output"
}

test_project_format_shadowing_builtin_is_tested() {
  mkrepo
  cases_lib
  mkdir -p .gauntlet/formats
  # Same name as the built-in path-line: the project file is the one tested.
  # shellcheck disable=SC2016 # fence markers are literal text
  printf -- '---\nmatch: ^([^:]+):([0-9]+): (.*)$\npath: 1\nline: 2\nmessage: 3\n---\n```sample\na.ts:1: bad\n```\n```expected\na.ts\t1\twrong\n```\n' > .gauntlet/formats/path-line.md
  run run_rule_tests "$TMP/repo"
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "  path-line  expected"
}

test_sample_that_does_not_parse_fails() {
  mkrepo
  cases_lib
  mkdir -p .gauntlet/formats
  # shellcheck disable=SC2016 # fence markers are literal text
  printf -- '---\nmatch: ^([^:]+):([0-9]+): (.*)$\npath: 1\nline: 2\nmessage: 3\n---\n```sample\nnot a match\n```\n```expected\na.ts\t1\tx\n```\n' > .gauntlet/formats/unparsed.md
  run run_rule_tests "$TMP/repo"
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "  unparsed  sample  does not parse"
}

test_bad_directory_without_violation_fails() {
  mkrepo
  cases_lib
  rule todo
  mkdir -p .gauntlet/rules/todo.bad
  printf 'ok\n' > .gauntlet/rules/todo.bad/a.ts
  printf 'ok\n' > .gauntlet/rules/todo.bad/b.ts
  run run_rule_tests "$TMP/repo"
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "  todo  todo.bad  bad case not flagged"
}

test_broken_detector_exits_2_and_cleans_up() {
  mkrepo
  rule r engine=linter "detector=echo garbage; exit 0"
  printf 'x\n' > .gauntlet/rules/r.bad.ts
  mkdir -p "$TMP/tmpdir"
  TMPDIR="$TMP/tmpdir"
  export TMPDIR
  run "$G" test-rules
  assert_eq 2 "$STATUS" "status"
  assert_contains "$OUT" "broken detector"
  assert_eq "" "$(ls -A "$TMP/tmpdir")" "leftover temp dirs"
}
