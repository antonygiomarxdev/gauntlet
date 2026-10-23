# shellcheck shell=bash
# shellcheck disable=SC2153 # ROOT, G, STATUS and OUT are set by test/lib.sh
# Tests for status, promote and doctor (lib/status.sh). Each test runs in a fresh
# repo under $TMP. GAUNTLET_TODAY pins the clock wherever a date matters.

# same_file <want> <got>: fail with a diff unless the two files are byte-equal.
same_file() {
  if ! cmp -s "$1" "$2"; then
    diff -u "$1" "$2" >&2
    fail "$2 differs from $1"
  fi
}

# file_mode <file>: the permission bits of <file>, GNU and BSD stat.
file_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

# doctor_fails: how many FAIL lines the last run printed.
doctor_fails() {
  printf '%s\n' "$OUT" | grep -c '^FAIL ' || true
}

# doctor_install: vendor the runner and wire the hooks of the current repo.
doctor_install() {
  run "$G" install
  assert_eq 0 "$STATUS" "install"
}

# doctor_one_fail <needle>: doctor must exit 1 with exactly one FAIL line, and
# that line must hold <needle>.
doctor_one_fail() {
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor status with [$1] broken"
  assert_eq 1 "$(doctor_fails)" "FAIL count with [$1] broken"
  assert_contains "$(printf '%s\n' "$OUT" | grep '^FAIL ')" "$1"
}

# status_due_for <since> <today>: run status for one shadow rule and leave the output in OUT.
status_due_for() {
  rule x severity=shadow "since=$1"
  run env GAUNTLET_TODAY="$2" "$G" status
  assert_eq 0 "$STATUS" "status"
}

test_status_totals_and_worst_files() {
  mkrepo
  rule a
  rule b severity=shadow since=2026-10-28
  rule c
  rule t severity=track
  printf 'a\tsrc/x.ts\tfp-1\t3\na\tsrc/y.ts\tfp-2\t2\nb\tsrc/x.ts\tfp-3\t4\nt\tsrc/y.ts\tfp-4\t9\n' > .gauntlet/baseline.tsv
  env GAUNTLET_TODAY=2026-10-30 "$G" status > "$TMP/out" || fail "status exits $?"
  cat > "$TMP/want" <<'EOF'
| rule | severity | total |
| --- | --- | --- |
| a | block | 5 |
| b | shadow | 4 |
| c | block | 0 |
| t | track | 9 |

| file | block total |
| --- | --- |
| src/x.ts | 3 |
| src/y.ts | 2 |
EOF
  same_file "$TMP/want" "$TMP/out"
}

test_status_top_five_ties_and_space_path() {
  mkrepo
  rule a
  printf 'a\tsrc/zeta.ts\tf1\t5\na\tsrc/a b.ts\tf2\t4\na\tsrc/beta.ts\tf3\t4\na\tsrc/alpha.ts\tf4\t1\na\tsrc/alpha.ts\tf5\t2\na\tsrc/gamma.ts\tf6\t2\na\tsrc/delta.ts\tf7\t1\n' > .gauntlet/baseline.tsv
  env GAUNTLET_TODAY=2026-10-30 "$G" status > "$TMP/out" || fail "status exits $?"
  cat > "$TMP/want" <<'EOF'
| rule | severity | total |
| --- | --- | --- |
| a | block | 19 |

| file | block total |
| --- | --- |
| src/zeta.ts | 5 |
| src/a b.ts | 4 |
| src/beta.ts | 4 |
| src/alpha.ts | 3 |
| src/gamma.ts | 2 |
EOF
  same_file "$TMP/want" "$TMP/out"
}

test_status_files_list_only_block_rules() {
  mkrepo
  rule a
  rule s severity=shadow since=2026-10-28
  rule t severity=track
  printf 's\tsrc/only-shadow.ts\tf1\t7\nt\tsrc/only-track.ts\tf2\t8\n' > .gauntlet/baseline.tsv
  env GAUNTLET_TODAY=2026-10-30 "$G" status > "$TMP/out" || fail "status exits $?"
  cat > "$TMP/want" <<'EOF'
| rule | severity | total |
| --- | --- | --- |
| a | block | 0 |
| s | shadow | 7 |
| t | track | 8 |
EOF
  same_file "$TMP/want" "$TMP/out"
}

