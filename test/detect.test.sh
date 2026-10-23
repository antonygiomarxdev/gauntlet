# shellcheck shell=bash
# shellcheck disable=SC2153 # ROOT and STATUS are set by test/lib.sh
# Tests for lib/detect.sh: detector runs, output parsing through formats, and
# the exit-code rules of decision 8.

# detect_lib: source the libraries under test into the current test subshell.
detect_lib() {
  # shellcheck source=lib/core.sh
  . "$ROOT/lib/core.sh"
  # shellcheck source=lib/rules.sh
  . "$ROOT/lib/rules.sh"
  # shellcheck source=lib/paths.sh
  . "$ROOT/lib/paths.sh"
  # shellcheck source=lib/detect.sh
  . "$ROOT/lib/detect.sh"
}

test_rg_rows() {
  mkrepo
  detect_lib
  printf 'ok\nTODO here\n' > a.ts
  printf 'a.ts\n' > "$TMP/files.txt"
  rule todo
  run run_detector .gauntlet/rules/todo.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 0 "$STATUS" "status"
  assert_eq "$(printf 'todo\ta.ts\t2\tTODO here')" "$(cat "$TMP/out.tsv")" "rows"
}

test_path_with_space() {
  mkrepo
  detect_lib
  mkdir "my dir"
  printf 'TODO\n' > "my dir/ä b.ts"
  printf 'my dir/ä b.ts\n' > "$TMP/files.txt"
  rule todo
  run run_detector .gauntlet/rules/todo.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 0 "$STATUS" "status"
  assert_eq "$(printf 'todo\tmy dir/ä b.ts\t1\tTODO')" "$(cat "$TMP/out.tsv")" "rows"
}

test_apostrophe_in_path_is_quoted() {
  mkrepo
  detect_lib
  printf 'TODO\n' > "it's.ts"
  printf "it's.ts\n" > "$TMP/files.txt"
  rule todo
  run run_detector .gauntlet/rules/todo.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 0 "$STATUS" "status"
  assert_eq "$(printf "todo\tit's.ts\t1\tTODO")" "$(cat "$TMP/out.tsv")" "rows"
}

test_ast_grep_parse() {
  mkrepo
  detect_lib
  mkdir -p "$TMP/bin"
  printf '#!/bin/sh\ncat "%s"\nexit 1\n' "$ROOT/test/fixtures/ast-grep-github.txt" > "$TMP/bin/ast-grep"
  must chmod +x "$TMP/bin/ast-grep"
  PATH="$TMP/bin:$PATH"
  export PATH
  printf 'x.ts\n' > "$TMP/files.txt"
  rule silent-catch engine=ast-grep detector=.gauntlet/rules/silent-catch.yml
  run run_detector .gauntlet/rules/silent-catch.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 0 "$STATUS" "status"
  assert_eq "$(printf 'silent-catch\tx.ts\t1\tempty catch')" "$(cat "$TMP/out.tsv")" "rows"
}

test_exit1_empty_is_clean() {
  mkrepo
  detect_lib
  printf 'ok\n' > a.ts
  printf 'a.ts\n' > "$TMP/files.txt"
  rule todo
  run run_detector .gauntlet/rules/todo.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 0 "$STATUS" "status"
  assert_eq "" "$(cat "$TMP/out.tsv")" "rows"
}

test_empty_file_list_skips_detector() {
  mkrepo
  detect_lib
  : > "$TMP/files.txt"
  rule r "detector=touch ran.marker; true {files}"
  run run_detector .gauntlet/rules/r.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 0 "$STATUS" "status"
  if [ -e ran.marker ]; then fail "detector ran with an empty file list"; fi
}

test_unparseable_output_fails_closed() {
  mkrepo
  detect_lib
  rule r "detector=echo garbage; exit 1"
  run run_detector .gauntlet/rules/r.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 2 "$STATUS" "status"
  assert_contains "$OUT" "broken detector"
}

test_unmatched_line_fails_even_on_exit0() {
  mkrepo
  detect_lib
  rule r "detector=echo garbage; exit 0"
  run run_detector .gauntlet/rules/r.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 2 "$STATUS" "status"
  assert_contains "$OUT" "unparsed line: garbage"
}

test_project_format_no_runner_change() {
  mkrepo
  detect_lib
  mkdir -p .gauntlet/formats
  printf -- '---\nmatch: ^([^|]+)\\|([0-9]+)\\|(.*)$\npath: 1\nline: 2\nmessage: 3\n---\n' > .gauntlet/formats/mylint.md
  rule r engine=linter format=mylint "detector=printf 'a.ts|7|bad thing\\n'"
  run run_detector .gauntlet/rules/r.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 0 "$STATUS" "status"
  assert_eq "$(printf 'r\ta.ts\t7\tbad thing')" "$(cat "$TMP/out.tsv")" "rows"
}

test_ignore_drops_summary_line() {
  mkrepo
  detect_lib
  rule r engine=linter format=tsc "detector=printf 'a.ts(1,2): error TS2322: bad\\nFound 2 errors.\\nb.ts(3,4): error TS6133: unused\\n'"
  run run_detector .gauntlet/rules/r.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 0 "$STATUS" "status"
  assert_eq "$(printf 'r\ta.ts\t1\tTS2322: bad\nr\tb.ts\t3\tTS6133: unused')" "$(cat "$TMP/out.tsv")" "rows"
}

test_project_format_overrides_builtin() {
  mkrepo
  detect_lib
  mkdir -p .gauntlet/formats
  printf -- '---\nmatch: ^([^|]+)\\|([0-9]+)\\|(.*)$\npath: 1\nline: 2\nmessage: 3\n---\n' > .gauntlet/formats/path-line.md
  rule r engine=linter "detector=printf 'a.ts|7|bad thing\\n'"
  run run_detector .gauntlet/rules/r.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 0 "$STATUS" "status"
  assert_eq "$(printf 'r\ta.ts\t7\tbad thing')" "$(cat "$TMP/out.tsv")" "rows"
}

test_unknown_format_is_broken_setup() {
  mkrepo
  detect_lib
  rule r engine=linter format=nope detector=true
  run run_detector .gauntlet/rules/r.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 2 "$STATUS" "status"
  assert_contains "$OUT" "unknown format nope"
}

test_missing_tool() {
  mkrepo
  detect_lib
  printf 'a.ts\n' > "$TMP/files.txt"
  rule r engine=linter "detector=nosuchtool {files}"
  run run_detector .gauntlet/rules/r.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 2 "$STATUS" "status"
  assert_contains "$OUT" "missing tool nosuchtool"
}

test_output_filtered_to_inputs() {
  mkrepo
  detect_lib
  printf 'a.ts\n' > "$TMP/files.txt"
  rule r engine=linter "detector=printf 'a.ts:1:x\\nb.ts:2:y\\n'; true {files}"
  run run_detector .gauntlet/rules/r.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 0 "$STATUS" "status"
  assert_eq "$(printf 'r\ta.ts\t1\tx')" "$(cat "$TMP/out.tsv")" "rows"
}

test_whole_program_filtered_by_paths() {
  mkrepo
  detect_lib
  : > "$TMP/files.txt"
  rule r engine=linter paths='src/**' "detector=printf 'src/a.ts:1:x\\nlib/x.ts:2:y\\n'"
  run run_detector .gauntlet/rules/r.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 0 "$STATUS" "status"
  assert_eq "$(printf 'r\tsrc/a.ts\t1\tx')" "$(cat "$TMP/out.tsv")" "rows"
}
