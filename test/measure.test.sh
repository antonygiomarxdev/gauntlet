# shellcheck shell=bash
# shellcheck disable=SC2153 # ROOT, G and STATUS are set by test/lib.sh
# Tests for lib/measure.sh: fingerprints survive line shifts, reformatting and
# CRLF, duplicates are counted, and gauntlet baseline writes the measured TSV.
# Rules use paths **/*.ts so a rule file never matches its own detector text.

# measure_lib: source the libraries under test into the current test subshell.
measure_lib() {
  # shellcheck source=lib/core.sh
  . "$ROOT/lib/core.sh"
  # shellcheck source=lib/rules.sh
  . "$ROOT/lib/rules.sh"
  # shellcheck source=lib/paths.sh
  . "$ROOT/lib/paths.sh"
  # shellcheck source=lib/detect.sh
  . "$ROOT/lib/detect.sh"
  # shellcheck source=lib/measure.sh
  . "$ROOT/lib/measure.sh"
}

test_fingerprint_ignores_line_shift() {
  mkrepo
  measure_lib
  printf 'ok\nTODO here\n' > a.ts
  rule todo paths='**/*.ts'
  must git add -A
  must measure all "$TMP/m1" todo
  printf '\n\n\n' | cat - a.ts > "$TMP/shifted.ts"
  must mv "$TMP/shifted.ts" a.ts
  must git add -A
  must measure all "$TMP/m2" todo
  must cmp "$TMP/m1/measure.tsv" "$TMP/m2/measure.tsv"
  assert_eq "$(printf 'todo\ta.ts\tTODO here\t1')" "$(cat "$TMP/m2/measure.tsv")" "rows"
}

test_reformat_whole_file_same_fingerprints() {
  mkrepo
  measure_lib
  printf '  TODO  a\n    TODO b\n' > a.ts
  rule todo paths='**/*.ts'
  must git add -A
  must measure all "$TMP/m1" todo
  printf '\tTODO\ta\n\t\tTODO\tb\n' > a.ts
  must git add -A
  must measure all "$TMP/m2" todo
  must cmp "$TMP/m1/measure.tsv" "$TMP/m2/measure.tsv"
  assert_eq "$(printf 'todo\ta.ts\tTODO a\t1\ntodo\ta.ts\tTODO b\t1')" "$(cat "$TMP/m1/measure.tsv")" "rows"
}

test_crlf_equals_lf() {
  mkrepo
  measure_lib
  printf 'ok\nTODO here\n' > a.ts
  rule todo paths='**/*.ts'
  must git add -A
  must measure all "$TMP/m1" todo
  printf 'ok\r\nTODO here\r\n' > a.ts
  must git add -A
  must measure all "$TMP/m2" todo
  must cmp "$TMP/m1/measure.tsv" "$TMP/m2/measure.tsv"
}

test_count_duplicates() {
  mkrepo
  measure_lib
  printf 'TODO x\nTODO x\n' > a.ts
  rule todo paths='**/*.ts'
  must git add -A
  must measure all "$TMP/m1" todo
  assert_eq "$(printf 'todo\ta.ts\tTODO x\t2')" "$(cat "$TMP/m1/measure.tsv")" "rows"
}

test_baseline_command_writes_file() {
  mkrepo
  mkdir -p "my dir"
  printf 'TODO\n' > "my dir/ä b.ts"
  rule todo paths='**/*.ts'
  rule nothing paths='**/*.ts' "detector=rg --with-filename --line-number --no-heading 'NOPE_NEVER' {files}"
  must git add -A
  run "$G" baseline
  assert_eq 0 "$STATUS" "status"
  assert_eq "$(printf 'todo\tmy dir/ä b.ts\tTODO\t1')" "$(cat .gauntlet/baseline.tsv)" "baseline"
}

test_baseline_rule_without_matches() {
  mkrepo
  printf 'ok\n' > a.ts
  rule nothing paths='**/*.ts' "detector=rg --with-filename --line-number --no-heading 'NOPE_NEVER' {files}"
  must git add -A
  run "$G" baseline
  assert_eq 0 "$STATUS" "status"
  assert_eq "" "$(cat .gauntlet/baseline.tsv)" "baseline"
}