test_status_ignores_rows_of_a_deleted_rule() {
  mkrepo
  rule a
  printf 'a\tsrc/x.ts\tf1\t1\ngone\tsrc/x.ts\tf2\t50\n' > .gauntlet/baseline.tsv
  env GAUNTLET_TODAY=2026-10-30 "$G" status > "$TMP/out" || fail "status exits $?"
  cat > "$TMP/want" <<'EOF'
| rule | severity | total |
| --- | --- | --- |
| a | block | 1 |

| file | block total |
| --- | --- |
| src/x.ts | 1 |
EOF
  same_file "$TMP/want" "$TMP/out"
}

test_status_writes_status_md_same_text() {
  mkrepo
  rule a
  printf 'a\tsrc/x.ts\tf1\t1\n' > .gauntlet/baseline.tsv
  env GAUNTLET_TODAY=2026-10-30 "$G" status > "$TMP/first" || fail "first status exits $?"
  same_file "$TMP/first" .gauntlet/STATUS.md
  printf 'a\tsrc/x.ts\tf1\t4\n' > .gauntlet/baseline.tsv
  env GAUNTLET_TODAY=2026-10-30 "$G" status > "$TMP/second" || fail "second status exits $?"
  same_file "$TMP/second" .gauntlet/STATUS.md
  if cmp -s "$TMP/first" "$TMP/second"; then fail "the second run did not rewrite the file"; fi
}

test_promote_due_after_7_days() {
  mkrepo
  status_due_for 2026-10-22 2026-10-30
  assert_contains "$OUT" "promote due: x (shadow since 2026-10-22, 8 days), 0 found"
}

test_promote_due_exactly_7_days_and_not_at_6() {
  mkrepo
  status_due_for 2026-10-23 2026-10-30
  assert_contains "$OUT" "promote due: x (shadow since 2026-10-23, 7 days), 0 found"
  status_due_for 2026-10-24 2026-10-30
  assert_not_contains "$OUT" "promote due"
}

test_promote_due_across_leap_day() {
  mkrepo
  status_due_for 2028-02-24 2028-03-02
  assert_contains "$OUT" "promote due: x (shadow since 2028-02-24, 7 days), 0 found"
  status_due_for 2028-02-25 2028-03-02
  assert_not_contains "$OUT" "promote due"
}

test_promote_due_across_year_boundary() {
  mkrepo
  status_due_for 2026-12-27 2027-01-03
  assert_contains "$OUT" "promote due: x (shadow since 2026-12-27, 7 days), 0 found"
  status_due_for 2026-12-28 2027-01-03
  assert_not_contains "$OUT" "promote due"
}

test_promote_future_since_is_not_due() {
  mkrepo
  status_due_for 2026-11-05 2026-10-30
  assert_not_contains "$OUT" "promote due"
}

test_promote_due_skips_shadow_without_since() {
  mkrepo
  rule x severity=shadow since=
  run env GAUNTLET_TODAY=2026-10-30 "$G" status
  assert_eq 0 "$STATUS" "status"
  assert_not_contains "$OUT" "promote due"
}

test_promote_due_appends_found_total() {
  mkrepo
  rule x severity=shadow since=2026-10-22
  printf 'x\tsrc/x.ts\tf1\t3\nx\tsrc/y.ts\tf2\t2\n' > .gauntlet/baseline.tsv
  run env GAUNTLET_TODAY=2026-10-30 "$G" status
  assert_eq 0 "$STATUS" "status"
  assert_contains "$OUT" "promote due: x (shadow since 2026-10-22, 8 days), 5 found"
}

test_status_rejects_bad_today() {
  mkrepo
  rule x severity=shadow since=2026-10-22
  run env GAUNTLET_TODAY=2026-10 "$G" status
  assert_eq 2 "$STATUS" "status"
  assert_contains "$OUT" "GAUNTLET_TODAY"
}

