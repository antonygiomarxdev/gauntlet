# shellcheck shell=bash
# shellcheck disable=SC2153 # ROOT, G, STATUS and OUT are set by test/lib.sh
# Tests for status, promote and doctor (lib/status.sh). Each test runs in a fresh
# repo under $TMP. GAUNTLET_TODAY pins the clock wherever a date matters.

# The pre-push gate text has one source, lib/hooks.sh; the tests read it there and never paste it.
STATUS_TEST_GATE_CI=$(hook_const HOOK_GATE_CI)
STATUS_TEST_SHARED_STAGED=$(hook_const HOOK_SHARED_STAGED)
STATUS_TEST_SHARED_CI=$(hook_const HOOK_SHARED_CI)
STATUS_TEST_CMD_CI=$(hook_const GAUNTLET_CMD_CI)

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

# A rule file that cannot be written is exit 2 with its path, and is left as it was.
test_promote_cannot_write_the_rule_file() {
  [ "$(id -u)" -ne 0 ] || { skip "root writes any file"; return 77; }
  mkrepo
  rule x severity=shadow
  must chmod 444 .gauntlet/rules/x.md
  cp .gauntlet/rules/x.md "$TMP/before"
  run "$G" promote x
  assert_eq 2 "$STATUS" "promote: $OUT"
  assert_contains "$OUT" "gauntlet: cannot write "
  assert_contains "$OUT" ".gauntlet/rules/x.md"
  assert_not_contains "$OUT" "promoted"
  same_file "$TMP/before" .gauntlet/rules/x.md
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
  printf 'pre-commit:\n  commands:\n    gauntlet:\n      run: .gauntlet/bin/gauntlet check --staged\npre-push:\n  commands:\n    gauntlet:\n      run: %s\n      use_stdin: true\n' "$STATUS_TEST_CMD_CI" >> lefthook.yml
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor with the snippet"
  assert_contains "$OUT" "ok gate in lefthook.yml"
}

# A lefthook pre-push command gets no stdin unless it says use_stdin: true, and then the gate sees
# no ref lines and judges the checked-out branch whatever git pushes. doctor said ok to that.
test_doctor_fails_a_lefthook_pre_push_gate_without_use_stdin() {
  mkrepo
  printf 'pre-commit:\n  commands:\n    gauntlet:\n      run: .gauntlet/bin/gauntlet check --staged\npre-push:\n  commands:\n    gauntlet:\n      run: %s\n' "$STATUS_TEST_CMD_CI" > lefthook.yml
  doctor_install
  doctor_one_fail "FAIL lefthook pre-push gate in lefthook.yml has no use_stdin: true, so it judges the checked-out branch whatever git pushes: add use_stdin: true"
  printf '      use_stdin: true\n' >> lefthook.yml
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor with use_stdin: true: $OUT"
  assert_contains "$OUT" "ok gate in lefthook.yml"
}

# status_lefthook <run line> <pre-push extra line>: a lefthook.yml whose pre-push command is
# <run line> followed by <extra line> (both indented as written), in a repo that has the runner.
status_lefthook() {
  mkrepo
  printf 'pre-commit:\n  commands:\n    gauntlet:\n      run: .gauntlet/bin/gauntlet check --staged\npre-push:\n  commands:\n    gauntlet:\n%s\n%s\n' "$1" "$2" > lefthook.yml
  doctor_install
}

# A commented line is not a setting: use_stdin in a comment passes no stdin to the gate.
test_doctor_does_not_take_a_commented_use_stdin_for_the_switch() {
  status_lefthook "      run: $STATUS_TEST_CMD_CI" '      # use_stdin: true'
  doctor_one_fail "FAIL lefthook pre-push gate in lefthook.yml has no use_stdin: true, so it judges the checked-out branch whatever git pushes: add use_stdin: true"
  # A comma in the comment puts the words where a flow mapping's next key would start.
  status_lefthook "      run: $STATUS_TEST_CMD_CI" '      # off for now, use_stdin: true'
  doctor_one_fail "FAIL lefthook pre-push gate in lefthook.yml has no use_stdin: true"
}

test_doctor_takes_use_stdin_with_a_trailing_comment() {
  status_lefthook "      run: $STATUS_TEST_CMD_CI" '      use_stdin: true  # why: the gate reads the ref lines'
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor: $OUT"
  assert_contains "$OUT" "ok gate in lefthook.yml"
}

# lefthook's `jobs` are a list: use_stdin may be the first key of an item, on the line of its "- ".
# That is the switch, with the value it needs.
test_doctor_takes_use_stdin_as_the_first_key_of_a_list_item() {
  mkrepo
  printf 'pre-commit:\n  jobs:\n    - run: .gauntlet/bin/gauntlet check --staged\npre-push:\n  jobs:\n    - use_stdin: true\n      run: %s\n' "$STATUS_TEST_CMD_CI" > lefthook.yml
  doctor_install
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor: $OUT"
  assert_contains "$OUT" "ok gate in lefthook.yml"
  printf 'pre-commit:\n  jobs:\n    - run: .gauntlet/bin/gauntlet check --staged\npre-push:\n  jobs:\n    - use_stdin: false\n      run: %s\n' "$STATUS_TEST_CMD_CI" > lefthook.yml
  doctor_one_fail "FAIL lefthook pre-push gate in lefthook.yml has no use_stdin: true"
}

# Text inside a block scalar that reads like the setting is not the setting.
test_doctor_does_not_take_use_stdin_inside_a_block_scalar_for_the_switch() {
  status_lefthook "      run: $STATUS_TEST_CMD_CI" '      description: |
        remember: use_stdin: true'
  doctor_one_fail "FAIL lefthook pre-push gate in lefthook.yml has no use_stdin: true"
}

# The gate commands are read the same way: a commented-out command is not configured.
test_doctor_does_not_take_a_commented_out_gate_command_for_the_gate() {
  mkrepo
  printf 'pre-commit:\n  commands:\n    gauntlet:\n      # run: .gauntlet/bin/gauntlet check --staged\npre-push:\n  commands:\n    gauntlet:\n      # run: %s\n      use_stdin: true\n' "$STATUS_TEST_CMD_CI" > lefthook.yml
  doctor_install
  doctor_one_fail "FAIL gate missing from lefthook.yml: run gauntlet install-hooks"
}

# The switch is spelled the way each lefthook config format spells it; prek has no such switch.
test_doctor_reads_use_stdin_in_every_lefthook_format_and_asks_none_of_prek() {
  mkrepo
  doctor_install
  local cmds="run = \"$STATUS_TEST_CMD_CI\" # .gauntlet/bin/gauntlet check --staged"
  printf '%s\n' "$cmds" > lefthook.toml
  run "$G" doctor
  assert_eq 1 "$STATUS" "toml without use_stdin: $OUT"
  assert_contains "$OUT" "FAIL lefthook pre-push gate in lefthook.toml has no use_stdin: true"
  printf '%s\nuse_stdin = true\n' "$cmds" > lefthook.toml
  run "$G" doctor
  assert_eq 0 "$STATUS" "toml with use_stdin = true: $OUT"
  # A TOML comment may follow the value with no blank between.
  printf '%s\nuse_stdin = true# why\n' "$cmds" > lefthook.toml
  run "$G" doctor
  assert_eq 0 "$STATUS" "toml with use_stdin = true# why: $OUT"
  rm lefthook.toml
  printf '{"run": "%s", "x": ".gauntlet/bin/gauntlet check --staged", "use_stdin": true}\n' "$STATUS_TEST_CMD_CI" > .lefthook.json
  run "$G" doctor
  assert_eq 0 "$STATUS" "json with \"use_stdin\": true: $OUT"
  printf '{"run": "%s", "x": ".gauntlet/bin/gauntlet check --staged", "use_stdin": false}\n' "$STATUS_TEST_CMD_CI" > .lefthook.json
  run "$G" doctor
  assert_eq 1 "$STATUS" "json with use_stdin false: $OUT"
  rm .lefthook.json
  printf -- '- repo: local\n  hooks:\n    - id: gauntlet\n      entry: .gauntlet/bin/gauntlet check --staged\n    - id: gauntlet-ci\n      entry: %s\n' "$STATUS_TEST_CMD_CI" > .pre-commit-config.yaml
  run "$G" doctor
  assert_eq 0 "$STATUS" "prek config needs no use_stdin: $OUT"
  assert_contains "$OUT" "ok gate in .pre-commit-config.yaml"
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
  assert_contains "$OUT" "FAIL pre-commit gate missing from $TMP/shared/pre-commit: add this line by hand as the first command, after the shebang line if there is one: $STATUS_TEST_SHARED_STAGED"
  assert_contains "$OUT" "FAIL pre-push gate missing from $TMP/shared/pre-push: add this line by hand as the first command, after the shebang line if there is one: $STATUS_TEST_SHARED_CI"
  assert_not_contains "$OUT" "install-hooks"
  printf '%s\n' "$STATUS_TEST_SHARED_STAGED" > "$TMP/shared/pre-commit"
  printf '%s\n' "$STATUS_TEST_SHARED_CI" > "$TMP/shared/pre-push"
  must chmod +x "$TMP/shared/pre-commit" "$TMP/shared/pre-push"
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor after the gate lines are added by hand"
}

# R53, review D M6: a plain gate line in a shared hooks directory fails every commit and push of a
# repo that has no .gauntlet/, so doctor does not accept it, and says why instead of "missing". The
# plain line (either form) is rejected; install-hooks says to replace it by the guarded one.
test_doctor_rejects_a_plain_gate_in_a_shared_hooks_dir_and_says_why() {
  mkrepo
  must mkdir "$TMP/shared"
  must git config core.hooksPath "$TMP/shared"
  doctor_install
  printf '%s\n' '.gauntlet/bin/gauntlet check --staged  # gauntlet' > "$TMP/shared/pre-commit"
  printf '%s\n' "$STATUS_TEST_GATE_CI" > "$TMP/shared/pre-push"
  must chmod +x "$TMP/shared/pre-commit" "$TMP/shared/pre-push"
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor: $OUT"
  assert_eq 2 "$(doctor_fails)" "one FAIL per hook: $OUT"
  assert_contains "$OUT" "FAIL pre-commit gate in $TMP/shared/pre-commit: shared hooks directory: the gate must use the guarded form; run gauntlet install-hooks to see it"
  assert_contains "$OUT" "FAIL pre-push gate in $TMP/shared/pre-push: shared hooks directory: the gate must use the guarded form; run gauntlet install-hooks to see it"
  printf '%s\n' '.gauntlet/bin/gauntlet check --staged || exit $?  # gauntlet' > "$TMP/shared/pre-commit"
  run "$G" doctor
  assert_contains "$OUT" "FAIL pre-commit gate in $TMP/shared/pre-commit: shared hooks directory: the gate must use the guarded form"
  run "$G" install-hooks
  assert_contains "$OUT" "ACTION NEEDED: replace the line ending in \"# gauntlet\" in $TMP/shared/pre-commit with:"$'\n'"$STATUS_TEST_SHARED_STAGED"
  printf '%s\n' "$STATUS_TEST_SHARED_STAGED" > "$TMP/shared/pre-commit"
  printf '%s\n' "$STATUS_TEST_SHARED_CI" > "$TMP/shared/pre-push"
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor with the guarded lines: $OUT"
}