test_gauntlet_files_never_measured() {
  mkrepo
  measure_lib
  printf 'TODO here\n' > a.ts
  rule todo
  must git add -A
  must measure all "$TMP/m1" todo
  assert_eq "$(printf 'todo\ta.ts\tTODO here\t1')" "$(cat "$TMP/m1/measure.tsv")" "rows"
}

test_baseline_twice_is_identical() {
  mkrepo
  printf 'TODO here\n' > a.ts
  rule todo
  must git add -A
  run "$G" baseline
  assert_eq 0 "$STATUS" "first status"
  cp .gauntlet/baseline.tsv "$TMP/first.tsv"
  must git add -A
  run "$G" baseline
  assert_eq 0 "$STATUS" "second status"
  must cmp "$TMP/first.tsv" .gauntlet/baseline.tsv
  assert_eq "$(printf 'todo\ta.ts\tTODO here\t1')" "$(cat .gauntlet/baseline.tsv)" "rows"
}

test_whole_program_gauntlet_rows_dropped() {
  mkrepo
  measure_lib
  printf 'TODO here\n' > a.ts
  rule todo engine=linter paths='**' "detector=printf '.gauntlet/rules/todo.md:1:TODO\na.ts:1:TODO\n'"
  must git add -A
  must measure all "$TMP/m1" todo
  assert_eq "$(printf 'todo\ta.ts\tTODO here\t1')" "$(cat "$TMP/m1/measure.tsv")" "rows"
}

test_staged_mode_measures_staged_only() {
  mkrepo
  measure_lib
  printf 'TODO staged\n' > a.ts
  printf 'TODO unstaged\n' > b.ts
  must git add a.ts
  rule todo paths='**/*.ts'
  must measure staged "$TMP/m1" todo
  assert_eq "$(printf 'todo\ta.ts\tTODO staged\t1')" "$(cat "$TMP/m1/measure.tsv")" "rows"
}

test_bad_mode_exits_2() {
  mkrepo
  measure_lib
  rule todo
  run measure sideways "$TMP/m1" todo
  assert_eq 2 "$STATUS" "status"
  assert_contains "$OUT" "measure mode must be all or staged"
}

test_unknown_rule_exits_2() {
  mkrepo
  measure_lib
  run measure all "$TMP/m1" nosuch
  assert_eq 2 "$STATUS" "status"
  assert_contains "$OUT" "unknown rule nosuch"
}

test_located_columns_message_to_eol() {
  mkrepo
  measure_lib
  printf 'x\nTODO\tx\n' > a.ts
  rule todo paths='**/*.ts'
  must git add -A
  must measure all "$TMP/m1" todo
  assert_eq "$(printf 'todo\ta.ts\t2\tTODO x\tTODO\tx')" "$(cat "$TMP/m1/located.tsv")" "located"
}

test_baseline_skips_deleted_tracked_file() {
  mkrepo
  printf 'TODO here\n' > a.ts
  printf 'TODO gone\n' > b.ts
  must git add b.ts
  must git commit -q -m "add b"
  must rm b.ts
  rule todo paths='**/*.ts'
  must git add -A
  run "$G" baseline
  assert_eq 0 "$STATUS" "status"
  assert_eq "$(printf 'todo\ta.ts\tTODO here\t1')" "$(cat .gauntlet/baseline.tsv)" "baseline"
}

test_measure_writes_time_per_rule() {
  mkrepo
  measure_lib
  printf 'TODO here\n' > a.ts
  rule todo paths='**/*.ts'
  rule nothing paths='**/*.ts' "detector=rg --with-filename --line-number --no-heading 'NOPE_NEVER' {files}"
  must git add -A
  must measure all "$TMP/m1" todo nothing
  assert_eq 2 "$(awk 'END { print NR }' "$TMP/m1/time.tsv")" "one row per rule"
  assert_eq "todo" "$(awk -F '\t' 'NR == 1 { print $1 }' "$TMP/m1/time.tsv")" "first rule"
  assert_eq "nothing" "$(awk -F '\t' 'NR == 2 { print $1 }' "$TMP/m1/time.tsv")" "second rule"
  awk -F '\t' '$2 !~ /^[0-9]+$/ { bad = 1 } END { exit bad }' "$TMP/m1/time.tsv" || fail "time is not a whole number of ms"
}