test_status_lists_slow_commit_rules() {
  mkrepo
  rule fast
  rule slow
  rule pushslow stage=push
  printf 'fast\t40\nslow\t6200\npushslow\t9000\n' > .gauntlet/time.tsv
  run env GAUNTLET_TODAY=2026-10-30 "$G" status
  assert_eq 0 "$STATUS" "status"
  assert_contains "$OUT" "slow: slow 6200 ms (consider stage: push)"
  assert_not_contains "$OUT" "slow: pushslow"
  assert_not_contains "$OUT" "slow: fast"
  run env GAUNTLET_TODAY=2026-10-30 GAUNTLET_COMMIT_BUDGET_MS=30 "$G" status
  assert_eq 0 "$STATUS" "status with a 30 ms budget"
  assert_contains "$OUT" "slow: fast 40 ms (consider stage: push)"
  run env GAUNTLET_TODAY=2026-10-30 GAUNTLET_COMMIT_BUDGET_MS=40 "$G" status
  assert_contains "$OUT" "slow: fast 40 ms (consider stage: push)"
  run env GAUNTLET_TODAY=2026-10-30 GAUNTLET_COMMIT_BUDGET_MS=41 "$G" status
  assert_not_contains "$OUT" "slow: fast"
}

test_status_without_time_tsv_lists_no_slow_rules() {
  mkrepo
  rule slow
  run env GAUNTLET_TODAY=2026-10-30 "$G" status
  assert_eq 0 "$STATUS" "status"
  assert_not_contains "$OUT" "slow:"
}

test_status_rejects_bad_commit_budget() {
  mkrepo
  rule slow
  printf 'slow\t6200\n' > .gauntlet/time.tsv
  run env GAUNTLET_TODAY=2026-10-30 GAUNTLET_COMMIT_BUDGET_MS=soon "$G" status
  assert_eq 2 "$STATUS" "status"
  assert_contains "$OUT" "GAUNTLET_COMMIT_BUDGET_MS"
}

test_status_and_doctor_reject_extra_arguments() {
  mkrepo
  run "$G" status extra
  assert_eq 2 "$STATUS" "status with an argument"
  assert_contains "$OUT" "usage: gauntlet status"
  run "$G" doctor extra
  assert_eq 2 "$STATUS" "doctor with an argument"
  assert_contains "$OUT" "usage: gauntlet doctor"
}

test_status_without_gauntlet_dir_exits_2() {
  mkrepo
  rm -rf .gauntlet
  run "$G" status
  assert_eq 2 "$STATUS" "status"
  assert_contains "$OUT" "not a gauntlet repo"
  run "$G" doctor
  assert_eq 2 "$STATUS" "doctor"
  assert_contains "$OUT" "not a gauntlet repo"
}

test_promote_flips_shadow() {
  mkrepo
  # Written by hand: a trailing comment, and a body with no final newline, must survive.
  printf -- '---\nid: x\nseverity: shadow  # shadow | block\nstage: commit\nengine: rg\ndetector: rg TODO {files}\npaths: **\nexclude: \nfix: remove it\nsource: pending\nsince: 2026-10-22\n---\nFixture rule x.' > .gauntlet/rules/x.md
  must chmod 640 .gauntlet/rules/x.md
  printf -- '---\nid: x\nseverity: block  # shadow | block\nstage: commit\nengine: rg\ndetector: rg TODO {files}\npaths: **\nexclude: \nfix: remove it\nsource: pending\nsince: 2026-10-22\n---\nFixture rule x.' > "$TMP/want"
  run "$G" promote x
  assert_eq 0 "$STATUS" "promote"
  assert_eq "promoted x: shadow -> block; commit the rule file" "$OUT" "output"
  same_file "$TMP/want" .gauntlet/rules/x.md
  assert_eq 640 "$(file_mode .gauntlet/rules/x.md)" "mode"
}