# A script that serves both hooks of a shared hooks directory: doctor wants the guarded gates inside
# the tests on the hook's name, says so for a plain gate there, and is satisfied by the guarded ones
# (review D M1: the print branch of the one-script check had no test).
test_doctor_checks_a_script_that_serves_both_hooks_of_a_shared_hooks_dir() {
  mkrepo
  must mkdir "$TMP/shared"
  printf '#!/bin/sh\necho shared\n' > "$TMP/shared/pre-commit"
  must chmod 755 "$TMP/shared/pre-commit"
  must ln -s pre-commit "$TMP/shared/pre-push"
  must git config core.hooksPath "$TMP/shared"
  doctor_install
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor: $OUT"
  assert_eq 1 "$(doctor_fails)" "one FAIL for the one script, not one per hook: $OUT"
  assert_contains "$OUT" "FAIL $TMP/shared/pre-commit and $TMP/shared/pre-push are the same file, so a gate line in it would run in both hooks: run gauntlet install-hooks and add by hand the lines it prints"
  # shellcheck disable=SC2016 # the hook text holds ${0##*/}, which must not expand here
  printf '#!/bin/sh\nif [ "${0##*/}" = pre-commit ]; then\n.gauntlet/bin/gauntlet check --staged || exit $?  # gauntlet\nfi\nif [ "${0##*/}" = pre-push ]; then\n%s\nfi\n' "$STATUS_TEST_GATE_CI" > "$TMP/shared/pre-commit"
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor with plain gates in a shared script: $OUT"
  assert_contains "$OUT" "are the same file, so a gate line in it would run in both hooks"
  # shellcheck disable=SC2016 # as above
  printf '#!/bin/sh\nif [ "${0##*/}" = pre-commit ]; then\n%s\nfi\nif [ "${0##*/}" = pre-push ]; then\n%s\nfi\n' "$STATUS_TEST_SHARED_STAGED" "$STATUS_TEST_SHARED_CI" > "$TMP/shared/pre-commit"
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor with the guarded gates: $OUT"
  assert_contains "$OUT" "ok pre-commit gate in $TMP/shared/pre-commit"
  assert_contains "$OUT" "ok pre-push gate in $TMP/shared/pre-commit"
}

# An own hooks directory still wants the plain gate, and says nothing about a shared one.
test_doctor_says_nothing_about_a_shared_hooks_dir_for_an_own_hooks_dir() {
  mkrepo
  doctor_install
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor: $OUT"
  assert_not_contains "$OUT" "shared hooks directory"
}

# The guarded form that install-hooks prints for a shared hooks directory is the one doctor asks for.
test_doctor_accepts_the_guarded_form_in_a_shared_hooks_dir() {
  mkrepo
  must mkdir "$TMP/shared"
  must git config core.hooksPath "$TMP/shared"
  doctor_install
  printf '%s\n' "$STATUS_TEST_SHARED_STAGED" > "$TMP/shared/pre-commit"
  printf '%s\n' "$STATUS_TEST_SHARED_CI" > "$TMP/shared/pre-push"
  must chmod +x "$TMP/shared/pre-commit" "$TMP/shared/pre-push"
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor with the guarded lines: $OUT"
  assert_contains "$OUT" "ok pre-commit gate in $TMP/shared/pre-commit"
  assert_contains "$OUT" "ok pre-push gate in $TMP/shared/pre-push"
}

