# shellcheck shell=bash
# shellcheck disable=SC2153 # ROOT and STATUS are set by test/lib.sh
# Tests for lib/rules.sh: frontmatter reads, rule validation and ordering.

# rules_lib: source the libraries under test into the current test subshell.
rules_lib() {
  # shellcheck source=lib/core.sh
  # shellcheck disable=SC2153 # ROOT is set by test/lib.sh
  . "$ROOT/lib/core.sh"
  # shellcheck source=lib/rules.sh
  . "$ROOT/lib/rules.sh"
  # rule_validate asks exceptions.sh for the script row; DETECT_TAB is in detect.sh.
  # shellcheck source=lib/detect.sh
  . "$ROOT/lib/detect.sh"
  # shellcheck source=lib/exceptions.sh
  . "$ROOT/lib/exceptions.sh"
}

test_get_strips_comment_on_enum_keys() {
  mkrepo
  rules_lib
  rule x "severity=block   # block | shadow"
  assert_eq "block" "$(rule_get .gauntlet/rules/x.md severity)" "severity"
}

test_get_keeps_hash_in_detector() {
  mkrepo
  rules_lib
  rule x "detector=rg '# x' {files}"
  assert_eq "rg '# x' {files}" "$(rule_get .gauntlet/rules/x.md detector)" "detector"
}

test_get_strips_comment_on_format_key() {
  mkrepo
  rules_lib
  printf -- '---\nid: x\nformat: github   # default\n---\n' > .gauntlet/rules/x.md
  assert_eq "github" "$(rule_get .gauntlet/rules/x.md format)" "format"
}

test_get_fails_on_unclosed_frontmatter() {
  mkrepo
  rules_lib
  printf -- '---\nid: x\nseverity: block\n' > .gauntlet/rules/x.md
  run rule_get .gauntlet/rules/x.md id
  assert_eq 3 "$STATUS" "status"
  assert_eq "" "$OUT" "output"
}

test_validate_rejects_unclosed_frontmatter() {
  mkrepo
  rules_lib
  printf -- '---\nid: x\nseverity: block\nengine: rg\ndetector: rg TODO {files}\nfix: remove it\nsource: pending\nsince: 2026-10-22\n' > .gauntlet/rules/x.md
  run rule_validate .gauntlet/rules/x.md
  assert_eq 1 "$STATUS" "status"
  assert_eq ".gauntlet/rules/x.md: frontmatter not closed" "$OUT" "output"
}

test_validate_accepts_good_rule() {
  mkrepo
  rules_lib
  rule x
  run rule_validate .gauntlet/rules/x.md
  assert_eq 0 "$STATUS" "status"
  assert_eq "" "$OUT" "output"
}

test_validate_rejects_bad_severity() {
  mkrepo
  rules_lib
  rule x severity=hard
  run rule_validate .gauntlet/rules/x.md
  assert_eq 1 "$STATUS" "status"
  assert_contains "$OUT" "severity"
}

test_validate_script_needs_exception() {
  mkrepo
  rules_lib
  rule x engine=script
  run rule_validate .gauntlet/rules/x.md
  assert_eq 1 "$STATUS" "status without row"
  assert_contains "$OUT" "exceptions.tsv"
  printf 'type\ttarget\treason\tdate\tbranch\nscript\tx\tneeds awk\t2026-10-22\t\n' > .gauntlet/exceptions.tsv
  run rule_validate .gauntlet/rules/x.md
  assert_eq 0 "$STATUS" "status with row"
}

# exc_has_script asks only whether this rule has a script row: no file is no row, and a
# row for another rule is not this rule's.
test_exc_has_script_is_false_without_the_file() {
  mkrepo
  rules_lib
  must rm .gauntlet/exceptions.tsv
  run exc_has_script x
  assert_eq 1 "$STATUS" "no exceptions.tsv: $OUT"
}

test_exc_has_script_is_false_for_another_rules_row() {
  mkrepo
  rules_lib
  script_row y
  run exc_has_script x
  assert_eq 1 "$STATUS" "a row for y is not x's: $OUT"
  run exc_has_script y
  assert_eq 0 "$STATUS" "y has its row: $OUT"
  rule x engine=script
  run rule_validate .gauntlet/rules/x.md
  assert_eq 1 "$STATUS" "x still needs a row: $OUT"
  assert_contains "$OUT" "exceptions.tsv"
}

test_stage_defaults_to_commit() {
  mkrepo
  rules_lib
  # A rule with no stage key: validation must accept it.
  printf -- '---\nid: x\nseverity: block\nengine: rg\ndetector: rg TODO {files}\npaths: **\nexclude: \nfix: remove it\nsource: pending\nsince: 2026-10-22\n---\nBody.\n' > .gauntlet/rules/x.md
  assert_eq "" "$(rule_get .gauntlet/rules/x.md stage)" "raw stage"
  run rule_validate .gauntlet/rules/x.md
  assert_eq 0 "$STATUS" "status"
}

test_ids_sorted() {
  mkrepo
  rules_lib
  rule b
  rule a
  run rule_ids
  assert_eq "$(printf 'a\nb')" "$OUT" "ids"
}

test_severity_rank_orders_levels() {
  rules_lib
  assert_eq 3 "$(severity_rank block)" "block"
  assert_eq 2 "$(severity_rank shadow)" "shadow"
  assert_eq 1 "$(severity_rank track)" "track"
}

test_rule_ids_skips_case_files() {
  mkrepo
  rules_lib
  rule mdr
  printf 'TODO\n' > .gauntlet/rules/mdr.bad.md
  printf 'ok\n' > .gauntlet/rules/mdr.good.md
  run rule_ids
  assert_eq "mdr" "$OUT" "ids"
}