test_promote_due_after_7_days_then_promoted_is_not_due() {
  mkrepo
  rule x severity=shadow since=2026-10-22
  run "$G" promote x
  assert_eq 0 "$STATUS" "promote"
  run env GAUNTLET_TODAY=2026-10-30 "$G" status
  assert_eq 0 "$STATUS" "status"
  assert_not_contains "$OUT" "promote due"
}

test_promote_rejects_block() {
  mkrepo
  rule x severity=block
  cp .gauntlet/rules/x.md "$TMP/before"
  run "$G" promote x
  assert_eq 2 "$STATUS" "promote"
  assert_contains "$OUT" "block"
  same_file "$TMP/before" .gauntlet/rules/x.md
}

test_promote_rejects_track() {
  mkrepo
  rule x severity=track
  cp .gauntlet/rules/x.md "$TMP/before"
  run "$G" promote x
  assert_eq 2 "$STATUS" "promote"
  assert_contains "$OUT" "track"
  same_file "$TMP/before" .gauntlet/rules/x.md
}

test_promote_unknown_rule_exits_2() {
  mkrepo
  rule x severity=shadow
  run "$G" promote nope
  assert_eq 2 "$STATUS" "promote"
  assert_contains "$OUT" "unknown rule nope"
}

test_promote_wrong_argument_count_exits_2() {
  mkrepo
  rule x severity=shadow
  run "$G" promote
  assert_eq 2 "$STATUS" "promote with no id"
  assert_contains "$OUT" "usage: gauntlet promote <id>"
  run "$G" promote x y
  assert_eq 2 "$STATUS" "promote with two ids"
  assert_contains "$OUT" "usage: gauntlet promote <id>"
}

test_doctor_clean_repo_ok() {
  mkrepo
  mkdir -p src
  rule todo
  printf 'TODO fix\n' > src/a.ts
  must git add -A
  must git commit -q -m content
  run "$G" baseline
  assert_eq 0 "$STATUS" "baseline"
  doctor_install
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor"
  assert_eq 0 "$(doctor_fails)" "FAIL lines"
  assert_contains "$OUT" "ok baseline is exact"
  assert_contains "$OUT" "ok pre-commit gate in .git/hooks/pre-commit"
  assert_contains "$OUT" "ok pre-push gate in .git/hooks/pre-push"
  assert_contains "$OUT" "ok tool rg for rule todo"
  assert_contains "$OUT" "ok config keys"
}

test_doctor_flags_missing_hook() {
  mkrepo
  doctor_install
  printf '#!/bin/sh\necho hi\n' > .git/hooks/pre-commit
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor"
  assert_contains "$OUT" "FAIL pre-commit gate missing from .git/hooks/pre-commit: run gauntlet install-hooks"
  assert_not_contains "$OUT" "by hand"
}

test_doctor_accepts_gate_form_line() {
  mkrepo
  printf '#!/bin/sh\necho hi\n' > .git/hooks/pre-commit
  doctor_install
  assert_contains "$(cat .git/hooks/pre-commit)" "|| exit \$?  # gauntlet"
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor"
  assert_contains "$OUT" "ok pre-commit gate in .git/hooks/pre-commit"
}

test_doctor_husky_layout() {
  mkrepo
  must mkdir -p .husky
  must git config core.hooksPath .husky
  doctor_install
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor with husky"
  assert_contains "$OUT" "ok pre-push gate in .husky/pre-push"
  printf '#!/bin/sh\n' > .husky/pre-push
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor after the husky pre-push loses its line"
  assert_contains "$OUT" "FAIL pre-push gate missing from .husky/pre-push: run gauntlet install-hooks"
}

test_doctor_lefthook_needs_snippet() {
  mkrepo
  printf 'pre-commit:\n  parallel: true\n' > lefthook.yml
  doctor_install
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor without the snippet"
  assert_contains "$OUT" "FAIL gate missing from lefthook.yml: run gauntlet install-hooks"
  assert_eq 1 "$(doctor_fails)" "FAIL count without the snippet"
  printf 'pre-commit:\n  commands:\n    gauntlet:\n      run: .gauntlet/bin/gauntlet check --staged\npre-push:\n  commands:\n    gauntlet:\n      run: .gauntlet/bin/gauntlet check --ci\n' >> lefthook.yml
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor with the snippet"
  assert_contains "$OUT" "ok gate in lefthook.yml"
}