# The guarded form is for a shared directory; an own hooks directory still wants the plain gate.
test_doctor_does_not_accept_the_guarded_form_in_an_own_hooks_dir() {
  mkrepo
  doctor_install
  printf '%s\n' "$STATUS_TEST_SHARED_STAGED" > .git/hooks/pre-commit
  must chmod +x .git/hooks/pre-commit
  run "$G" doctor
  assert_contains "$OUT" "FAIL pre-commit gate missing from .git/hooks/pre-commit"
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

test_doctor_accepts_a_check_named_BAD() {
  mkrepo
  doctor_install
  printf 'check.BAD=echo hi\n' >> .gauntlet/config
  run "$G" doctor
  assert_eq 0 "$(doctor_fails)" "FAIL lines: $OUT"
  assert_not_contains "$OUT" "bad check key"
}

test_doctor_invalid_check_name_says_what_a_name_may_hold() {
  mkrepo
  doctor_install
  printf 'check.my check=echo hi\n' >> .gauntlet/config
  doctor_one_fail "FAIL bad check key check.my check: name [my check] must use letters, digits, - and _"
}

test_doctor_accepts_a_crlf_config() {
  mkrepo
  doctor_install
  printf 'base=main\r\ntouched=on\r\ncheck.hello=echo hi\r\ncheck.hello.ci=on\r\n' > .gauntlet/config
  run "$G" doctor
  assert_eq 0 "$(doctor_fails)" "FAIL lines: $OUT"
  assert_contains "$OUT" "ok config keys"
  assert_not_contains "$OUT" "touched must be"
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
  doctor_one_fail "FAIL .gauntlet/lib lacks files the runner sources (core.sh"
  assert_contains "$OUT" "run gauntlet install to re-vendor"
}

test_doctor_runner_bin_directory_fails() {
  mkrepo
  doctor_install
  must rm -f .gauntlet/bin/gauntlet
  must mkdir .gauntlet/bin/gauntlet
  doctor_one_fail "FAIL .gauntlet/bin or .gauntlet/lib is broken or missing"
}

# A runner that exists and cannot run is told apart from a missing or broken one, with the words
# install-hooks uses.
test_doctor_runner_not_executable_fails() {
  mkrepo
  doctor_install
  must chmod -x .gauntlet/bin/gauntlet
  doctor_one_fail "FAIL runner at $TMP/repo/.gauntlet/bin/gauntlet is not executable; run chmod +x '$TMP/repo/.gauntlet/bin/gauntlet'"
  must chmod 755 .gauntlet/bin/gauntlet
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor after chmod +x: $OUT"
}

# R60: the command in the FAIL is one word per value, as install-hooks prints it, whatever the
# directory of the repository is called.
test_doctor_chmod_command_for_a_runner_is_pasted_as_one_word_whatever_the_path_holds() {
  local dir="$TMP/it's a \$(touch\${IFS}PWNED) repo" cmd
  mkrepo
  doctor_install
  must mv "$TMP/repo" "$dir"
  must cd "$dir"
  must chmod -x .gauntlet/bin/gauntlet
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor: $OUT"
  cmd=$(printf '%s\n' "$OUT" | grep '^FAIL runner at ')
  cmd=${cmd#*; run }
  assert_eq "chmod +x '$TMP/it'\\''s a \$(touch\${IFS}PWNED) repo/.gauntlet/bin/gauntlet'" "$cmd" "the command"
  paste_run "$cmd"
  assert_eq 0 "$STATUS" "pasted: $OUT"
  assert_eq "" "$(ls -A "$TMP/paste/cwd")" "the pasted command made no file"
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor after the pasted command: $OUT"
}

# A lib file that is there and not empty but does not load is none of the list's business: only
# `--version`, which sources every lib, sees it. The generic FAIL says to re-vendor.
test_doctor_runner_with_a_lib_that_does_not_load_fails() {
  mkrepo
  doctor_install
  { printf 'fi\n'; cat .gauntlet/lib/paths.sh; } > "$TMP/paths.sh"
  must cp "$TMP/paths.sh" .gauntlet/lib/paths.sh
  doctor_one_fail "FAIL .gauntlet/bin or .gauntlet/lib is broken or missing"
  assert_not_contains "$OUT" "lacks files"
  assert_not_contains "$OUT" "ok runner"
}

test_doctor_runner_all_fine_is_ok() {
  mkrepo
  doctor_install
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor"
  assert_contains "$OUT" "ok runner .gauntlet/bin/gauntlet"
}

test_doctor_runner_checks_every_lib_file() {
  mkrepo
  doctor_install
  for f in .gauntlet/lib/*.sh; do
    case "$f" in
      */core.sh) continue ;;
    esac
    must cp "$f" "$TMP/lib.bak"
    must rm -f "$f"
    run "$G" doctor
    assert_eq 1 "$STATUS" "doctor with $f removed"
    assert_contains "$OUT" "FAIL .gauntlet/lib lacks files the runner sources (${f##*/}): run gauntlet install to re-vendor"
    must cp "$TMP/lib.bak" "$f"
  done
}

test_doctor_missing_builtin_format_fails() {
  mkrepo
  rule fmt
  doctor_install
  must rm .gauntlet/lib/formats/path-line.md
  doctor_one_fail "FAIL built-in format path-line is missing from .gauntlet/lib (rules: fmt)"
}

test_doctor_unknown_format_is_one_fail() {
  mkrepo
  rule r1 'format=nosuch'
  doctor_install
  doctor_one_fail "FAIL rule r1: format nosuch is unknown: use a built-in format or add .gauntlet/formats/nosuch.md"
}

test_doctor_missing_builtin_format_is_reported_once_per_format() {
  mkrepo
  rule r1
  rule r2
  doctor_install
  must rm .gauntlet/lib/formats/path-line.md
  doctor_one_fail "FAIL built-in format path-line is missing from .gauntlet/lib (rules: r1, r2): run gauntlet install from a gauntlet checkout"
}

test_doctor_format_key_decides_the_builtin() {
  mkrepo
  rule r1 'format=github'
  doctor_install
  must cp .gauntlet/lib/formats/path-line.md "$TMP/path-line.bak"
  must rm .gauntlet/lib/formats/path-line.md
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor when only path-line is missing and the rule uses github"
  must cp "$TMP/path-line.bak" .gauntlet/lib/formats/path-line.md
  must rm .gauntlet/lib/formats/github.md
  doctor_one_fail "FAIL built-in format github is missing from .gauntlet/lib (rules: r1)"
}

test_doctor_ast_grep_rule_defaults_to_github() {
  mkrepo
  rule r1 engine=ast-grep paths=nothing/**
  doctor_install
  must cp .gauntlet/lib/formats/github.md "$TMP/github.bak"
  must rm .gauntlet/lib/formats/github.md
  run "$G" doctor
  assert_contains "$OUT" "FAIL built-in format github is missing from .gauntlet/lib (rules: r1)"
  must cp "$TMP/github.bak" .gauntlet/lib/formats/github.md
  must rm .gauntlet/lib/formats/path-line.md
  run "$G" doctor
  assert_not_contains "$OUT" "path-line"
}

test_doctor_vendored_runner_does_not_demand_its_own_format_copies() {
  mkrepo
  rule r1 'format=github'
  doctor_install
  must rm .gauntlet/lib/formats/github.md
  run .gauntlet/bin/gauntlet doctor
  assert_not_contains "$OUT" "is missing from .gauntlet/lib"
}

test_doctor_no_vendored_lib_prints_only_the_runner_fail() {
  mkrepo
  rule r1
  doctor_install
  must rm -rf .gauntlet/lib
  doctor_one_fail "FAIL .gauntlet/lib lacks files the runner sources"
}

test_doctor_project_format_needs_no_vendored_copy() {
  mkrepo
  rule fmt "format=mine"
  must mkdir .gauntlet/formats
  must cp "$ROOT/lib/formats/path-line.md" .gauntlet/formats/mine.md
  doctor_install
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor with a project format"
  assert_eq 0 "$(doctor_fails)" "FAIL lines"
}

test_doctor_other_rules_error_shows_next_to_a_missing_tool() {
  mkrepo
  mkdir -p src
  printf 'x\n' > src/a.ts
  must git add -A
  must git commit -q -m content
  rule bd engine=linter "detector=sh -c 'echo nope >&2; exit 3' {files}"
  rule aghost engine=linter "detector=nosuchtool-gauntlet-xyz {files}"
  doctor_install
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor with a missing tool and a broken detector"
  assert_eq 2 "$(doctor_fails)" "FAIL lines"
  assert_contains "$OUT" "FAIL tool nosuchtool-gauntlet-xyz for rule aghost is missing"
  assert_contains "$OUT" "FAIL baseline cannot be checked: broken detector: bd: exit 3"
}

# The doctor line for a refused path already says what to do; "fix the rule or tool it names" is
# for a broken detector or a missing tool, which name one.
test_doctor_odd_path_line_does_not_point_at_a_rule_or_tool() {
  mkrepo
  rule todo
  printf 'x\n' > "$(printf 'a\tb.ts')"
  must git add -A
  must git commit -q -m content
  doctor_install
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor status"
  assert_contains "$OUT" 'FAIL baseline cannot be checked: path with a tab or newline: a\tb.ts; rename the file'
  assert_not_contains "$OUT" "fix the rule or tool it names"
}

test_doctor_broken_detector_line_still_points_at_the_rule_or_tool() {
  mkrepo
  mkdir -p src
  printf 'x\n' > src/a.ts
  must git add -A
  must git commit -q -m content
  rule bd engine=linter "detector=sh -c 'echo nope >&2; exit 3' {files}"
  doctor_install
  run "$G" doctor
  assert_contains "$OUT" "FAIL baseline cannot be checked: broken detector: bd: exit 3; fix the rule or tool it names"
}

test_doctor_partial_baseline_ignores_orphan_rows_until_the_tool_is_fixed() {
  mkrepo
  mkdir -p src
  printf 'TODO fix\n' > src/a.ts
  rule good
  rule bad engine=linter "detector=nosuchtool-gauntlet-xyz {files}"
  must git add -A
  must git commit -q -m content
  printf 'good\tsrc/a.ts\tTODO fix\t1\nghost\tx.txt\tfp\t3\n' > .gauntlet/baseline.tsv
  must git add -A
  must git commit -q -m baseline
  doctor_install
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor while the tool is missing"
  assert_eq 1 "$(doctor_fails)" "FAIL lines while the tool is missing"
  assert_contains "$OUT" "ok baseline is exact for the rules that can be measured"
  rule bad "engine=linter" "detector=sh -c 'exit 0' {files}"
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor after the tool is fixed"
  assert_contains "$OUT" "FAIL baseline differs from the code: run gauntlet baseline and commit it"
  assert_not_contains "$OUT" "FAIL tool"
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
  assert_contains "$OUT" "note tool for rule s1 not checked: the detector starts with 'rg', which is not a plain command name, so doctor cannot tell whether it exists"
  assert_contains "$OUT" "note tool for rule s2 not checked: the detector starts with \"rg\", which is not a plain command name"
  assert_contains "$OUT" "note tool for rule s3 not checked: the detector starts with FOO=1, which is not a plain command name"
  assert_contains "$OUT" "note tool for rule s4 not checked: the detector starts with \$LINT, which is not a plain command name"
  assert_contains "$OUT" "note tool for rule s5 not checked: the detector starts with ~/bin/tool, which is not a plain command name"
  assert_not_contains "$OUT" "ok tool s"
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

# The fix for a script rule without its row is a row in exceptions.tsv: no command
# writes it and the rule file cannot hold it. Every other problem still points at the rule.
test_doctor_script_row_problem_points_at_exceptions_tsv() {
  mkrepo
  rule needs engine=script
  doctor_install
  doctor_one_fail "FAIL rule needs: engine=script needs a script row for [needs] in .gauntlet/exceptions.tsv; fix .gauntlet/exceptions.tsv: add the row"
  assert_contains "$OUT" "type, target, reason, date, branch"
  assert_contains "$OUT" "script<TAB>needs<TAB><reason><TAB><YYYY-MM-DD><TAB>-"
  assert_not_contains "$OUT" "fix .gauntlet/rules/needs.md"
}

test_doctor_other_rule_problems_still_point_at_the_rule_file() {
  mkrepo
  rule empty engine=linter "detector="
  doctor_install
  doctor_one_fail "FAIL rule empty: detector must not be empty; fix .gauntlet/rules/empty.md"
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
  doctor_one_fail "FAIL pre-commit hook .git/hooks/pre-commit is not executable: chmod +x '.git/hooks/pre-commit'"
}

# gate_fixture: a repo with one commit-stage rule that forbids TODO, committed, so a new
# TODO in a later commit is a violation the gate blocks. The baseline stays empty.
gate_fixture() {
  mkrepo
  rule todo
  must git add -A
  must git commit -q -m rule
}

# violation_commit: stage a new TODO and commit it; leaves the commit's status in STATUS.
violation_commit() {
  must mkdir -p src
  printf 'TODO fix\n' > src/a.ts
  must git add src/a.ts
  run git commit -q -m violation
}

# husky_v9_case <hooks-path>: a husky v9 layout. git runs <hooks-path>/pre-commit, which is
# the husky wrapper; the wrapper sources .husky/pre-commit, so that file needs no exec bit.
husky_v9_case() {
  gate_fixture
  must mkdir -p .husky/_
  # shellcheck disable=SC2016 # the wrapper is written literally; it expands when git runs it
  printf '#!/bin/sh\n. "$(dirname "$0")/../pre-commit"\n' > .husky/_/pre-commit
  must chmod +x .husky/_/pre-commit
  must git config core.hooksPath "$1"
  doctor_install
  must chmod 644 .husky/pre-commit
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor with a non-executable v9 user hook"
  assert_eq 0 "$(doctor_fails)" "FAIL lines"
  violation_commit
  assert_eq 1 "$STATUS" "the wrapper runs the user hook, so the gate blocks the commit"
}

# dir_hook_case <hooks-path> <hook-dir>: a plain hooks dir that is not husky. git runs the file
# itself, so a non-executable hook is ignored and the gate does not run.
dir_hook_case() {
  gate_fixture
  must git config core.hooksPath "$1"
  doctor_install
  must chmod 644 "$2/pre-commit"
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor with a non-executable hook in $2"
  assert_contains "$OUT" "FAIL pre-commit hook $2/pre-commit is not executable: chmod +x '$2/pre-commit'"
  violation_commit
  assert_eq 0 "$STATUS" "git ignores the non-executable hook, so the gate does not run"
  assert_contains "$OUT" "was ignored because it's not set as executable"
}

test_husky_v9_layout_with_trailing_slash_runs_without_exec_bit() {
  husky_v9_case ".husky/_/"
}

test_husky_v9_layout_with_double_slash_runs_without_exec_bit() {
  husky_v9_case ".husky//_"
}

test_husky_v9_layout_with_parent_path_runs_without_exec_bit() {
  husky_v9_case ".husky/../.husky/_"
}

test_githooks_underscore_nonexec_hook_fails_and_git_ignores_it() {
  dir_hook_case ".githooks/_" ".githooks/_"
}

test_my_hooks_nonexec_hook_fails_and_git_ignores_it() {
  dir_hook_case "my_hooks" "my_hooks"
}

test_underscore_dir_nonexec_hook_fails_and_git_ignores_it() {
  dir_hook_case "x_/hooks" "x_/hooks"
}

test_doctor_nonexec_husky_v8_hook_fails() {
  mkrepo
  must mkdir .husky
  must git config core.hooksPath .husky
  doctor_install
  must chmod 644 .husky/pre-commit
  doctor_one_fail "FAIL pre-commit hook .husky/pre-commit is not executable: chmod +x '.husky/pre-commit'"
}

test_doctor_nonexec_husky_v9_hook_is_ok() {
  mkrepo
  must mkdir .husky
  must git config core.hooksPath .husky/_
  doctor_install
  must chmod 644 .husky/pre-commit .husky/pre-push
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor with husky v9 hooks that are not executable"
  assert_eq 0 "$(doctor_fails)" "FAIL lines"
}

test_husky_v8_nonexec_hook_is_ignored_by_git_and_doctor_fails() {
  mkrepo
  rule todo
  must git add -A
  must git commit -q -m rule
  must mkdir .husky
  must git config core.hooksPath .husky
  doctor_install
  must mkdir -p src
  printf 'TODO fix\n' > src/a.ts
  must git add src/a.ts
  run git commit -q -m violation
  assert_eq 1 "$STATUS" "an executable v8 hook runs the gate and blocks the commit"
  must chmod 644 .husky/pre-commit
  run git commit -q -m violation
  assert_eq 0 "$STATUS" "git ignores a non-executable v8 hook, so the gate does not run"
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor with the non-executable v8 hook"
  assert_contains "$OUT" "FAIL pre-commit hook .husky/pre-commit is not executable: chmod +x '.husky/pre-commit'"
}

test_doctor_hooks_path_with_tilde_resolves_like_install_hooks() {
  mkrepo
  must mkdir home
  export HOME="$TMP/repo/home"
  # shellcheck disable=SC2088 # git expands the ~ in core.hooksPath itself, as the test needs
  must git config core.hooksPath '~/.husky'
  doctor_install
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor with core.hooksPath=~/.husky"
  assert_contains "$OUT" "ok pre-commit gate in home/.husky/pre-commit"
  must chmod 644 home/.husky/pre-commit
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor with the v8 hook under HOME not executable"
  assert_contains "$OUT" "FAIL pre-commit hook home/.husky/pre-commit is not executable: chmod +x 'home/.husky/pre-commit'"
}

test_doctor_nonexec_pre_push_hook_fails() {
  mkrepo
  doctor_install
  must chmod 644 .git/hooks/pre-push
  doctor_one_fail "FAIL pre-push hook .git/hooks/pre-push is not executable: chmod +x '.git/hooks/pre-push'"
}

# The same for a hook: its path is shown from the repository root, so the pasted command runs there.
test_doctor_chmod_command_for_a_hook_is_pasted_as_one_word_whatever_the_path_holds() {
  local name="odd'dir \$(touch\${IFS}PWNED)" cmd
  mkrepo
  must git config core.hooksPath "$name"
  doctor_install
  must chmod 644 "$name/pre-commit"
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor: $OUT"
  cmd=$(printf '%s\n' "$OUT" | grep '^FAIL pre-commit hook ')
  cmd=${cmd#*: chmod}
  cmd="chmod$cmd"
  assert_eq "chmod +x 'odd'\\''dir \$(touch\${IFS}PWNED)/pre-commit'" "$cmd" "the command"
  paste_run "$cmd" "$TMP/repo"
  assert_eq 0 "$STATUS" "pasted: $OUT"
  if [ -e "$TMP/repo/PWNED" ]; then fail "the pasted command ran the text in the path"; fi
  if [ ! -x "$name/pre-commit" ]; then fail "the pasted command did not make the hook executable"; fi
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

test_doctor_malformed_config_line_fails() {
  mkrepo
  doctor_install
  printf 'touched on\n' > .gauntlet/config
  doctor_one_fail "FAIL config line 1 has no '=': write key=value"
  printf 'touched=off\ntouched:on\n' > .gauntlet/config
  doctor_one_fail "FAIL config line 2 has no '=': write key=value"
  printf 'touched=off\ncheck.lint echo hi\n' > .gauntlet/config
  doctor_one_fail "FAIL config line 2 has no '=': write key=value"
}

test_doctor_blank_and_comment_config_lines_are_ok() {
  mkrepo
  doctor_install
  printf '\n# a comment\n   \n\t# indented comment\ntouched=off\n\n' > .gauntlet/config
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor"
  assert_contains "$OUT" "ok config keys"
}

test_doctor_base_key_is_accepted() {
  mkrepo
  doctor_install
  printf 'base=main\ntouched=off\n' > .gauntlet/config
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor with base"
  assert_contains "$OUT" "ok config keys"
}

test_doctor_bom_before_a_comment_is_ok() {
  mkrepo
  doctor_install
  printf '\357\273\277# gauntlet config\ntouched=off\n' > .gauntlet/config
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor with a BOM before a comment"
  assert_contains "$OUT" "ok config keys"
}

test_doctor_bom_before_a_key_fails_with_the_bom_note() {
  mkrepo
  doctor_install
  printf '\357\273\277touched=off\n' > .gauntlet/config
  doctor_one_fail "FAIL config key "
  assert_contains "$OUT" "is not known; use base, touched or check.<name>; a byte-order mark is present on line 1"
}

test_check_ignores_a_bom_before_a_key() {
  mkrepo
  printf '\357\273\277check.lint=sh -c "exit 3"\ntouched=off\n' > .gauntlet/config
  must git add -A
  must git commit -q -m config
  run "$G" check --ci
  assert_eq 0 "$STATUS" "check --ci with a BOM before a declared check"
  assert_contains "$OUT" "gauntlet: ok"
}

test_check_accepts_a_bom_before_a_comment() {
  mkrepo
  printf '\357\273\277# gauntlet config\ntouched=off\n' > .gauntlet/config
  must git add -A
  must git commit -q -m config
  run "$G" check --ci
  assert_eq 0 "$STATUS" "check --ci with a BOM before a comment"
  assert_contains "$OUT" "gauntlet: ok"
}

test_doctor_empty_key_config_line_fails() {
  mkrepo
  doctor_install
  printf '=1\n' > .gauntlet/config
  doctor_one_fail "FAIL config line 1 has no key: write key=value"
}

test_doctor_config_problems_are_sorted() {
  mkrepo
  doctor_install
  printf 'zeta=1\nalpha=1\n' > .gauntlet/config
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor with two unknown keys"
  alpha=$(printf '%s\n' "$OUT" | grep -n 'config key alpha' | cut -d: -f1)
  zeta=$(printf '%s\n' "$OUT" | grep -n 'config key zeta' | cut -d: -f1)
  if [ -z "$alpha" ] || [ -z "$zeta" ]; then fail "both problems should be reported"; fi
  if [ "$alpha" -gt "$zeta" ]; then fail "problems are not sorted: alpha on line $alpha, zeta on line $zeta"; fi
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

test_valid_date_30_day_months() {
  status_lib
  valid_date 2026-11-30 || fail "2026-11-30 should be valid"
  for d in 2026-11-31 2026-06-31 2026-09-31; do
    if valid_date "$d"; then fail "$d should be rejected"; fi
  done
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

test_status_md_mode_follows_umask() {
  mkrepo
  rule a
  printf 'a\tsrc/x.ts\tf1\t1\n' > .gauntlet/baseline.tsv
  ( umask 022 && env GAUNTLET_TODAY=2026-10-30 "$G" status > /dev/null ) || fail "status under umask 022"
  assert_eq 644 "$(file_mode .gauntlet/STATUS.md)" "mode under umask 022"
  ( umask 002 && env GAUNTLET_TODAY=2026-10-30 "$G" status > /dev/null ) || fail "status under umask 002"
  assert_eq 664 "$(file_mode .gauntlet/STATUS.md)" "mode under umask 002"
}

test_status_removes_its_temp_when_the_rename_fails() {
  mkrepo
  rule a
  printf 'a\tsrc/x.ts\tf1\t1\n' > .gauntlet/baseline.tsv
  must mkdir "$TMP/shim"
  printf '#!/bin/sh\nexit 1\n' > "$TMP/shim/mv"
  must chmod +x "$TMP/shim/mv"
  run env PATH="$TMP/shim:$PATH" GAUNTLET_TODAY=2026-10-30 "$G" status
  assert_eq 2 "$STATUS" "status when the rename fails"
  assert_contains "$OUT" "cannot write .gauntlet/STATUS.md"
  leftover=0
  for f in .gauntlet/.STATUS.md.*; do
    if [ -e "$f" ]; then leftover=1; fi
  done
  assert_eq 0 "$leftover" "no temp file left after the failed rename"
  if [ -e .gauntlet/STATUS.md ]; then fail "STATUS.md was written although the rename failed"; fi
}

test_status_in_a_read_only_gauntlet_dir_fails_quietly() {
  if [ "$(id -u)" -eq 0 ]; then
    skip "running as root: a read-only directory is still writable here"
    return 77
  fi
  mkrepo
  rule a
  printf 'a\tsrc/x.ts\tf1\t1\n' > .gauntlet/baseline.tsv
  must chmod 555 .gauntlet
  run env GAUNTLET_TODAY=2026-10-30 "$G" status
  must chmod 755 .gauntlet
  assert_eq 2 "$STATUS" "status in a read-only .gauntlet"
  assert_contains "$OUT" "cannot write .gauntlet/STATUS.md"
  assert_not_contains "$OUT" "mktemp"
  assert_not_contains "$OUT" "Permission denied"
}

test_status_refuses_a_planted_temp_symlink() {
  mkrepo
  rule a
  printf 'a\tsrc/x.ts\tf1\t1\n' > .gauntlet/baseline.tsv
  printf 'victim\n' > "$TMP/victim"
  cat > "$TMP/planted.sh" <<EOF
#!/bin/sh
cd "$TMP/repo" || exit 9
ln -s "$TMP/victim" ".gauntlet/.STATUS.md.\$\$"
exec "$G" status
EOF
  must chmod +x "$TMP/planted.sh"
  run env GAUNTLET_TODAY=2026-10-30 "$TMP/planted.sh"
  assert_eq 2 "$STATUS" "status with a planted temp symlink"
  assert_contains "$OUT" "cannot write .gauntlet/STATUS.md"
  assert_eq "victim" "$(cat "$TMP/victim")" "the victim file is untouched"
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

# Every rule here sleeps 1 s, not 0.2: a seconds clock (BSD date) reads a shorter run
# as 0 ms, which is under the 1 ms budget these tests set.
test_check_staged_records_times_for_status() {
  mkrepo
  rule slowrule "detector=sh -c 'sleep 1' {files}" paths=src/**
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

test_check_staged_records_every_rule_time() {
  mkrepo
  rule slowone "detector=sh -c 'sleep 1' {files}" paths=src/**
  rule slowtwo "detector=sh -c 'sleep 1' {files}" paths=src/**
  must git add -A
  must git commit -q -m rules
  mkdir -p src
  printf 'x\n' > src/a.ts
  must git add src/a.ts
  run env GAUNTLET_COMMIT_BUDGET_MS=1 "$G" check --staged
  assert_eq 0 "$STATUS" "check --staged"
  run env GAUNTLET_TODAY=2026-10-30 GAUNTLET_COMMIT_BUDGET_MS=1 "$G" status
  assert_contains "$OUT" "slow: slowone "
  assert_contains "$OUT" "slow: slowtwo "
}

test_check_staged_time_file_replaces_the_previous_run() {
  mkrepo
  rule slowone "detector=sh -c 'sleep 1' {files}" paths=src/**
  must git add -A
  must git commit -q -m rules
  mkdir -p src
  printf 'x\n' > src/a.ts
  must git add src/a.ts
  run env GAUNTLET_COMMIT_BUDGET_MS=1 "$G" check --staged
  assert_eq 0 "$STATUS" "first check --staged"
  run env GAUNTLET_COMMIT_BUDGET_MS=1 "$G" check --staged
  assert_eq 0 "$STATUS" "second check --staged"
  lines=$(awk 'END { print NR }' "$(commit_times_file)")
  assert_eq 1 "$lines" "one row per rule after two runs"
}

test_check_staged_time_file_leaves_no_temp_file() {
  mkrepo
  rule slowone "detector=sh -c 'sleep 1' {files}" paths=src/**
  must git add -A
  must git commit -q -m rules
  mkdir -p src
  printf 'x\n' > src/a.ts
  must git add src/a.ts
  run env GAUNTLET_COMMIT_BUDGET_MS=1 "$G" check --staged
  assert_eq 0 "$STATUS" "check --staged"
  count=0
  for f in .git/gauntlet-time*; do
    if [ -e "$f" ]; then count=$((count + 1)); fi
  done
  assert_eq 1 "$count" "the time file and nothing else"
}

test_status_does_not_list_a_rule_without_a_time_row() {
  mkrepo
  rule fast
  rule other
  printf 'fast\t40\ngone\t9000\n' > "$(commit_times_file)"
  run env GAUNTLET_TODAY=2026-10-30 GAUNTLET_COMMIT_BUDGET_MS=0 "$G" status
  assert_eq 0 "$STATUS" "status"
  assert_contains "$OUT" "slow: fast 40 ms (consider stage: push)"
  assert_not_contains "$OUT" "slow: other"
  assert_not_contains "$OUT" "slow: gone"
}

test_status_linked_worktree_reads_its_own_times() {
  mkrepo
  rule slowrule "detector=sh -c 'sleep 1' {files}" paths=src/**
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
  rule slowrule "detector=sh -c 'sleep 1' {files}" paths=src/**
  must git add -A
  must git commit -q -m rule
  mkdir -p src
  printf 'x\n' > src/a.ts
  must git add src/a.ts
  must chmod 555 .git
  run env GAUNTLET_COMMIT_BUDGET_MS=1 "$G" check --staged
  must chmod 755 .git
  assert_eq 0 "$STATUS" "check --staged with an unwritable git dir"
  assert_not_contains "$OUT" "mktemp"
  if [ -e "$(commit_times_file)" ]; then fail "the time file was written"; fi
}

test_check_ignores_malformed_config_lines() {
  mkrepo
  printf 'touched on\n' > .gauntlet/config
  must git add -A
  must git commit -q -m config
  must git checkout -q -b feature
  # A changed path that starts with the words of the malformed line's message: a line
  # check ignores must never become a check that runs.
  printf 'x\n' > configx.txt
  must git add configx.txt
  must git commit -q -m change
  run "$G" check --ci
  assert_eq 0 "$STATUS" "check --ci with a malformed config line"
  assert_contains "$OUT" "gauntlet: ok"
}

test_check_named_like_a_row_tag_still_runs() {
  mkrepo
  printf 'check.UNKNOWN=sh -c "exit 3"\ncheck.UNKNOWN.ci=on\n' > .gauntlet/config
  must git add -A
  must git commit -q -m config
  run "$G" check --ci
  assert_eq 1 "$STATUS" "a check named UNKNOWN fails when it exits 3"
  assert_contains "$OUT" "UNKNOWN  exit 3"
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

# R47: a line that ends in "# gauntlet" and is not the current form is an older line, whatever
# it lacks. Before the flag the line judged the checked-out branch whatever git pushed; before the
# buffer it left the project's own pre-push commands without git's stdin. doctor says the line
# differs and how to get the current one.
test_doctor_flags_a_pre_push_line_that_is_not_the_current_form() {
  mkrepo
  doctor_install
  local old
  for old in \
    '.gauntlet/bin/gauntlet check --ci  # gauntlet' \
    '.gauntlet/bin/gauntlet check --ci || exit $?  # gauntlet' \
    '.gauntlet/bin/gauntlet check --ci --pre-push  # gauntlet' \
    '.gauntlet/bin/gauntlet check --ci --pre-push || exit $?  # gauntlet'; do
    printf '#!/bin/sh\n%s\n' "$old" > .git/hooks/pre-push
    doctor_one_fail "FAIL pre-push gate in .git/hooks/pre-push is an older gauntlet line (it differs from the current one): run gauntlet install-hooks"
  done
  run "$G" install-hooks
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor after install-hooks: $OUT"
  assert_contains "$OUT" "ok pre-push gate in .git/hooks/pre-push"
}

test_doctor_names_the_manual_line_for_an_old_pre_push_line() {
  mkrepo
  must mkdir "$TMP/shared"
  must git config core.hooksPath "$TMP/shared"
  doctor_install
  printf '%s\n' "$STATUS_TEST_SHARED_STAGED" > "$TMP/shared/pre-commit"
  printf '%s\n' '.gauntlet/bin/gauntlet check --ci --pre-push || exit $?  # gauntlet' > "$TMP/shared/pre-push"
  must chmod +x "$TMP/shared/pre-commit" "$TMP/shared/pre-push"
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor: $OUT"
  assert_contains "$OUT" "FAIL pre-push gate in $TMP/shared/pre-push is an older gauntlet line (it differs from the current one): replace the line ending in \"# gauntlet\" in $TMP/shared/pre-push with: $STATUS_TEST_SHARED_CI"
  assert_not_contains "$OUT" "run gauntlet install-hooks"
}

# R43 M-4: where an older gauntlet line already is, the advice says "replace", not "add": following
# "add" leaves both lines (and a duplicate YAML key in lefthook). install-hooks and doctor use the
# same words for the same file, and neither says "add" when a line of ours is there.
STATUS_TEST_OLD_CI='.gauntlet/bin/gauntlet check --ci --pre-push || exit $?  # gauntlet'

test_a_crlf_hook_with_an_older_gauntlet_line_is_told_to_replace_it() {
  mkrepo
  doctor_install
  printf '#!/bin/sh\r\n%s\r\necho x\r\n' "$STATUS_TEST_OLD_CI" > .git/hooks/pre-push
  must chmod 755 .git/hooks/pre-push
  cp .git/hooks/pre-push "$TMP/before"
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks: $OUT"
  assert_contains "$OUT" "ACTION NEEDED: replace the line ending in \"# gauntlet\" in .git/hooks/pre-push with:"$'\n'"$STATUS_TEST_GATE_CI"
  assert_not_contains "$OUT" "add to .git/hooks/pre-push"
  same_file "$TMP/before" .git/hooks/pre-push
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor: $OUT"
  assert_contains "$OUT" "FAIL pre-push gate in .git/hooks/pre-push is an older gauntlet line (it differs from the current one): replace the line ending in \"# gauntlet\" in .git/hooks/pre-push with: $STATUS_TEST_GATE_CI"
}

# A CRLF hook that holds the current line is done: the CR sits in the comment after the marker.
test_a_crlf_hook_that_holds_the_current_line_is_done() {
  mkrepo
  doctor_install
  printf '#!/bin/sh\r\n%s\r\necho x\r\n' "$STATUS_TEST_GATE_CI" > .git/hooks/pre-push
  must chmod 755 .git/hooks/pre-push
  run "$G" install-hooks
  assert_contains "$OUT" "already present in .git/hooks/pre-push"
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor: $OUT"
  assert_contains "$OUT" "ok pre-push gate in .git/hooks/pre-push"
}

test_a_shared_hooks_dir_hook_with_an_older_gauntlet_line_is_told_to_replace_it() {
  mkrepo
  must mkdir "$TMP/shared"
  must git config core.hooksPath "$TMP/shared"
  doctor_install
  printf '%s\n' "$STATUS_TEST_SHARED_STAGED" > "$TMP/shared/pre-commit"
  printf '%s\n' "$STATUS_TEST_OLD_CI" > "$TMP/shared/pre-push"
  must chmod +x "$TMP/shared/pre-commit" "$TMP/shared/pre-push"
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks: $OUT"
  assert_contains "$OUT" "ACTION NEEDED: replace the line ending in \"# gauntlet\" in $TMP/shared/pre-push with:"$'\n'"$STATUS_TEST_SHARED_CI"
  assert_not_contains "$OUT" "add to $TMP/shared/pre-push"
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor: $OUT"
  assert_contains "$OUT" "FAIL pre-push gate in $TMP/shared/pre-push is an older gauntlet line (it differs from the current one): replace the line ending in \"# gauntlet\" in $TMP/shared/pre-push with: $STATUS_TEST_SHARED_CI"
}

# The hook a project can have edited gets the same verdict from doctor and the same fix from
# install-hooks, which does it.
test_an_older_gauntlet_line_in_an_editable_hook_is_replaced_by_install_hooks() {
  mkrepo
  doctor_install
  printf '#!/bin/sh\n%s\necho x\n' "$STATUS_TEST_OLD_CI" > .git/hooks/pre-push
  must chmod 755 .git/hooks/pre-push
  run "$G" doctor
  assert_contains "$OUT" "FAIL pre-push gate in .git/hooks/pre-push is an older gauntlet line (it differs from the current one): run gauntlet install-hooks"
  run "$G" install-hooks
  assert_contains "$OUT" "updated gauntlet line in .git/hooks/pre-push"
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor after install-hooks: $OUT"
}

# R59: a hook with two or more lines of ours is a FAIL, whichever comes first (a stale line first
# drains git's stdin; a second line runs the gate twice), with the words install-hooks prints. Neither
# command edits the hook: the user keeps one line, the current form, and removes the others.
test_doctor_fails_a_hook_with_several_gauntlet_lines_and_install_hooks_leaves_it() {
  mkrepo
  doctor_install
  local body old='.gauntlet/bin/gauntlet check --ci  # gauntlet'
  for body in \
    "$old"$'\n'"$STATUS_TEST_GATE_CI" \
    "$STATUS_TEST_GATE_CI"$'\n'"$old" \
    "$STATUS_TEST_GATE_CI"$'\n'"$STATUS_TEST_GATE_CI" \
    "$old"$'\n'"$STATUS_TEST_OLD_CI"; do
    printf '#!/bin/sh\n%s\necho x\n' "$body" > .git/hooks/pre-push
    cp .git/hooks/pre-push "$TMP/before"
    doctor_one_fail "FAIL .git/hooks/pre-push has 2 lines ending in \"# gauntlet\" (lines 2, 3); keep one, the current form, and remove the others"
    run "$G" install-hooks
    assert_eq 0 "$STATUS" "install-hooks: $OUT"
    assert_contains "$OUT" "gauntlet: .git/hooks/pre-push has 2 lines ending in \"# gauntlet\" (lines 2, 3); keep one, the current form, and remove the others"$'\n'"$STATUS_TEST_GATE_CI"
    same_file "$TMP/before" .git/hooks/pre-push
    printf '#!/bin/sh\n%s\necho x\n' "$STATUS_TEST_GATE_CI" > .git/hooks/pre-push
    run "$G" doctor
    assert_eq 0 "$STATUS" "doctor after the hand edit: $OUT"
    assert_contains "$OUT" "ok pre-push gate in .git/hooks/pre-push"
  done
}

# R61: the same state in a shared hooks directory is a FAIL with the guarded-form sentence, as for a
# plain line alone; the guarded line alone is ok.
# shellcheck disable=SC2016 # the hook line holds $? that must not expand here
test_doctor_fails_a_shared_hook_that_has_the_guarded_line_and_a_marked_plain_line() {
  local staged_line='.gauntlet/bin/gauntlet check --staged || exit $?  # gauntlet'
  mkrepo
  must mkdir "$TMP/shared"
  must git config core.hooksPath "$TMP/shared"
  doctor_install
  printf '#!/bin/sh\n%s\n' "$STATUS_TEST_SHARED_STAGED" > "$TMP/shared/pre-commit"
  printf '#!/bin/sh\n%s\n' "$STATUS_TEST_SHARED_CI" > "$TMP/shared/pre-push"
  must chmod +x "$TMP/shared/pre-commit" "$TMP/shared/pre-push"
  run "$G" doctor
  assert_eq 0 "$STATUS" "the guarded lines alone: $OUT"
  assert_contains "$OUT" "ok pre-push gate in $TMP/shared/pre-push"
  printf '#!/bin/sh\n%s\n%s\n' "$STATUS_TEST_SHARED_CI" "$STATUS_TEST_GATE_CI" > "$TMP/shared/pre-push"
  doctor_one_fail "FAIL pre-push gate in $TMP/shared/pre-push: shared hooks directory: the gate must use the guarded form; run gauntlet install-hooks to see it"
  printf '#!/bin/sh\n%s\n' "$STATUS_TEST_SHARED_CI" > "$TMP/shared/pre-push"
  printf '#!/bin/sh\n%s\n%s\n' "$STATUS_TEST_SHARED_STAGED" "$staged_line" > "$TMP/shared/pre-commit"
  doctor_one_fail "FAIL pre-commit gate in $TMP/shared/pre-commit: shared hooks directory: the gate must use the guarded form; run gauntlet install-hooks to see it"
}

test_doctor_fails_a_pre_commit_hook_with_several_gauntlet_lines() {
  mkrepo
  doctor_install
  local staged='.gauntlet/bin/gauntlet check --staged || exit $?  # gauntlet'
  printf '#!/bin/sh\n%s\n%s\n' "$staged" "$staged" > .git/hooks/pre-commit
  doctor_one_fail "FAIL .git/hooks/pre-commit has 2 lines ending in \"# gauntlet\" (lines 2, 3); keep one, the current form, and remove the others"
}

# The lines are counted in a hook install-hooks would not edit anyway, and the count names every
# line.
test_doctor_counts_the_gauntlet_lines_of_a_crlf_hook() {
  mkrepo
  doctor_install
  printf '#!/bin/sh\r\n%s\r\n%s\r\necho x\r\n%s\r\n' "$STATUS_TEST_OLD_CI" "$STATUS_TEST_GATE_CI" "$STATUS_TEST_OLD_CI" > .git/hooks/pre-push
  doctor_one_fail "FAIL .git/hooks/pre-push has 3 lines ending in \"# gauntlet\" (lines 2, 3, 5); keep one, the current form, and remove the others"
}

# One script for both hooks: each stage's lines are counted by themselves.
# shellcheck disable=SC2016 # the hook text holds ${0##*/} and $? that must not expand here
test_doctor_counts_gauntlet_lines_in_a_script_that_serves_both_hooks() {
  mkrepo
  doctor_install
  printf '#!/bin/sh\nif [ "${0##*/}" = pre-commit ]; then\n.gauntlet/bin/gauntlet check --staged || exit $?  # gauntlet\nfi\nif [ "${0##*/}" = pre-push ]; then\n%s\n%s\nfi\n' "$STATUS_TEST_GATE_CI" "$STATUS_TEST_OLD_CI" > .git/hooks/pre-commit
  must chmod 755 .git/hooks/pre-commit
  must rm .git/hooks/pre-push
  must ln .git/hooks/pre-commit .git/hooks/pre-push
  doctor_one_fail "FAIL .git/hooks/pre-commit has 2 lines ending in \"# gauntlet\" (lines 6, 7); keep one, the current form, and remove the others"
  printf '#!/bin/sh\nif [ "${0##*/}" = pre-commit ]; then\n.gauntlet/bin/gauntlet check --staged || exit $?  # gauntlet\n.gauntlet/bin/gauntlet check --staged || exit $?  # gauntlet\nfi\nif [ "${0##*/}" = pre-push ]; then\n%s\nfi\n' "$STATUS_TEST_GATE_CI" > .git/hooks/pre-commit
  doctor_one_fail "FAIL .git/hooks/pre-commit has 2 lines ending in \"# gauntlet\" (lines 3, 4); keep one, the current form, and remove the others"
}

# A shared hooks directory is only printed for: the same words, with the file name spelled.
test_doctor_names_the_several_gauntlet_lines_of_a_shared_hook() {
  mkrepo
  must mkdir "$TMP/shared"
  must git config core.hooksPath "$TMP/shared"
  doctor_install
  printf '%s\n' "$STATUS_TEST_SHARED_STAGED" > "$TMP/shared/pre-commit"
  printf '#!/bin/sh\n%s\n%s\n' "$STATUS_TEST_OLD_CI" "$STATUS_TEST_GATE_CI" > "$TMP/shared/pre-push"
  must chmod +x "$TMP/shared/pre-commit" "$TMP/shared/pre-push"
  doctor_one_fail "FAIL $TMP/shared/pre-push has 2 lines ending in \"# gauntlet\" (lines 2, 3); keep one, the current form, and remove the others"
}

test_a_lefthook_config_with_an_older_gauntlet_command_is_told_to_replace_it() {
  mkrepo
  printf 'pre-commit:\n  commands:\n    gauntlet:\n      run: .gauntlet/bin/gauntlet check --staged\npre-push:\n  commands:\n    gauntlet:\n      run: .gauntlet/bin/gauntlet check --ci\n' > lefthook.yml
  doctor_install
  cp lefthook.yml "$TMP/before"
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks: $OUT"
  assert_contains "$OUT" "ACTION NEEDED: replace the gauntlet command in lefthook.yml with: $STATUS_TEST_CMD_CI"
  assert_contains "$OUT" "set use_stdin: true on it"
  assert_not_contains "$OUT" "add to lefthook.yml"
  same_file "$TMP/before" lefthook.yml
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor: $OUT"
  assert_contains "$OUT" "FAIL pre-push gate in lefthook.yml is an older gauntlet command (it differs from the current one): replace the gauntlet command in lefthook.yml with: $STATUS_TEST_CMD_CI, and set use_stdin: true on it"
  assert_eq 1 "$(doctor_fails)" "one FAIL for the config"
}

test_a_prek_config_with_an_older_gauntlet_command_is_told_to_replace_it() {
  mkrepo
  printf -- '- repo: local\n  hooks:\n    - id: gauntlet\n      entry: .gauntlet/bin/gauntlet check --staged\n    - id: gauntlet-ci\n      entry: .gauntlet/bin/gauntlet check --ci\n' > .pre-commit-config.yaml
  doctor_install
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks: $OUT"
  assert_contains "$OUT" "ACTION NEEDED: replace the gauntlet command in .pre-commit-config.yaml with: $STATUS_TEST_CMD_CI"
  assert_not_contains "$OUT" "use_stdin"
  assert_not_contains "$OUT" "add to .pre-commit-config.yaml"
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor: $OUT"
  assert_contains "$OUT" "FAIL pre-push gate in .pre-commit-config.yaml is an older gauntlet command (it differs from the current one): replace the gauntlet command in .pre-commit-config.yaml with: $STATUS_TEST_CMD_CI"
  assert_not_contains "$OUT" "use_stdin"
}

# One script serving both hooks: the old pre-push line sits inside its test on the hook's name, so
# the advice names that line and does not print the whole block again.
test_a_shared_script_with_an_older_pre_push_line_is_told_to_replace_that_line() {
  mkrepo
  printf '#!/bin/sh\necho shared\n' > .git/hooks/pre-commit
  must chmod 755 .git/hooks/pre-commit
  must ln -s pre-commit .git/hooks/pre-push
  doctor_install
  # shellcheck disable=SC2016 # the hook text holds ${0##*/}, which must not expand here
  printf '#!/bin/sh\nif [ "${0##*/}" = pre-commit ]; then\n.gauntlet/bin/gauntlet check --staged || exit $?  # gauntlet\nfi\nif [ "${0##*/}" = pre-push ]; then\n%s\nfi\necho shared\n' "$STATUS_TEST_OLD_CI" > .git/hooks/pre-commit
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks: $OUT"
  assert_contains "$OUT" "ACTION NEEDED: .git/hooks/pre-commit and .git/hooks/pre-push are the same file"
  assert_contains "$OUT" "replace the line ending in \"# gauntlet\" that runs check --ci in .git/hooks/pre-commit with:"$'\n'"$STATUS_TEST_GATE_CI"
  assert_not_contains "$OUT" "Add to"
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor: $OUT"
  assert_eq 1 "$(doctor_fails)" "one FAIL for the shared script: $OUT"
  assert_contains "$OUT" "FAIL .git/hooks/pre-commit and .git/hooks/pre-push are the same file, so a gate line in it would run in both hooks: replace the line ending in \"# gauntlet\" that runs check --ci in .git/hooks/pre-commit with: $STATUS_TEST_GATE_CI"
}

# The same in a hooks directory shared with other repositories: the line to put there is the
# guarded form, for install-hooks and for doctor.
test_a_shared_dir_script_with_an_older_pre_push_line_is_told_the_guarded_line() {
  mkrepo
  must mkdir "$TMP/shared"
  printf '#!/bin/sh\necho shared\n' > "$TMP/shared/pre-commit"
  must chmod 755 "$TMP/shared/pre-commit"
  must ln -s pre-commit "$TMP/shared/pre-push"
  must git config core.hooksPath "$TMP/shared"
  doctor_install
  # shellcheck disable=SC2016 # the hook text holds ${0##*/}, which must not expand here
  printf '#!/bin/sh\nif [ "${0##*/}" = pre-commit ]; then\n.gauntlet/bin/gauntlet check --staged || exit $?  # gauntlet\nfi\nif [ "${0##*/}" = pre-push ]; then\n%s\nfi\n' "$STATUS_TEST_OLD_CI" > "$TMP/shared/pre-commit"
  run "$G" install-hooks
  assert_contains "$OUT" "that runs check --ci in $TMP/shared/pre-commit with:"$'\n'"$STATUS_TEST_SHARED_CI"
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor: $OUT"
  assert_contains "$OUT" "that runs check --ci in $TMP/shared/pre-commit with: $STATUS_TEST_SHARED_CI"
}

# I1, and review C I-2 and I-3: doctor lists every file under .gauntlet/ that git ignores and does
# not track, because a clone and CI do not have it, with the pattern that hides it. What it says to
# do depends on the cause. The demo is a root .gitignore with bin/ and lib/ against the .gauntlet/.gitignore
# of the version before: it lacks the lines that bring the runner back.
STATUS_TEST_OLD_GITIGNORE=$'STATUS.md\n!bin/\n!lib/\n!bin/**\n!lib/**\n'

# doctor_untrack: leave .gauntlet/ in the working tree but out of the index and the last commit, the
# state of a project that has installed gauntlet and not committed it yet.
doctor_untrack() {
  must git rm -r -q --cached .gauntlet
  must git commit -q --no-verify -m "untrack .gauntlet"
}

test_doctor_fails_when_a_root_ignore_hides_the_runner_and_the_lines_are_missing() {
  mkrepo
  doctor_install
  doctor_untrack
  printf 'bin/\nlib/\n' > .gitignore
  printf 'STATUS.md\n' > .gauntlet/.gitignore
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor: $OUT"
  assert_eq 2 "$(doctor_fails)" "one FAIL per rule that hides files: $OUT"
  assert_contains "$OUT" "FAIL required lines are missing from .gauntlet/.gitignore, so a root ignore rule hides .gauntlet/bin/gauntlet (.gitignore:1:bin/): run gauntlet install to add them"
  assert_contains "$OUT" "FAIL required lines are missing from .gauntlet/.gitignore, so a root ignore rule hides .gauntlet/lib/base.sh, .gauntlet/lib/cases.sh, "
  assert_contains "$OUT" ".gauntlet/lib/formats/tsc.md, "
  assert_contains "$OUT" "(.gitignore:2:lib/): run gauntlet install to add them"
  run "$G" install
  assert_eq 0 "$STATUS" "install: $OUT"
  assert_contains "$OUT" "updated .gauntlet/.gitignore: added "
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor after install: $OUT"
  assert_contains "$OUT" "ok .gauntlet files are not ignored by git"
}

# The end-to-end case of review C: the .gauntlet/.gitignore of the version before (five lines) and a
# root *.tsv. doctor fails, install repairs the file, and then the state files are tracked.
test_install_repairs_the_old_gauntlet_gitignore_that_a_root_tsv_ignore_defeats() {
  mkrepo
  doctor_install
  doctor_untrack
  printf '*.tsv\n' > .gitignore
  printf '%s' "$STATUS_TEST_OLD_GITIGNORE" > .gauntlet/.gitignore
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor: $OUT"
  assert_eq 1 "$(doctor_fails)" "one FAIL: $OUT"
  assert_contains "$OUT" "FAIL required lines are missing from .gauntlet/.gitignore, so a root ignore rule hides .gauntlet/baseline.tsv, .gauntlet/exceptions.tsv (.gitignore:1:*.tsv): run gauntlet install to add them"
  run "$G" install
  assert_eq 0 "$STATUS" "install: $OUT"
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor after install: $OUT"
  must git add -A
  must git commit -q -m "adopt gauntlet"
  assert_contains "$(git ls-files -- .gauntlet)" ".gauntlet/baseline.tsv"
  assert_contains "$(git ls-files -- .gauntlet)" ".gauntlet/exceptions.tsv"
}

# Root patterns for the project's own files: every ignored untracked file is listed, a rule at a
# time with the files it hides, and the fix is the rule's, because the lines are all there.
test_doctor_lists_every_ignored_file_and_names_the_rule_that_hides_it() {
  mkrepo
  doctor_install
  doctor_untrack
  printf '*.txt\n*.log\n' > .gitignore
  printf 'x\n' > .gauntlet/rules/a.bad.txt
  printf 'x\n' > .gauntlet/rules/a.good.txt
  printf 'x\n' > .gauntlet/rules/notes.log
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor: $OUT"
  assert_eq 2 "$(doctor_fails)" "one FAIL per rule: $OUT"
  assert_contains "$OUT" "FAIL a root ignore rule hides .gauntlet/rules/a.bad.txt, .gauntlet/rules/a.good.txt (.gitignore:1:*.txt); remove or narrow that rule"
  assert_contains "$OUT" "FAIL a root ignore rule hides .gauntlet/rules/notes.log (.gitignore:2:*.log); remove or narrow that rule"
}

# With lines missing, only the files they would bring back get the advice to run install; a file
# they do not cover (a case file of a rule) is hidden by the root rule, whatever install adds.
test_doctor_does_not_ask_for_install_for_a_file_the_lines_do_not_cover() {
  mkrepo
  doctor_install
  doctor_untrack
  printf '*.tsv\n*.txt\n' > .gitignore
  printf '%s' "$STATUS_TEST_OLD_GITIGNORE" > .gauntlet/.gitignore
  printf 'x\n' > .gauntlet/rules/a.bad.txt
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor: $OUT"
  assert_eq 2 "$(doctor_fails)" "one FAIL per cause: $OUT"
  assert_contains "$OUT" "FAIL required lines are missing from .gauntlet/.gitignore, so a root ignore rule hides .gauntlet/baseline.tsv, .gauntlet/exceptions.tsv (.gitignore:1:*.tsv): run gauntlet install to add them"
  assert_contains "$OUT" "FAIL a root ignore rule hides .gauntlet/rules/a.bad.txt (.gitignore:2:*.txt); remove or narrow that rule"
}

# A rule that wins over the re-include lines (here a line the user added after them) is named, and
# install is not the advice: the lines are there.
test_doctor_names_the_rule_that_hides_a_lib_file_when_the_lines_are_there() {
  mkrepo
  doctor_install
  doctor_untrack
  printf '*.sh\n' >> .gauntlet/.gitignore
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor: $OUT"
  assert_eq 1 "$(doctor_fails)" "one FAIL: $OUT"
  assert_contains "$OUT" "FAIL a root ignore rule hides .gauntlet/lib/base.sh, "
  assert_contains "$OUT" "(.gauntlet/.gitignore:17:*.sh); remove or narrow that rule"
  assert_not_contains "$OUT" "run gauntlet install"
}

# R58 N4: a pattern of the lines install writes covers one path level: rules/*.md is a rule file, not
# a file in a directory under rules/. A nested file is hidden by the root rule whatever install adds,
# so it is not blamed on the missing lines.
test_gauntlet_keeps_matches_one_path_level() {
  . "$ROOT/lib/hooks.sh"
  local path
  for path in bin/gauntlet lib/core.sh lib/formats/tsc.md rules/todo.md formats/mine.md config baseline.tsv exceptions.tsv .gitignore; do
    gauntlet_keeps "$path" || fail "$path is a file install writes under .gauntlet/"
  done
  for path in lib/sub/core.sh lib/formats/sub/tsc.md rules/todo.bad/n.md formats/sub/mine.md sub/config rules/todo.bad.txt bin/other lib/formats/tsc.txt; do
    if gauntlet_keeps "$path"; then fail "$path is none of the files install writes"; fi
  done
}

test_doctor_does_not_blame_the_missing_lines_for_a_nested_file_they_cannot_cover() {
  mkrepo
  doctor_install
  doctor_untrack
  printf '*.md\n' > .gitignore
  printf '%s' "$STATUS_TEST_OLD_GITIGNORE" > .gauntlet/.gitignore
  must mkdir -p .gauntlet/rules/foo.bad .gauntlet/formats
  printf 'x\n' > .gauntlet/rules/foo.bad/n.md
  printf 'x\n' > .gauntlet/formats/mine.md
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor: $OUT"
  assert_eq 2 "$(doctor_fails)" "one FAIL per cause: $OUT"
  assert_contains "$OUT" "FAIL a root ignore rule hides .gauntlet/rules/foo.bad/n.md (.gitignore:1:*.md); remove or narrow that rule"
  assert_contains "$OUT" "FAIL required lines are missing from .gauntlet/.gitignore, so a root ignore rule hides .gauntlet/formats/mine.md (.gitignore:1:*.md): run gauntlet install to add them"
}

# R58 N5: a .gauntlet/.gitignore that cannot be read is one FAIL with a gauntlet: line, as install
# says it; git's own warning and awk's are not passed on, and the other checks go on.
test_doctor_fails_once_when_the_gauntlet_gitignore_cannot_be_read() {
  [ "$(id -u)" -ne 0 ] || { skip "root reads any file"; return 77; }
  mkrepo
  doctor_install
  doctor_untrack
  printf '*.tsv\n' > .gitignore
  must chmod 000 .gauntlet/.gitignore
  run "$G" doctor
  chmod 644 .gauntlet/.gitignore
  assert_eq 1 "$STATUS" "doctor: $OUT"
  assert_eq 1 "$(doctor_fails)" "one FAIL: $OUT"
  assert_contains "$OUT" "FAIL gauntlet: cannot read .gauntlet/.gitignore; fix the permissions"
  assert_not_contains "$OUT" "unable to access"
  assert_not_contains "$OUT" "cannot open"
  assert_contains "$OUT" "ok base main"
  assert_contains "$OUT" "ok no stale waivers"
}

# A read that fails after the permission test passed (the file goes away, the disk fails) says the
# same, and awk's own message is not passed on.
test_doctor_fails_once_when_the_gauntlet_gitignore_read_fails() {
  mkrepo
  doctor_install
  doctor_untrack
  printf '*.tsv\n' > .gitignore
  printf '%s' "$STATUS_TEST_OLD_GITIGNORE" > .gauntlet/.gitignore
  tool_fails awk '' .gitignore
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor: $OUT"
  assert_eq 1 "$(doctor_fails)" "one FAIL: $OUT"
  assert_contains "$OUT" "FAIL gauntlet: cannot read .gauntlet/.gitignore; fix the permissions"
  assert_not_contains "$OUT" "simulated failure"
  assert_contains "$OUT" "ok no stale waivers"
}

# Without any ignored file the unreadable file would go unnoticed, and git's warning would leak.
test_doctor_fails_when_the_gauntlet_gitignore_cannot_be_read_and_nothing_is_ignored() {
  [ "$(id -u)" -ne 0 ] || { skip "root reads any file"; return 77; }
  mkrepo
  doctor_install
  must chmod 000 .gauntlet/.gitignore
  run "$G" doctor
  chmod 644 .gauntlet/.gitignore
  assert_eq 1 "$STATUS" "doctor: $OUT"
  assert_contains "$OUT" "FAIL gauntlet: cannot read .gauntlet/.gitignore; fix the permissions"
  assert_not_contains "$OUT" "unable to access"
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor with the file readable again: $OUT"
}

# A root pattern that ignores .gauntlet/ itself cannot be undone from inside it: one FAIL says so.
test_doctor_says_when_gauntlet_itself_is_ignored() {
  mkrepo
  doctor_install
  doctor_untrack
  local pat
  for pat in '.gauntlet/' '/.gauntlet' '*'; do
    printf '%s\n' "$pat" > .gitignore
    run "$G" doctor
    assert_eq 1 "$STATUS" "doctor with the root pattern [$pat]: $OUT"
    assert_eq 1 "$(doctor_fails)" "one FAIL with the root pattern [$pat]: $OUT"
    assert_contains "$OUT" "FAIL .gauntlet/ is ignored by git (.gitignore:1:$pat): nothing in it can be committed; remove or narrow that rule"
  done
}

# Not subject to the check: the derived file, the lock, and editor and OS junk (which the lines of
# .gauntlet/.gitignore leave ignored on purpose).
test_doctor_does_not_list_status_md_the_lock_or_editor_junk() {
  mkrepo
  doctor_install
  doctor_untrack
  printf '.DS_Store\n*.swp\n*.orig\n' > .gitignore
  printf 'x\n' > .gauntlet/STATUS.md
  must mkdir -p .gauntlet/.install.lock
  printf 'x\n' > .gauntlet/.install.lock/owner
  printf 'x\n' > .gauntlet/.DS_Store
  printf 'x\n' > .gauntlet/lib/.DS_Store
  printf 'x\n' > .gauntlet/lib/core.sh.swp
  printf 'x\n' > .gauntlet/rules/a.md.orig
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor: $OUT"
  assert_contains "$OUT" "ok .gauntlet files are not ignored by git"
}

# doctor_git_fails <git command> <flag>: put a git first on PATH that fails `git <command> <flag> ...`
# with an error, as a damaged repository would, and runs every other call through the real git.
doctor_git_fails() {
  local real
  real=$(command -v git) || fail "no git on PATH"
  must mkdir -p "$TMP/shim"
  cat > "$TMP/shim/git" <<SHIM
#!/bin/sh
if [ "\$1" = $1 ] && [ "\${2:-}" = "$2" ]; then
  echo "fatal: simulated failure of $1" >&2
  exit 128
fi
exec "$real" "\$@"
SHIM
  must chmod +x "$TMP/shim/git"
  PATH="$TMP/shim:$PATH"
  export PATH
}

# A git that cannot list the ignored files, or cannot answer check-ignore, does not make the files
# "not ignored": doctor stops, exit 2, with git's message, and prints no ok line for it.
test_doctor_stops_when_git_cannot_list_the_ignored_files() {
  mkrepo
  doctor_install
  doctor_git_fails ls-files -z
  run "$G" doctor
  assert_eq 2 "$STATUS" "doctor: $OUT"
  assert_contains "$OUT" "fatal: simulated failure of ls-files"
  assert_not_contains "$OUT" "files are not ignored by git"
}

test_doctor_stops_when_git_cannot_say_whether_gauntlet_is_ignored() {
  mkrepo
  doctor_install
  doctor_untrack
  printf '*.txt\n' > .gitignore
  printf 'x\n' > .gauntlet/rules/a.bad.txt
  doctor_git_fails check-ignore -q
  run "$G" doctor
  assert_eq 2 "$STATUS" "doctor: $OUT"
  assert_contains "$OUT" "fatal: simulated failure of check-ignore"
  assert_not_contains "$OUT" "files are not ignored by git"
  assert_not_contains "$OUT" "FAIL a root ignore rule"
}

# The same when the ignore is real and only the question of which pattern fails: no FAIL line with an
# empty pattern in place of the answer.
test_doctor_stops_when_git_cannot_name_the_pattern_that_ignores_a_file() {
  mkrepo
  doctor_install
  doctor_untrack
  printf '*.txt\n' > .gitignore
  printf 'x\n' > .gauntlet/rules/a.bad.txt
  doctor_git_fails check-ignore -v
  run "$G" doctor
  assert_eq 2 "$STATUS" "doctor: $OUT"
  assert_contains "$OUT" "fatal: simulated failure of check-ignore"
  assert_not_contains "$OUT" "files are not ignored by git"
  assert_not_contains "$OUT" "FAIL a root ignore rule"
}

# lefthook keeps its config under .config/ too; use_stdin is read there as in the root.
test_doctor_reads_a_lefthook_config_in_dot_config() {
  mkrepo
  doctor_install
  must mkdir .config
  printf 'pre-commit:\n  commands:\n    gauntlet:\n      run: .gauntlet/bin/gauntlet check --staged\npre-push:\n  commands:\n    gauntlet:\n      run: %s\n' "$STATUS_TEST_CMD_CI" > .config/lefthook.yml
  doctor_one_fail "FAIL lefthook pre-push gate in .config/lefthook.yml has no use_stdin: true"
  printf '      use_stdin: true\n' >> .config/lefthook.yml
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor: $OUT"
  assert_contains "$OUT" "ok gate in .config/lefthook.yml"
}

# A runner that is tracked is not subject to ignore rules, so it is not a FAIL.
test_doctor_accepts_a_tracked_runner_under_a_root_ignore() {
  mkrepo
  doctor_install
  must git add -f .gauntlet
  printf 'bin/\nlib/\n' > .gitignore
  must rm .gauntlet/.gitignore
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor: $OUT"
  assert_contains "$OUT" "ok .gauntlet files are not ignored by git"
}

# I1 (c): the base must resolve, by the resolution the gates use.
test_doctor_fails_when_the_base_does_not_resolve() {
  mkrepo
  must git branch -m main master
  doctor_install
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor on a repo whose only branch is master: $OUT"
  assert_eq 1 "$(doctor_fails)" "one FAIL line: $OUT"
  assert_contains "$OUT" "FAIL base main does not resolve; set base=<ref> in .gauntlet/config (all branches), or run gauntlet base <ref> (this branch only)"
  must git config branch.master.gauntletBase master
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor after gauntlet base master: $OUT"
  assert_contains "$OUT" "ok base master"
  must git config --unset branch.master.gauntletBase
  printf 'base=master\n' > .gauntlet/config
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor after base= in the config: $OUT"
}

# The demo of the final review: a clone whose default branch is master. With origin/HEAD the base
# is origin/master; without it (a remote added by hand, or set-head removed) the fallback main
# does not exist, and the command that fixes it is named.
test_doctor_on_a_clone_whose_default_branch_is_master() {
  must git init -q --bare "$TMP/remote.git"
  must git -C "$TMP/remote.git" symbolic-ref HEAD refs/heads/master
  mkrepo
  must git branch -m main master
  must git remote add origin "$TMP/remote.git"
  must git push -q origin master
  must cd "$TMP"
  must git clone -q "$TMP/remote.git" "$TMP/clone"
  must cd "$TMP/clone"
  must git config user.name "Test User"
  must git config user.email "test@example.com"
  must git config commit.gpgsign false
  must mkdir -p .gauntlet/rules
  must touch .gauntlet/config .gauntlet/baseline.tsv .gauntlet/exceptions.tsv
  doctor_install
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor in the clone: $OUT"
  assert_contains "$OUT" "ok base origin/master"
  must git remote set-head origin -d
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor without origin/HEAD: $OUT"
  assert_contains "$OUT" "FAIL base main does not resolve; set base=<ref> in .gauntlet/config (all branches), or run gauntlet base <ref> (this branch only)"
}

# doctor never touches the network (R49): against a remote that cannot be reached a fetch would
# hang a hook or a CI step, and doctor has nothing to gain from one. A base that is a remote ref
# not fetched yet is a note, because the gates fetch it; a ref that is neither local nor plausibly
# remote is still a FAIL.
test_doctor_never_fetches_and_notes_an_origin_base_that_is_not_fetched_yet() {
  mkrepo
  must git remote add origin "file://$TMP/no/such/remote.git"
  doctor_install
  must git config branch.main.gauntletBase origin/dev
  git_counts
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor: $OUT"
  assert_contains "$OUT" "note base origin/dev is not fetched yet; the gates fetch it"
  assert_not_contains "$OUT" "FAIL"
  if grep -q 'fetch' "$SHIM_CALLS"; then fail "doctor asked git to fetch: $(grep fetch "$SHIM_CALLS")"; fi
  printf 'base=origin/dev\n' > .gauntlet/config
  must git config --unset branch.main.gauntletBase
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor with base= in the config: $OUT"
  assert_contains "$OUT" "note base origin/dev is not fetched yet; the gates fetch it"
}

test_doctor_resolves_an_origin_base_that_is_already_local() {
  must git init -q --bare "$TMP/remote.git"
  mkrepo
  must git remote add origin "$TMP/remote.git"
  must git push -q origin main
  must git push -q origin main:dev
  must git fetch -q origin
  doctor_install
  must git config branch.main.gauntletBase origin/dev
  git_counts
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor: $OUT"
  assert_contains "$OUT" "ok base origin/dev"
  assert_not_contains "$OUT" "note"
  if grep -q 'fetch' "$SHIM_CALLS"; then fail "doctor asked git to fetch: $(grep fetch "$SHIM_CALLS")"; fi
}

# The gates fetch only origin/ refs, so doctor does not call another missing ref "not fetched yet",
# and without a remote origin there is nothing to fetch it from.
test_doctor_fails_a_missing_base_that_the_gates_would_not_fetch() {
  mkrepo
  doctor_install
  must git config branch.main.gauntletBase origin/dev
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor with no remote origin: $OUT"
  assert_contains "$OUT" "FAIL base origin/dev does not resolve; set base=<ref> in .gauntlet/config (all branches), or run gauntlet base <ref> (this branch only)"
  must git remote add origin "file://$TMP/no/such/remote.git"
  must git remote add upstream "file://$TMP/no/such/remote.git"
  must git config branch.main.gauntletBase upstream/dev
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor with a ref of another remote: $OUT"
  assert_contains "$OUT" "FAIL base upstream/dev does not resolve; set base=<ref> in .gauntlet/config (all branches), or run gauntlet base <ref> (this branch only)"
}

# R36: doctor says what install-hooks says about one script serving both hooks, and is satisfied
# once the guarded lines are there.
test_doctor_names_a_script_that_serves_both_hooks() {
  mkrepo
  printf '#!/bin/sh\necho shared\n' > .git/hooks/pre-commit
  must chmod 755 .git/hooks/pre-commit
  must ln -s pre-commit .git/hooks/pre-push
  doctor_install
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor: $OUT"
  assert_eq 1 "$(doctor_fails)" "one FAIL for the shared script: $OUT"
  assert_contains "$OUT" "FAIL .git/hooks/pre-commit and .git/hooks/pre-push are the same file, so a gate line in it would run in both hooks: run gauntlet install-hooks and add by hand the lines it prints"
  # shellcheck disable=SC2016 # the hook text holds ${0##*/}, which must not expand here
  printf '#!/bin/sh\nif [ "${0##*/}" = pre-commit ]; then\n.gauntlet/bin/gauntlet check --staged || exit $?  # gauntlet\nfi\nif [ "${0##*/}" = pre-push ]; then\n%s\nfi\necho shared\n' "$STATUS_TEST_GATE_CI" > .git/hooks/pre-commit
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor after the lines are added: $OUT"
  assert_contains "$OUT" "ok pre-commit gate in .git/hooks/pre-commit"
  assert_contains "$OUT" "ok pre-push gate in .git/hooks/pre-commit"
}

test_doctor_fails_a_shared_script_that_is_not_executable() {
  mkrepo
  printf '#!/bin/sh\necho shared\n' > .git/hooks/pre-commit
  must chmod 644 .git/hooks/pre-commit
  must ln -s pre-commit .git/hooks/pre-push
  doctor_install
  run "$G" doctor
  assert_contains "$OUT" "FAIL hook .git/hooks/pre-commit is not executable: chmod +x '.git/hooks/pre-commit'"
}

# core.hooksPath that git cannot read: doctor stops with git's message instead of judging the default directory.
test_doctor_stops_on_a_hooks_path_git_cannot_read() {
  local real
  mkrepo
  doctor_install
  real=$(command -v git)
  must mkdir -p "$TMP/shim"
  cat > "$TMP/shim/git" <<SHIM
#!/bin/sh
case " \$* " in
  *" config "*" --get core.hooksPath"*)
    echo "fatal: simulated failure reading core.hooksPath" >&2
    exit 128
    ;;
esac
exec "$real" "\$@"
SHIM
  must chmod +x "$TMP/shim/git"
  run env PATH="$TMP/shim:$PATH" "$G" doctor
  assert_eq 2 "$STATUS" "doctor: $OUT"
  assert_contains "$OUT" "gauntlet: cannot read core.hooksPath: fatal: simulated failure reading core.hooksPath"
}

