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

test_column_output_keeps_message() {
  mkrepo
  detect_lib
  rule r engine=linter "detector=printf 'a.ts:7:3: msg\\n'"
  run run_detector .gauntlet/rules/r.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 0 "$STATUS" "status"
  assert_eq "$(printf 'r\ta.ts\t7\tmsg')" "$(cat "$TMP/out.tsv")" "rows"
}

test_no_match_survives_set_e() {
  mkrepo
  detect_lib
  printf 'ok\n' > a.ts
  printf 'a.ts\n' > "$TMP/files.txt"
  rule todo
  # A fresh bash, not a subshell: bash ignores errexit inside a subshell
  # started from a conditional context, and the test runner is one.
  OUT=$(bash -c '
    set -eu
    . "$1/core.sh"; . "$1/rules.sh"; . "$1/paths.sh"; . "$1/detect.sh"
    run_detector .gauntlet/rules/todo.md "$2" "$3"
    echo reached
  ' _ "$ROOT/lib" "$TMP/files.txt" "$TMP/out.tsv") || true
  assert_eq "reached" "$OUT" "continues after a clean run under set -e"
  assert_eq "" "$(cat "$TMP/out.tsv")" "rows"
}

test_large_file_list_is_batched() {
  mkrepo
  detect_lib
  mkdir -p src/gen
  : > "$TMP/files.txt"
  local i name
  for i in $(seq 1 4000); do
    name=$(printf 'src/gen/file_%04d_abcdefghijklmnopqrstuv.ts' "$i")
    printf 'TODO\n' > "$name"
    printf '%s\n' "$name" >> "$TMP/files.txt"
  done
  rule todo
  run run_detector .gauntlet/rules/todo.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 0 "$STATUS" "status"
  assert_eq 4000 "$(wc -l < "$TMP/out.tsv" | tr -d ' ')" "rows"
}

test_detector_stderr_is_reported() {
  mkrepo
  detect_lib
  printf 'a.ts\n' > "$TMP/files.txt"
  rule r "detector=rg '[' {files}"
  run run_detector .gauntlet/rules/r.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 2 "$STATUS" "status"
  assert_contains "$OUT" "regex parse error"
}

test_ast_grep_command_line() {
  mkrepo
  detect_lib
  mkdir -p "$TMP/bin"
  printf '#!/bin/sh\necho "$*" > "%s/args"\n' "$TMP" > "$TMP/bin/ast-grep"
  must chmod +x "$TMP/bin/ast-grep"
  PATH="$TMP/bin:$PATH"
  export PATH
  printf 'x.ts\n' > "$TMP/files.txt"
  rule silent-catch engine=ast-grep detector=.gauntlet/rules/silent-catch.yml
  run run_detector .gauntlet/rules/silent-catch.md "$TMP/files.txt" "$TMP/out.tsv"
  local args
  args=$(cat "$TMP/args")
  assert_contains "$args" "scan --rule"
  assert_contains "$args" "--format github"
  assert_contains "$args" "x.ts"
}

test_missing_rg_prints_install_hint() {
  mkrepo
  detect_lib
  mkdir -p "$TMP/bin"
  printf '#!/bin/sh\nexit 127\n' > "$TMP/bin/rg"
  must chmod +x "$TMP/bin/rg"
  PATH="$TMP/bin:$PATH"
  export PATH
  printf 'a.ts\n' > "$TMP/files.txt"
  rule todo
  run run_detector .gauntlet/rules/todo.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 2 "$STATUS" "status"
  assert_contains "$OUT" "missing tool rg"
  assert_contains "$OUT" "brew install ripgrep ast-grep"
}

test_unknown_engine_is_broken() {
  mkrepo
  detect_lib
  printf 'a.ts\n' > "$TMP/files.txt"
  rule r engine=bogus detector=true
  run run_detector .gauntlet/rules/r.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 2 "$STATUS" "status"
  assert_contains "$OUT" "unknown engine bogus"
}

test_uncompilable_format_is_broken() {
  mkrepo
  detect_lib
  mkdir -p .gauntlet/formats
  printf -- '---\nmatch: (\npath: 1\nline: 1\n---\n' > .gauntlet/formats/bad.md
  rule r engine=linter format=bad "detector=printf 'a:1\\n'"
  run run_detector .gauntlet/rules/r.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 2 "$STATUS" "status"
  assert_contains "$OUT" "does not compile"
}

test_batched_command_portable_under_compat32() {
  mkrepo
  printf 'TODO\n' > "my a.ts"
  printf 'TODO\n' > "my b.ts"
  printf 'my a.ts\nmy b.ts\n' > "$TMP/files.txt"
  rule todo
  # compat32 selects the bash 3.2 quoting rules that broke argument-position
  # ${var//pat/"rep"} on bash 4.2 and older. Run in a fresh bash so errexit is
  # active, as in bin/gauntlet.
  OUT=$(bash -c '
    shopt -s compat32 2>/dev/null || true
    set -eu
    . "$1/core.sh"; . "$1/rules.sh"; . "$1/paths.sh"; . "$1/detect.sh"
    run_detector .gauntlet/rules/todo.md "$2" "$3"
    LC_ALL=C sort "$3"
  ' _ "$ROOT/lib" "$TMP/files.txt" "$TMP/out.tsv") || fail "run failed: $OUT"
  assert_eq "$(printf 'todo\tmy a.ts\t1\tTODO\ntodo\tmy b.ts\t1\tTODO')" "$OUT" "rows"
}



test_command_length_counts_against_budget() {
  mkrepo
  detect_lib
  mkdir -p "$TMP/bin"
  # Stub records the byte total of its argv on each run.
  # shellcheck disable=SC2016 # the stub script body is meant to stay literal
  printf '#!/bin/bash\nt=0\nfor a in "$@"; do t=$((t + ${#a})); done\necho "$t" >> "%s/sizes"\n' "$TMP" > "$TMP/bin/ztool"
  must chmod +x "$TMP/bin/ztool"
  PATH="$TMP/bin:$PATH"
  export PATH
  local pad name i
  pad=$(printf 'x%.0s' $(seq 1 99000))
  name=$(printf 'y%.0s' $(seq 1 190))
  : > "$TMP/files.txt"
  for i in 1 2 3 4 5 6; do printf 'f_%04d_%s.ts\n' "$i" "$name" >> "$TMP/files.txt"; done
  rule r engine=linter "detector=ztool {files} $pad"
  run run_detector .gauntlet/rules/r.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 0 "$STATUS" "status"
  local max
  max=$(sort -n "$TMP/sizes" | tail -1)
  if [ "$max" -gt 100000 ]; then fail "one command was $max bytes, over 100000"; fi
}