test_doctor_missing_runner() {
  mkrepo
  doctor_install
  must rm -rf .gauntlet/bin
  doctor_one_fail "FAIL runner .gauntlet/bin/gauntlet is missing or not executable: run gauntlet install"
}

test_doctor_print_only_hook_names_manual_line() {
  mkrepo
  must mkdir "$TMP/shared"
  must git config core.hooksPath "$TMP/shared"
  doctor_install
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor with a shared hooks dir"
  assert_contains "$OUT" "FAIL pre-commit gate missing from $TMP/shared/pre-commit: run gauntlet install-hooks, or add this line by hand: .gauntlet/bin/gauntlet check --staged || exit \$?  # gauntlet"
  printf '%s\n' '.gauntlet/bin/gauntlet check --staged || exit $?  # gauntlet' > "$TMP/shared/pre-commit"
  printf '%s\n' '.gauntlet/bin/gauntlet check --ci || exit $?  # gauntlet' > "$TMP/shared/pre-push"
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor after the lines are added by hand"
}

test_doctor_uneditable_hook_names_manual_line() {
  mkrepo
  printf '#!/usr/bin/env python3\nprint(1)\n' > .git/hooks/pre-commit
  doctor_install
  assert_contains "$(cat .git/hooks/pre-commit)" "python3"
  doctor_one_fail "FAIL pre-commit gate missing from .git/hooks/pre-commit: run gauntlet install-hooks, or add this line by hand: .gauntlet/bin/gauntlet check --staged || exit \$?  # gauntlet"
}

test_doctor_config_unknown_key_fails() {
  mkrepo
  doctor_install
  printf 'bogus=1\n' >> .gauntlet/config
  doctor_one_fail "FAIL config key bogus is not known"
}

test_doctor_bad_check_key_fails() {
  mkrepo
  doctor_install
  printf 'check.a.b.c=echo hi\n' >> .gauntlet/config
  doctor_one_fail "FAIL bad check key check.a.b.c"
}

test_doctor_touched_value_fails() {
  mkrepo
  doctor_install
  printf 'touched=maybe\n' >> .gauntlet/config
  doctor_one_fail "FAIL touched must be on or off, got [maybe]"
}

test_doctor_rule_validate_failure_names_rule() {
  mkrepo
  rule x severity=hard
  doctor_install
  doctor_one_fail "FAIL rule x: severity must be block, shadow or track, got [hard]"
}

test_doctor_inexact_baseline_fails() {
  mkrepo
  mkdir -p src
  rule todo
  printf 'TODO fix\n' > src/a.ts
  must git add -A
  must git commit -q -m content
  run "$G" baseline
  assert_eq 0 "$STATUS" "baseline"
  doctor_install
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor with an exact baseline"
  printf '' > .gauntlet/baseline.tsv
  doctor_one_fail "FAIL baseline differs from the code: run gauntlet baseline and commit it"
}

test_doctor_baseline_check_allows_dirty_tree() {
  mkrepo
  mkdir -p src
  rule todo
  printf 'TODO fix\n' > src/a.ts
  must git add -A
  must git commit -q -m content
  run "$G" baseline
  assert_eq 0 "$STATUS" "baseline"
  doctor_install
  printf 'TODO untracked\n' > src/untracked.ts
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor with an untracked violation"
  assert_contains "$OUT" "ok baseline is exact"
}