# I-final (review B): doctor could not tell an emptied or half-copied .gauntlet/lib. It reads the list
# of lib files from the vendored bin/gauntlet itself and names the ones that are missing or empty.
test_doctor_names_a_missing_lib_file() {
  mkrepo
  doctor_install
  must rm .gauntlet/lib/check.sh
  doctor_one_fail "FAIL .gauntlet/lib lacks files the runner sources (check.sh): run gauntlet install to re-vendor"
}

test_doctor_names_every_file_of_an_emptied_lib_directory() {
  local f
  mkrepo
  doctor_install
  must rm -rf .gauntlet/lib
  must mkdir .gauntlet/lib
  doctor_one_fail "FAIL .gauntlet/lib lacks files the runner sources ("
  for f in "$ROOT"/lib/*.sh; do
    assert_contains "$OUT" "${f##*/}"
  done
  assert_contains "$OUT" "): run gauntlet install to re-vendor"
}

test_doctor_names_a_lib_file_that_was_cut_to_nothing() {
  mkrepo
  doctor_install
  : > .gauntlet/lib/rules.sh
  doctor_one_fail "FAIL .gauntlet/lib lacks files the runner sources (rules.sh): run gauntlet install to re-vendor"
}

# The list is the vendored runner's own: a lib file it sources and the checkout does not have is
# missing; a file it no longer sources is not demanded.
test_doctor_reads_the_list_of_lib_files_from_the_vendored_runner() {
  mkrepo
  doctor_install
  # shellcheck disable=SC2016 # the line is the literal text of an entry point
  printf '. "$GAUNTLET_BIN/../lib/extra.sh"\n' >> .gauntlet/bin/gauntlet
  run "$G" doctor
  assert_contains "$OUT" "FAIL .gauntlet/lib lacks files the runner sources (extra.sh): run gauntlet install to re-vendor"
  must cp "$ROOT/bin/gauntlet" .gauntlet/bin/gauntlet
  grep -v 'lib/status.sh' "$ROOT/bin/gauntlet" > .gauntlet/bin/gauntlet
  must chmod +x .gauntlet/bin/gauntlet
  must rm .gauntlet/lib/status.sh
  run "$G" doctor
  assert_not_contains "$OUT" "lacks files the runner sources"
}

