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

# inode_of <file>: the inode number of <file>, GNU and BSD stat.
inode_of() {
  stat -c %i "$1" 2>/dev/null || stat -f %i "$1"
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

# status_lib: source the libraries the way bin/gauntlet does, for tests of helpers.
status_lib() {
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
  # shellcheck source=lib/base.sh
  . "$ROOT/lib/base.sh"
  # shellcheck source=lib/exceptions.sh
  . "$ROOT/lib/exceptions.sh"
  # shellcheck source=lib/check.sh
  . "$ROOT/lib/check.sh"
  # shellcheck source=lib/hooks.sh
  . "$ROOT/lib/hooks.sh"
  # shellcheck source=lib/status.sh
  . "$ROOT/lib/status.sh"
}

# commit_times_file: the file check --staged writes its per-rule times to, relative
# to the repo root (in the git dir, so it is never in the work tree).
commit_times_file() {
  git rev-parse --git-path gauntlet-time.tsv
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
  printf 'fast\t40\nslow\t6200\npushslow\t9000\n' > "$(commit_times_file)"
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
  printf 'slow\t6200\n' > "$(commit_times_file)"
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
  must chmod +x .git/hooks/pre-commit
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
  doctor_one_fail "FAIL .gauntlet/bin or .gauntlet/lib is broken or missing"
}

test_doctor_print_only_hook_names_manual_line() {
  mkrepo
  must mkdir "$TMP/shared"
  must git config core.hooksPath "$TMP/shared"
  doctor_install
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor with a shared hooks dir"
  assert_contains "$OUT" "FAIL pre-commit gate missing from $TMP/shared/pre-commit: add this line by hand as the first command, after the shebang line if there is one: .gauntlet/bin/gauntlet check --staged || exit \$?  # gauntlet"
  assert_not_contains "$OUT" "install-hooks"
  printf '%s\n' '.gauntlet/bin/gauntlet check --staged || exit $?  # gauntlet' > "$TMP/shared/pre-commit"
  printf '%s\n' '.gauntlet/bin/gauntlet check --ci || exit $?  # gauntlet' > "$TMP/shared/pre-push"
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor after the lines are added by hand"
}

test_doctor_uneditable_hook_names_manual_line() {
  mkrepo
  printf '#!/usr/bin/env python3\nprint(1)\n' > .git/hooks/pre-commit
  must chmod +x .git/hooks/pre-commit
  doctor_install
  assert_contains "$(cat .git/hooks/pre-commit)" "python3"
  doctor_one_fail "FAIL pre-commit gate missing from .git/hooks/pre-commit: add this line by hand as the first command, after the shebang line if there is one: .gauntlet/bin/gauntlet check --staged || exit \$?  # gauntlet"
}

test_doctor_flags_unknown_config_key() {
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
  doctor_one_fail "FAIL .gauntlet/bin or .gauntlet/lib is broken or missing"
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

test_doctor_runner_lib_removed_fails() {
  mkrepo
  doctor_install
  must rm -rf .gauntlet/lib
  doctor_one_fail "FAIL .gauntlet/bin or .gauntlet/lib is broken or missing"
}

test_doctor_runner_bin_directory_fails() {
  mkrepo
  doctor_install
  must rm -f .gauntlet/bin/gauntlet
  must mkdir .gauntlet/bin/gauntlet
  doctor_one_fail "FAIL .gauntlet/bin or .gauntlet/lib is broken or missing"
}

test_doctor_runner_not_executable_fails() {
  mkrepo
  doctor_install
  must chmod -x .gauntlet/bin/gauntlet
  doctor_one_fail "FAIL .gauntlet/bin or .gauntlet/lib is broken or missing"
}

test_doctor_runner_all_fine_is_ok() {
  mkrepo
  doctor_install
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor"
  assert_contains "$OUT" "ok runner .gauntlet/bin/gauntlet"
}

test_doctor_tool_shapes_are_not_checked() {
  mkrepo
  rule s1 engine=linter "detector='rg' --version {files}" paths=nothing/**
  rule s2 engine=linter 'detector="rg" --version {files}' paths=nothing/**
  rule s3 engine=linter 'detector=FOO=1 rg x {files}' paths=nothing/**
  # shellcheck disable=SC2016 # the detector holds a literal $LINT on purpose
  rule s4 engine=linter 'detector=$LINT x {files}' paths=nothing/**
  rule s5 engine=linter 'detector=~/bin/tool x {files}' paths=nothing/**
  doctor_install
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor"
  assert_eq 0 "$(doctor_fails)" "FAIL lines"
  assert_contains "$OUT" "ok tool s1: cannot check ('rg')"
  assert_contains "$OUT" "ok tool s2: cannot check (\"rg\")"
  assert_contains "$OUT" "ok tool s3: cannot check (FOO=1)"
  assert_contains "$OUT" "ok tool s4: cannot check (\$LINT)"
  assert_contains "$OUT" "ok tool s5: cannot check (~/bin/tool)"
}

test_doctor_unknown_engine_is_one_fail() {
  mkrepo
  mkdir -p src
  printf 'TODO\n' > src/a.ts
  must git add -A
  must git commit -q -m content
  rule weird engine=weird
  doctor_install
  doctor_one_fail "FAIL rule weird: engine must be linter, ast-grep, rg or script, got [weird]"
}

test_doctor_empty_detector_is_one_fail() {
  mkrepo
  rule empty engine=linter "detector="
  doctor_install
  doctor_one_fail "FAIL rule empty: detector must not be empty"
}

test_doctor_missing_tool_is_one_fail() {
  mkrepo
  mkdir -p src
  printf 'TODO\n' > src/a.ts
  must git add -A
  must git commit -q -m content
  rule ghost engine=linter "detector=nosuchtool-gauntlet-xyz {files}"
  doctor_install
  doctor_one_fail "FAIL tool nosuchtool-gauntlet-xyz for rule ghost is missing"
}

test_doctor_baseline_failure_names_real_reason() {
  mkrepo
  mkdir -p src
  printf 'x\n' > src/a.ts
  must git add -A
  must git commit -q -m content
  rule bd engine=linter "detector=sh -c 'echo nope >&2; exit 3' {files}"
  doctor_install
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor"
  assert_contains "$OUT" "FAIL baseline cannot be checked: broken detector: bd: exit 3"
  assert_not_contains "$OUT" "see above"
}

test_doctor_tool_relative_path_present_and_absent() {
  mkrepo
  rule lint engine=linter "detector=./tools/lint {files}" paths=nothing/**
  must mkdir tools
  printf '#!/bin/sh\nexit 0\n' > tools/lint
  must chmod +x tools/lint
  doctor_install
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor with the tool present"
  assert_contains "$OUT" "ok tool ./tools/lint for rule lint"
  must rm tools/lint
  doctor_one_fail "FAIL tool ./tools/lint for rule lint is missing"
}

test_doctor_nonexec_plain_hook_fails() {
  mkrepo
  doctor_install
  must chmod 644 .git/hooks/pre-commit
  doctor_one_fail "FAIL pre-commit hook .git/hooks/pre-commit is not executable: chmod +x .git/hooks/pre-commit"
}

test_doctor_nonexec_husky_hook_is_ok() {
  mkrepo
  must mkdir .husky
  must git config core.hooksPath .husky
  doctor_install
  must chmod 644 .husky/pre-commit .husky/pre-push
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor with husky hooks that are not executable"
  assert_eq 0 "$(doctor_fails)" "FAIL lines"
}

test_doctor_fail_lines_name_the_fix() {
  mkrepo
  doctor_install
  printf 'check.lint.ci=on\n' > .gauntlet/config
  doctor_one_fail "FAIL bad check key check.lint.ci: attribute without a command; add check.lint=<command> or remove the line"
  printf 'check.lint=\n' > .gauntlet/config
  doctor_one_fail "FAIL bad check key check.lint: empty command; give check.lint a command or remove the line"
  printf 'check.lint=x\ncheck.lint.ci=maybe\n' > .gauntlet/config
  doctor_one_fail "FAIL bad check key check.lint.ci: .ci must be on or off, got [maybe]; write on or off"
}

test_doctor_loosen_and_remove_rows_are_not_stale() {
  mkrepo
  doctor_install
  printf 'type\ttarget\treason\tdate\tbranch\nloosen\tx: severity\tcovers the move\t2026-10-22\t-\nremove\told-rule\tgone\t2026-10-22\t-\n' > .gauntlet/exceptions.tsv
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor"
  assert_contains "$OUT" "ok no stale waivers"
}

test_promote_newline_id_is_unknown_rule() {
  mkrepo
  rule x severity=shadow
  rule y severity=shadow
  cp .gauntlet/rules/x.md "$TMP/before"
  run "$G" promote "$(printf 'x\ny')"
  assert_eq 2 "$STATUS" "promote with a newline in the id"
  assert_contains "$OUT" "unknown rule"
  same_file "$TMP/before" .gauntlet/rules/x.md
}

test_promote_dash_x_id_is_unknown_rule() {
  mkrepo
  rule x severity=shadow
  run "$G" promote -x
  assert_eq 2 "$STATUS" "promote -x"
  assert_contains "$OUT" "unknown rule -x"
}

test_promote_unreadable_rule_names_rule() {
  mkrepo
  printf -- '---\nid: bad\nseverity: shadow\n' > .gauntlet/rules/bad.md
  run "$G" promote bad
  assert_eq 2 "$STATUS" "promote with an unclosed frontmatter"
  assert_contains "$OUT" "cannot read rule bad; run gauntlet doctor"
  printf 'no frontmatter\nseverity: shadow\n' > .gauntlet/rules/nofm.md
  run "$G" promote nofm
  assert_eq 2 "$STATUS" "promote with no frontmatter"
  assert_contains "$OUT" "cannot read rule nofm; run gauntlet doctor"
}

test_promote_keeps_spacing_variants() {
  mkrepo
  printf -- '---\nid: a\nseverity:shadow  # c\nfix: x\n---\nbody\n' > .gauntlet/rules/a.md
  printf -- '---\nid: a\nseverity:block  # c\nfix: x\n---\nbody\n' > "$TMP/want-a"
  printf -- '---\nid: b\nseverity:\tshadow\t# c\n---\n' > .gauntlet/rules/b.md
  printf -- '---\nid: b\nseverity:\tblock\t# c\n---\n' > "$TMP/want-b"
  run "$G" promote a
  assert_eq 0 "$STATUS" "promote a"
  same_file "$TMP/want-a" .gauntlet/rules/a.md
  run "$G" promote b
  assert_eq 0 "$STATUS" "promote b"
  same_file "$TMP/want-b" .gauntlet/rules/b.md
}

test_status_rejects_calendar_invalid_today() {
  mkrepo
  rule x severity=shadow since=2026-10-22
  run env GAUNTLET_TODAY=2026-02-31 "$G" status
  assert_eq 2 "$STATUS" "status with 2026-02-31"
  assert_contains "$OUT" "GAUNTLET_TODAY"
  run env GAUNTLET_TODAY=2026-13-45 "$G" status
  assert_eq 2 "$STATUS" "status with 2026-13-45"
  assert_contains "$OUT" "GAUNTLET_TODAY"
}

test_promote_due_skips_calendar_invalid_since() {
  mkrepo
  status_due_for 2026-02-31 2026-10-30
  assert_not_contains "$OUT" "promote due"
}

test_promote_due_not_for_a_since_a_week_in_the_future() {
  mkrepo
  status_due_for 2026-11-08 2026-10-30
  assert_not_contains "$OUT" "promote due"
}

test_days_between_calendar_edges() {
  status_lib
  assert_eq 2 "$(days_between 0000-02-28 0000-03-01)" "year 0 is a leap year"
  assert_eq 60 "$(days_between 0000-01-01 0000-03-01)" "January and February of year 0"
  assert_eq 1 "$(days_between 2100-02-28 2100-03-01)" "2100 is not a leap year"
  assert_eq 2 "$(days_between 2000-02-28 2000-03-01)" "2000 is a leap year"
  assert_eq 146097 "$(days_between 2000-03-01 2400-03-01)" "400 years"
  assert_eq 7 "$(days_between 2026-10-23 2026-10-30)" "a week"
  assert_eq -9 "$(days_between 2026-11-08 2026-10-30)" "a future since"
}

test_valid_date_rejects_impossible_days() {
  status_lib
  for d in 2028-02-29 2026-02-28 2000-02-29 0000-02-29 2026-12-31; do
    valid_date "$d" || fail "$d should be valid"
  done
  for d in 2026-02-29 2026-02-31 2026-04-31 2026-13-01 2026-00-10 2026-01-00 2026-01-32 2026-1-01; do
    if valid_date "$d"; then fail "$d should be rejected"; fi
  done
}

test_status_file_order_ignores_locale() {
  if ! locale -a 2>/dev/null | grep -qiE '^en_US\.utf-?8$'; then
    skip "en_US.UTF-8 is not installed; the locale check did not run"
    return 77
  fi
  mkrepo
  rule a
  printf 'a\tsrc/a.ts\tf1\t3\na\tsrc/B.ts\tf2\t3\n' > .gauntlet/baseline.tsv
  env GAUNTLET_TODAY=2026-10-30 LC_ALL=C "$G" status > "$TMP/c.out" || fail "status in C exits $?"
  env GAUNTLET_TODAY=2026-10-30 LC_ALL=en_US.UTF-8 "$G" status > "$TMP/en.out" || fail "status in en_US exits $?"
  same_file "$TMP/c.out" "$TMP/en.out"
  assert_eq "| src/B.ts | 3 |" "$(grep '^| src/' "$TMP/en.out" | head -n 1)" "first file row"
}

test_status_directory_in_place_of_status_md_exits_2() {
  mkrepo
  rule a
  printf 'a\tsrc/x.ts\tf1\t1\n' > .gauntlet/baseline.tsv
  must mkdir .gauntlet/STATUS.md
  run env GAUNTLET_TODAY=2026-10-30 "$G" status
  assert_eq 2 "$STATUS" "status"
  assert_contains "$OUT" "STATUS.md is a directory"
  assert_eq "" "$(ls -A .gauntlet/STATUS.md)" "nothing written inside the directory"
}

test_status_escapes_pipe_in_path() {
  mkrepo
  rule a
  printf 'a\tsrc/a|b.ts\tf1\t2\n' > .gauntlet/baseline.tsv
  run env GAUNTLET_TODAY=2026-10-30 "$G" status
  assert_eq 0 "$STATUS" "status"
  assert_contains "$OUT" "| src/a\\|b.ts | 2 |"
}

test_status_replaces_status_md_by_rename() {
  mkrepo
  rule a
  printf 'a\tsrc/x.ts\tf1\t1\n' > .gauntlet/baseline.tsv
  env GAUNTLET_TODAY=2026-10-30 "$G" status > /dev/null || fail "first status exits $?"
  before=$(inode_of .gauntlet/STATUS.md)
  env GAUNTLET_TODAY=2026-10-30 "$G" status > /dev/null || fail "second status exits $?"
  after=$(inode_of .gauntlet/STATUS.md)
  if [ "$before" = "$after" ]; then fail "STATUS.md was rewritten in place; it must be replaced by a rename"; fi
}

test_status_leaves_no_temp_file() {
  mkrepo
  rule a
  printf 'a\tsrc/x.ts\tf1\t1\n' > .gauntlet/baseline.tsv
  run env GAUNTLET_TODAY=2026-10-30 "$G" status
  assert_eq 0 "$STATUS" "status"
  leftover=0
  for f in .gauntlet/STATUS*; do
    if [ "$f" != .gauntlet/STATUS.md ] && [ -e "$f" ]; then leftover=1; fi
  done
  assert_eq 0 "$leftover" "no temp file left in .gauntlet"
}

test_check_staged_records_times_for_status() {
  mkrepo
  rule slowrule "detector=sh -c 'sleep 0.2' {files}" paths=src/**
  must git add -A
  must git commit -q -m rule
  mkdir -p src
  printf 'x\n' > src/a.ts
  must git add src/a.ts
  run env GAUNTLET_COMMIT_BUDGET_MS=1 "$G" check --staged
  assert_eq 0 "$STATUS" "check --staged"
  assert_contains "$(cat "$(commit_times_file)")" "slowrule"
  run env GAUNTLET_TODAY=2026-10-30 GAUNTLET_COMMIT_BUDGET_MS=1 "$G" status
  assert_eq 0 "$STATUS" "status"
  assert_contains "$OUT" "slow: slowrule "
  assert_contains "$OUT" "ms (consider stage: push)"
  assert_eq "" "$(git status --porcelain | grep gauntlet-time || true)" "the time file is never in the work tree"
}

test_status_linked_worktree_reads_its_own_times() {
  mkrepo
  rule slowrule "detector=sh -c 'sleep 0.2' {files}" paths=src/**
  must git add -A
  must git commit -q -m rule
  must git worktree add -q "$TMP/wt" -b feature
  must cd "$TMP/wt"
  mkdir -p src
  printf 'x\n' > src/a.ts
  must git add src/a.ts
  run env GAUNTLET_COMMIT_BUDGET_MS=1 "$G" check --staged
  assert_eq 0 "$STATUS" "check --staged in the worktree"
  run env GAUNTLET_TODAY=2026-10-30 GAUNTLET_COMMIT_BUDGET_MS=1 "$G" status
  assert_contains "$OUT" "slow: slowrule "
  must cd "$TMP/repo"
  run env GAUNTLET_TODAY=2026-10-30 GAUNTLET_COMMIT_BUDGET_MS=1 "$G" status
  assert_not_contains "$OUT" "slow:"
}

test_check_staged_unwritable_git_dir_keeps_exit_code() {
  if [ "$(id -u)" -eq 0 ]; then
    skip "running as root: a read-only git dir is still writable here"
    return 77
  fi
  mkrepo
  rule slowrule "detector=sh -c 'sleep 0.2' {files}" paths=src/**
  must git add -A
  must git commit -q -m rule
  mkdir -p src
  printf 'x\n' > src/a.ts
  must git add src/a.ts
  must chmod 555 .git
  run env GAUNTLET_COMMIT_BUDGET_MS=1 "$G" check --staged
  must chmod 755 .git
  assert_eq 0 "$STATUS" "check --staged with an unwritable git dir"
  if [ -e "$(commit_times_file)" ]; then fail "the time file was written"; fi
}

test_check_ignores_keys_it_does_not_know() {
  mkrepo
  printf 'bogus=1\ntouched=off\n' > .gauntlet/config
  must git add -A
  must git commit -q -m config
  must git checkout -q -b feature
  # A changed path that starts with the words of the unknown key's message: a key that
  # check did not know must never become a check that runs.
  printf 'x\n' > configx.txt
  must git add configx.txt
  must git commit -q -m change
  run "$G" check --ci
  assert_eq 0 "$STATUS" "check --ci with an unknown config key"
  assert_contains "$OUT" "gauntlet: ok"
}