test_doctor_engine_tool_missing_fails() {
  mkrepo
  rule ghost engine=linter "detector=nosuchtool-gauntlet-xyz {files}" paths=nothing/**
  rule present engine=linter "detector=/bin/sh -c true {files}" paths=nothing/**
  doctor_install
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor with a missing tool"
  assert_eq 1 "$(doctor_fails)" "FAIL count"
  assert_contains "$OUT" "FAIL tool nosuchtool-gauntlet-xyz for rule ghost is missing"
  assert_contains "$OUT" "ok tool /bin/sh for rule present"
}

test_doctor_lists_stale_waivers_and_exits_0() {
  mkrepo
  doctor_install
  printf 'waive\told.txt\treason here\t2026-10-20\tfeature-x\nwaive\tmine.txt\treason\t2026-10-21\tmain\n' >> .gauntlet/exceptions.tsv
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor with a stale waiver"
  assert_contains "$OUT" "stale waive old.txt (branch feature-x)"
  assert_not_contains "$OUT" "stale waive mine.txt"
  assert_not_contains "$OUT" "FAIL"
}

test_doctor_reports_no_stale_waivers() {
  mkrepo
  doctor_install
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor"
  assert_contains "$OUT" "ok no stale waivers"
}

test_doctor_stale_waiver_uses_github_head_ref() {
  mkrepo
  doctor_install
  printf 'waive\tsrc/a.ts\treason\t2026-10-20\tfeature-x\n' >> .gauntlet/exceptions.tsv
  run env GITHUB_HEAD_REF=feature-x "$G" doctor
  assert_eq 0 "$STATUS" "doctor on the waiver's branch"
  assert_contains "$OUT" "ok no stale waivers"
  run env GITHUB_HEAD_REF=other "$G" doctor
  assert_eq 0 "$STATUS" "doctor on another branch"
  assert_contains "$OUT" "stale waive src/a.ts (branch feature-x)"
}

test_doctor_end_to_end_one_break_one_fail() {
  mkrepo
  mkdir -p "src"
  rule todo
  printf 'TODO fix\n' > "src/a b.ts"
  must git add -A
  must git commit -q -m content
  must "$G" baseline
  must git add -A
  must git commit -q -m baseline
  doctor_install
  run "$G" doctor
  assert_eq 0 "$STATUS" "clean doctor"
  assert_eq 0 "$(doctor_fails)" "clean FAIL count"

  cp .git/hooks/pre-push "$TMP/pre-push.bak"
  printf '#!/bin/sh\n' > .git/hooks/pre-push
  doctor_one_fail "FAIL pre-push gate missing from .git/hooks/pre-push"
  cp "$TMP/pre-push.bak" .git/hooks/pre-push

  cp .gauntlet/config "$TMP/config.bak"
  printf 'bogus=1\n' >> .gauntlet/config
  doctor_one_fail "FAIL config key bogus"
  cp "$TMP/config.bak" .gauntlet/config

  cp .gauntlet/baseline.tsv "$TMP/baseline.bak"
  printf 'todo\tsrc/a b.ts\tTODO fix\t9\n' > .gauntlet/baseline.tsv
  doctor_one_fail "FAIL baseline differs from the code"
  cp "$TMP/baseline.bak" .gauntlet/baseline.tsv

  cp .gauntlet/rules/todo.md "$TMP/rule.bak"
  rule todo since=2026/10/22
  doctor_one_fail "FAIL rule todo: since must be YYYY-MM-DD"
  cp "$TMP/rule.bak" .gauntlet/rules/todo.md

  mv .gauntlet/bin "$TMP/bin.bak"
  doctor_one_fail "FAIL runner .gauntlet/bin/gauntlet is missing or not executable"
  mv "$TMP/bin.bak" .gauntlet/bin

  rule ghost engine=linter "detector=nosuchtool-gauntlet-xyz {files}" paths=nothing/**
  doctor_one_fail "FAIL tool nosuchtool-gauntlet-xyz for rule ghost is missing"
  rm -f .gauntlet/rules/ghost.md

  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor after every break is undone"
  assert_eq 0 "$(doctor_fails)" "FAIL count after every break is undone"

  printf 'waive\tsrc/a b.ts\treason\t2026-10-22\tfeature-x\n' >> .gauntlet/exceptions.tsv
  run "$G" doctor
  assert_eq 0 "$STATUS" "a stale waiver does not fail"
  assert_contains "$OUT" "stale waive src/a b.ts (branch feature-x)"
}
