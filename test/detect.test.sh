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

# Every row of a selected path is kept, however many a file has; a path the rule's paths do
# not select loses all of them.
test_whole_program_rows_keep_every_row_of_a_selected_path() {
  mkrepo
  detect_lib
  : > "$TMP/files.txt"
  rule r engine=linter paths='src/**' exclude='src/gen/**' "detector=printf 'src/a.ts:1:x\\nsrc/a.ts:2:y\\nsrc/a.ts:2:y\\nsrc/gen/g.ts:1:z\\nlib/x.ts:2:w\\nsrc/b.ts:7:v\\n'"
  run run_detector .gauntlet/rules/r.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_eq "$(printf 'r\tsrc/a.ts\t1\tx\nr\tsrc/a.ts\t2\ty\nr\tsrc/a.ts\t2\ty\nr\tsrc/b.ts\t7\tv')" "$(cat "$TMP/out.tsv")" "rows"
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
  assert_contains "$args" "--error"
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

# R30 hardening. utf8_locale: print a UTF-8 locale this machine has, or fail.
utf8_locale() {
  local l
  for l in en_US.UTF-8 en_US.utf8 C.UTF-8 C.utf8; do
    if [ "$(LC_ALL=$l locale charmap 2>/dev/null)" = UTF-8 ]; then
      printf '%s\n' "$l"
      return 0
    fi
  done
  return 1
}

# sed runs in the C locale: in a UTF-8 locale it does not match a byte that is not valid
# UTF-8, so a Latin-1 file name or a Latin-1 line in a matched file was "an unparsed line".
test_invalid_utf8_in_names_and_lines_parses_in_a_utf8_locale() {
  local loc name
  loc=$(utf8_locale) || { skip "no UTF-8 locale installed"; return 77; }
  mkrepo
  rule todo
  name=$(printf 'caf\351.ts')
  printf 'TODO a\n' > "$name"
  printf 'TODO b \351\n' > plain.ts
  must git add -A
  run env LC_ALL="$loc" "$G" baseline
  assert_eq 0 "$STATUS" "baseline in $loc: $OUT"
  assert_eq "$(printf 'todo\tcaf\351.ts\tTODO a\t1\ntodo\tplain.ts\tTODO b \351\t1')" "$(cat .gauntlet/baseline.tsv)" "rows"
}

# A tracked name that starts with - is a file, not an option.
test_dash_names_reach_the_detector_as_files() {
  mkrepo
  detect_lib
  printf 'TODO x\n' > ./-x.txt
  printf 'TODO z\n' > ./-
  printf 'TODO y\n' > ok.ts
  printf -- '-x.txt\n-\nok.ts\n' > "$TMP/files.txt"
  rule todo
  run run_detector .gauntlet/rules/todo.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 0 "$STATUS" "rg {files}: $OUT"
  assert_eq "$(printf 'todo\t-\t1\tTODO z\ntodo\t-x.txt\t1\tTODO x\ntodo\tok.ts\t1\tTODO y')" "$(LC_ALL=C sort "$TMP/out.tsv")" "rg rows"
  rule lint engine=linter "detector=grep -Hn TODO {files}"
  run run_detector .gauntlet/rules/lint.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 0 "$STATUS" "linter {files}: $OUT"
  assert_eq "$(printf 'lint\t-\t1\tTODO z\nlint\t-x.txt\t1\tTODO x\nlint\tok.ts\t1\tTODO y')" "$(LC_ALL=C sort "$TMP/out.tsv")" "linter rows"
}

# A tool that joins the working directory to the ./-name it was given prints <root>/./-name. The
# repo root comes off first, then the ./, or the row is not in the file list and is dropped.
test_root_dot_slash_paths_from_a_tool_are_normalised() {
  mkrepo
  detect_lib
  printf 'TODO x\n' > ./-x.ts
  printf 'TODO y\n' > y.ts
  printf -- '-x.ts\ny.ts\n' > "$TMP/files.txt"
  rule r engine=linter "detector=for f in {files}; do printf '%s/%s:1:x\\n' \"\$PWD\" \"\$f\"; done"
  run run_detector .gauntlet/rules/r.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_eq "$(printf 'r\t-x.ts\t1\tx\nr\ty.ts\t1\tx')" "$(LC_ALL=C sort "$TMP/out.tsv")" "both rows"
}

# A NUL byte in the detector's output is dropped, on purpose and without bash's warning
# ("ignored null byte in input"), so the row is the same text on every shell and awk.
test_a_nul_byte_in_detector_output_is_dropped_quietly() {
  mkrepo
  detect_lib
  printf 'x\n' > a.ts
  printf 'a.ts\n' > "$TMP/files.txt"
  rule r engine=linter "detector=printf 'a.ts:1:x\\0y\\n'"
  run run_detector .gauntlet/rules/r.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_not_contains "$OUT" "null byte"
  assert_eq "$(printf 'r\ta.ts\t1\txy')" "$(cat "$TMP/out.tsv")" "the row without the NUL"
}

test_dash_names_are_measured_by_the_gates() {
  mkrepo
  printf 'TODO x\n' > ./-x.txt
  printf 'TODO z\n' > ./-
  rule todo
  rule prog "detector=rg --no-ignore --with-filename --line-number --no-heading TODO ."
  must git add -A
  run "$G" baseline
  assert_eq 0 "$STATUS" "baseline: $OUT"
  assert_eq "$(printf 'prog\t-\tTODO z\t1\nprog\t-x.txt\tTODO x\t1\ntodo\t-\tTODO z\t1\ntodo\t-x.txt\tTODO x\t1')" "$(cat .gauntlet/baseline.tsv)" "rows"
}

# A stage that crashes is a broken detector whatever the stages after it say: the filter
# at the end (grep, rg) exits 1 on empty input, which alone would read as "no matches".
test_pipeline_failure_in_the_first_stage_is_a_broken_detector() {
  mkrepo
  detect_lib
  : > "$TMP/files.txt"
  rule r engine=linter "detector=sh -c 'echo boom >&2; exit 2' | grep -v nothing-here"
  run run_detector .gauntlet/rules/r.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 2 "$STATUS" "status"
  assert_contains "$OUT" "broken detector: r: exit 2"
  assert_contains "$OUT" "boom"
}

test_pipeline_with_a_missing_first_tool_names_the_tool() {
  mkrepo
  detect_lib
  : > "$TMP/files.txt"
  rule r engine=linter "detector=nosuchtool-gauntlet | grep -v nomatch"
  run run_detector .gauntlet/rules/r.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 2 "$STATUS" "status"
  assert_contains "$OUT" "missing tool nosuchtool-gauntlet"
}

test_pipeline_crash_in_a_middle_stage_before_a_filter_is_a_broken_detector() {
  mkrepo
  detect_lib
  printf 'TODO here\n' > a.ts
  printf 'a.ts\n' > "$TMP/files.txt"
  rule r engine=linter "detector=rg --with-filename --line-number --no-heading TODO {files} | sh -c 'cat >/dev/null; echo mid-boom >&2; exit 3' | grep -v nomatch"
  run run_detector .gauntlet/rules/r.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 2 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "broken detector: r: exit 3"
  assert_contains "$OUT" "mid-boom"
}

test_pipeline_with_a_bad_rg_flag_before_a_filter_is_a_broken_detector() {
  mkrepo
  detect_lib
  printf 'TODO here\n' > a.ts
  printf 'a.ts\n' > "$TMP/files.txt"
  rule r engine=linter "detector=rg --no-such-flag {files} | rg zzzz"
  run run_detector .gauntlet/rules/r.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 2 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "broken detector: r: exit 2"
  assert_contains "$OUT" "no-such-flag"
}

# A stage cut off because a later stage closed the pipe early (head) is not a failure: grep
# is killed by SIGPIPE (141) and the rows head let through are the rows of the rule. The file
# is far bigger than a pipe buffer, so grep is still writing when head exits.
test_pipeline_cut_off_by_head_is_not_a_failure() {
  # With SIGPIPE ignored (a job started from a Python or node parent that did not restore it) grep
  # gets a write error and exits 2 instead of dying with 141: another story, not this one.
  [ "$(bash -c 'kill -PIPE $$; echo alive' 2> /dev/null)" != alive ] || { skip "SIGPIPE is ignored here"; return 77; }
  mkrepo
  detect_lib
  awk 'BEGIN { for (i = 1; i <= 30000; i++) print "TODO line " i }' > big.ts
  printf 'big.ts\n' > "$TMP/files.txt"
  rule r engine=linter "detector=grep -Hn TODO {files} | head -n 1"
  run run_detector .gauntlet/rules/r.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_eq "$(printf 'r\tbig.ts\t1\tTODO line 1')" "$(cat "$TMP/out.tsv")" "the row head let through"
}

# Exit 1 from a stage still means "no matches", and rows still come through a pipe.
test_pipeline_keeps_exit_1_as_no_matches_and_passes_rows() {
  mkrepo
  detect_lib
  printf 'TODO here\n' > a.ts
  printf 'a.ts\n' > "$TMP/files.txt"
  rule none engine=linter "detector=rg --with-filename --line-number --no-heading NOPE {files} | cat"
  run run_detector .gauntlet/rules/none.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 0 "$STATUS" "no matches through a pipe: $OUT"
  assert_eq "" "$(cat "$TMP/out.tsv")" "no rows"
  rule some engine=linter "detector=rg --with-filename --line-number --no-heading TODO {files} | cat"
  run run_detector .gauntlet/rules/some.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 0 "$STATUS" "matches through a pipe: $OUT"
  assert_eq "$(printf 'some\ta.ts\t1\tTODO here')" "$(cat "$TMP/out.tsv")" "rows"
  rule last engine=linter "detector=rg --with-filename --line-number --no-heading TODO {files} | rg zzzz"
  run run_detector .gauntlet/rules/last.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 0 "$STATUS" "rg exit 1 as the last stage is no matches: $OUT"
  assert_eq "" "$(cat "$TMP/out.tsv")" "no rows"
  rule fail engine=linter "detector=rg --with-filename --line-number --no-heading NOPE {files} | sh -c 'cat; exit 2'"
  run run_detector .gauntlet/rules/fail.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 2 "$STATUS" "a failing later stage after an exit-1 first stage: $OUT"
}

# rg names a binary file it matched on stdout. It is not a violation of anything.
test_binary_file_match_is_ignored() {
  mkrepo
  detect_lib
  printf 'TODO bin\0stuff\n' > data.bin
  printf 'TODO y\n' > ok.ts
  printf 'data.bin\nok.ts\n' > "$TMP/files.txt"
  rule todo
  run run_detector .gauntlet/rules/todo.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_eq "$(printf 'todo\tok.ts\t1\tTODO y')" "$(cat "$TMP/out.tsv")" "rows"
}

test_binary_file_match_does_not_fail_the_gate_or_count() {
  mkrepo
  printf 'TODO bin\0stuff\n' > data.bin
  printf 'TODO y\n' > ok.ts
  rule todo
  must git add -A
  run "$G" baseline
  assert_eq 0 "$STATUS" "baseline: $OUT"
  assert_eq "$(printf 'todo\tok.ts\tTODO y\t1')" "$(cat .gauntlet/baseline.tsv)" "rows"
}

# --error: ast-grep reports a rule whose severity is hint (the default) or off only
# when told to; without it such a rule found nothing and the gate passed.
test_ast_grep_rule_without_a_severity_is_still_counted() {
  command -v ast-grep > /dev/null 2>&1 || { skip "ast-grep not installed"; return 77; }
  mkrepo
  printf 'try { a() } catch (e) {}\n' > x.ts
  # shellcheck disable=SC2016 # the ast-grep metavariables are meant to stay literal
  printf 'id: silent-catch\nlanguage: TypeScript\nrule:\n  pattern: try { $$$A } catch ($E) {}\nmessage: empty catch\n' > .gauntlet/rules/silent-catch.yml
  rule silent-catch engine=ast-grep detector=.gauntlet/rules/silent-catch.yml
  must git add -A
  run "$G" baseline
  assert_eq 0 "$STATUS" "baseline: $OUT"
  assert_contains "$(cat .gauntlet/baseline.tsv)" "silent-catch	x.ts	"
}

# detect_scan hands the paths to the detector in batches. Every name reaches it as one
# word, whatever it holds: the detector here prints each word it is given, and a project
# format reads those lines back, so the path survives the quoting, the ./ prefix for a
# leading dash and the strip of that prefix. A colon is in the list because path-line
# cannot read one (R12); this format can.
test_special_names_reach_the_detector_intact() {
  mkrepo
  detect_lib
  mkdir -p .gauntlet/formats
  printf -- '---\nmatch: ^(.*)\\|([0-9]+)\\|(.*)$\npath: 1\nline: 2\nmessage: 3\n---\n' > .gauntlet/formats/words.md
  # One name per line; none holds a newline (R31).
  cat > "$TMP/names.txt" <<'NAMES'
plain.ts
sp ace.ts
star*.ts
what?.ts
br[ack]et.ts
[x].ts
-lead.ts
-
--
ünï côde.ts
back\slash.ts
trail\
colon:name.ts
a:1:b.ts
it's.ts
say "hi".ts
dollar$HOME.ts
tick`id`.ts
amp&semi;.ts
{files}.ts
~tilde.ts
#hash.ts
 leading space.ts
trailing space.ts 
NAMES
  rule words engine=linter format=words "detector=printf '%s|1|x\\n' {files}"
  run run_detector .gauntlet/rules/words.md "$TMP/names.txt" "$TMP/out.tsv"
  assert_eq 0 "$STATUS" "status: $OUT"
  want=$(sed 's/^/words\t/; s/$/\t1\tx/' "$TMP/names.txt")
  assert_eq "$want" "$(cat "$TMP/out.tsv")" "rows"
}

# The same names, and files whose content is odd, through rg and the fingerprint
# reader. The names are the ones rg can print back in path-line form.
test_special_names_and_contents_baseline_rows() {
  mkrepo
  printf 'TODO plain\n' > plain.ts
  printf 'TODO space\n' > "sp ace.ts"
  printf 'TODO star\n' > 'star*.ts'
  printf 'TODO what\n' > 'what?.ts'
  printf 'TODO bracket\n' > 'br[ack]et.ts'
  printf 'TODO lead\n' > ./-lead.ts
  printf 'TODO dash\n' > ./-
  printf 'TODO uni\n' > "ünï côde.ts"
  printf 'TODO back\n' > 'back\slash.ts'
  printf 'TODO nolf' > nolf.ts
  : > empty.ts
  printf 'TODO crlf\r\nok\r\nTODO two\r\n' > crlf.ts
  rule todo
  must git add -A
  run "$G" baseline
  assert_eq 0 "$STATUS" "baseline: $OUT"
  want=$(printf '%s\n' \
    "todo	-	TODO dash	1" \
    "todo	-lead.ts	TODO lead	1" \
    "todo	back\\slash.ts	TODO back	1" \
    "todo	br[ack]et.ts	TODO bracket	1" \
    "todo	crlf.ts	TODO crlf	1" \
    "todo	crlf.ts	TODO two	1" \
    "todo	nolf.ts	TODO nolf	1" \
    "todo	plain.ts	TODO plain	1" \
    "todo	sp ace.ts	TODO space	1" \
    "todo	star*.ts	TODO star	1" \
    "todo	what?.ts	TODO what	1" \
    "todo	ünï côde.ts	TODO uni	1")
  assert_eq "$want" "$(cat .gauntlet/baseline.tsv)" "rows"
}

test_files_list_without_a_trailing_newline_keeps_the_last_path() {
  mkrepo
  detect_lib
  printf 'TODO a\n' > a.ts
  printf 'TODO b\n' > b.ts
  printf 'a.ts\nb.ts' > "$TMP/files.txt"
  rule todo
  run run_detector .gauntlet/rules/todo.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_eq "$(printf 'todo\ta.ts\t1\tTODO a\ntodo\tb.ts\t1\tTODO b')" "$(LC_ALL=C sort "$TMP/out.tsv")" "rows"
}

# The structure of the batching, not its speed: one awk pass quotes the whole list, so the
# cost does not grow with a bash loop over the paths (20k files took 14.6 s that way).
# A counting awk on PATH sees every awk that detect_scan starts.
test_batching_quotes_the_list_in_one_awk_pass() {
  mkrepo
  detect_lib
  mkdir -p "$TMP/bin"
  real_awk=$(command -v awk)
  printf '#!/bin/sh\necho x >> "%s/awk.count"\nexec "%s" "$@"\n' "$TMP" "$real_awk" > "$TMP/bin/awk"
  must chmod +x "$TMP/bin/awk"
  PATH="$TMP/bin:$PATH"
  export PATH
  local i
  : > "$TMP/files.txt"
  for i in $(seq 1 3000); do printf 'src/gen/file_%04d_abcdefghijklmnopqrstuv.ts\n' "$i" >> "$TMP/files.txt"; done
  : > "$TMP/err"
  : > "$TMP/awk.count"
  : > "$TMP/runs"
  DETECT_RAW=
  detect_scan "$PWD" "sh -c 'echo run >> \"$TMP/runs\"' ignored {files}" r "$TMP/err" "$TMP/files.txt"
  assert_eq 1 "$(wc -l < "$TMP/awk.count" | tr -d ' ')" "awk processes for 3000 paths"
  runs=$(wc -l < "$TMP/runs" | tr -d ' ')
  if [ "$runs" -lt 2 ] || [ "$runs" -gt 8 ]; then fail "3000 paths ran the detector $runs times, expected a few batches"; fi
  : > "$TMP/awk.count"
  printf 'a.ts\nb.ts\n' > "$TMP/files.txt"
  detect_scan "$PWD" "sh -c 'echo run >> \"$TMP/runs\"' ignored {files}" r "$TMP/err" "$TMP/files.txt"
  assert_eq 1 "$(wc -l < "$TMP/awk.count" | tr -d ' ')" "awk processes for 2 paths"
}

# sed reads \10 as \1 followed by 0, so a capture group above 9 cannot be named. A format
# that does so would never find a path: it is refused, naming the format and the key.
# group_format <path> <line> <message>: a format whose match has ten groups; the last
# three are the file, the line number and the message.
group_format() {
  mkdir -p .gauntlet/formats
  printf -- '---\nmatch: ^(a)(b)(c)(d)(e)(f)(g)([^|]+)\\|([0-9]+)\\|(.*)$\npath: %s\nline: %s\nmessage: %s\n---\n' "$1" "$2" "$3" > .gauntlet/formats/ten.md
}

test_format_groups_up_to_9_are_read() {
  mkrepo
  detect_lib
  mkdir -p .gauntlet/formats
  printf -- '---\nmatch: ^(a)(b)(c)(d)(e)(f)(g)([^|]+)\\|([0-9]+)\\|.*$\npath: 8\nline: 9\n---\n' > .gauntlet/formats/nine.md
  rule r engine=linter format=nine "detector=printf 'abcdefgX.ts|3|bad\\n'"
  : > "$TMP/files.txt"
  run run_detector .gauntlet/rules/r.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_eq "$(printf 'r\tX.ts\t3\t')" "$(cat "$TMP/out.tsv")" "rows"
}

test_format_groups_above_9_are_refused_naming_the_key() {
  mkrepo
  detect_lib
  rule r engine=linter format=ten "detector=printf 'abcdefgX.ts|3|bad\\n'"
  : > "$TMP/files.txt"
  group_format 10 2 3
  run run_detector .gauntlet/rules/r.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 2 "$STATUS" "path: 10"
  assert_contains "$OUT" "format ten: path is group 10; use a group from 0 to 9"
  group_format 8 10 3
  run run_detector .gauntlet/rules/r.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 2 "$STATUS" "line: 10"
  assert_contains "$OUT" "format ten: line is group 10; use a group from 0 to 9"
  group_format 8 9 12
  run run_detector .gauntlet/rules/r.md "$TMP/files.txt" "$TMP/out.tsv"
  assert_eq 2 "$STATUS" "message: 12"
  assert_contains "$OUT" "format ten: message is group 12; use a group from 0 to 9"
}

test_gates_refuse_a_format_with_a_group_above_9() {
  mkrepo
  group_format 10 11 12
  rule r engine=linter format=ten "detector=printf 'abcdefgX.ts|3|bad\\n'"
  cases_of r 'x'
  printf 'x\n' > X.ts
  must git add -A
  run "$G" baseline
  assert_eq 2 "$STATUS" "baseline: $OUT"
  assert_contains "$OUT" "format ten: path is group 10; use a group from 0 to 9"
  run "$G" test-rules
  assert_eq 2 "$STATUS" "test-rules: $OUT"
  assert_contains "$OUT" "format ten: path is group 10; use a group from 0 to 9"
}

# The batch budget on its exact edge (guards; they fail only if the edge moves). A word of n
# characters joins a batch when what the batch holds plus n is at most the limit; the list is
# measured after the command text is taken off the budget. 'a' quotes to 3 characters and takes
# 4 with its space.
test_batch_budget_edge_is_inclusive() {
  detect_lib
  printf 'a\nb\nc\n' > "$TMP/in.txt"
  assert_eq "$(printf " 'a' 'b'\n 'c'")" "$(detect_quote_batches 7 < "$TMP/in.txt")" "limit 7: 4 + 3 fits, 8 + 3 does not"
  assert_eq "$(printf " 'a'\n 'b'\n 'c'")" "$(detect_quote_batches 6 < "$TMP/in.txt")" "limit 6: 4 + 3 does not fit"
}

test_batch_budget_counts_the_command_text() {
  mkrepo
  detect_lib
  printf 'a\nb\nc\n' > "$TMP/files.txt"
  : > "$TMP/err"
  DETECT_RAW=
  # ': {files}' is 10 characters, so a budget of 17 leaves 7 for the list.
  DETECT_BATCH_CHARS=17
  detect_scan "$PWD" ": {files}" r "$TMP/err" "$TMP/files.txt"
  assert_eq "$(printf " 'a' 'b'\n 'c'")" "$(cat "$TMP/err.batches")" "batches under a budget of 17 for a 10 character command"
}