test_doctor_says_ok_for_a_complete_runner() {
  mkrepo
  doctor_install
  run "$G" doctor
  assert_eq 0 "$STATUS" "doctor: $OUT"
  assert_contains "$OUT" "ok runner .gauntlet/bin/gauntlet"
  assert_not_contains "$OUT" "lacks files"
}

# doctor_hooks used to run the runner and format checks too; each is its own check now, in the
# same order, so the lines come out as before.
test_doctor_prints_runner_formats_and_hooks_in_that_order() {
  local runner formats hooks
  mkrepo
  rule fmt
  doctor_install
  must rm .gauntlet/lib/formats/path-line.md
  run "$G" doctor
  runner=$(printf '%s\n' "$OUT" | grep -n '^ok runner \.gauntlet' | cut -d: -f1)
  formats=$(printf '%s\n' "$OUT" | grep -n '^FAIL built-in format path-line' | cut -d: -f1)
  hooks=$(printf '%s\n' "$OUT" | grep -n '^ok pre-commit gate' | cut -d: -f1)
  if [ -z "$runner" ] || [ -z "$formats" ] || [ -z "$hooks" ]; then fail "a line is missing: $OUT"; fi
  if [ "$runner" -ge "$formats" ] || [ "$formats" -ge "$hooks" ]; then fail "runner $runner, formats $formats, hooks $hooks: $OUT"; fi
}
