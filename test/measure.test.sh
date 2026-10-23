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
  must measure all "$TMP/m1" todo
  printf '\n\n\n' | cat - a.ts > "$TMP/shifted.ts"
  must mv "$TMP/shifted.ts" a.ts
  must measure all "$TMP/m2" todo
  must cmp "$TMP/m1/measure.tsv" "$TMP/m2/measure.tsv"
  assert_eq "$(printf 'todo\ta.ts\tTODO here\t1')" "$(cat "$TMP/m2/measure.tsv")" "rows"
}

test_reformat_whole_file_same_fingerprints() {
  mkrepo
  measure_lib
  printf '  TODO  a\n    TODO b\n' > a.ts
  rule todo paths='**/*.ts'
  must measure all "$TMP/m1" todo
  printf '\tTODO\ta\n\t\tTODO\tb\n' > a.ts
  must measure all "$TMP/m2" todo
  must cmp "$TMP/m1/measure.tsv" "$TMP/m2/measure.tsv"
  assert_eq "$(printf 'todo\ta.ts\tTODO a\t1\ntodo\ta.ts\tTODO b\t1')" "$(cat "$TMP/m1/measure.tsv")" "rows"
}

test_crlf_equals_lf() {
  mkrepo
  measure_lib
  printf 'ok\nTODO here\n' > a.ts
  rule todo paths='**/*.ts'
  must measure all "$TMP/m1" todo
  printf 'ok\r\nTODO here\r\n' > a.ts
  must measure all "$TMP/m2" todo
  must cmp "$TMP/m1/measure.tsv" "$TMP/m2/measure.tsv"
}

test_count_duplicates() {
  mkrepo
  measure_lib
  printf 'TODO x\nTODO x\n' > a.ts
  rule todo paths='**/*.ts'
  must measure all "$TMP/m1" todo
  assert_eq "$(printf 'todo\ta.ts\tTODO x\t2')" "$(cat "$TMP/m1/measure.tsv")" "rows"
}

test_baseline_command_writes_file() {
  mkrepo
  mkdir -p "my dir"
  printf 'TODO\n' > "my dir/ä b.ts"
  rule todo paths='**/*.ts'
  rule nothing paths='**/*.ts' "detector=rg --with-filename --line-number --no-heading 'NOPE_NEVER' {files}"
  run "$G" baseline
  assert_eq 0 "$STATUS" "status"
  assert_eq "$(printf 'todo\tmy dir/ä b.ts\tTODO\t1')" "$(cat .gauntlet/baseline.tsv)" "baseline"
}

test_baseline_rule_without_matches() {
  mkrepo
  printf 'ok\n' > a.ts
  rule nothing paths='**/*.ts' "detector=rg --with-filename --line-number --no-heading 'NOPE_NEVER' {files}"
  run "$G" baseline
  assert_eq 0 "$STATUS" "status"
  assert_eq "" "$(cat .gauntlet/baseline.tsv)" "baseline"
}
