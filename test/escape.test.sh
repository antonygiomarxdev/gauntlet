# shellcheck shell=bash
# shellcheck disable=SC2153 # ROOT, G and STATUS are set by test/lib.sh
# shellcheck disable=SC2016 # the fixture scripts hold $ and quotes that must not expand here
# What gauntlet prints is somebody else's text: a tracked file name, a detector's message, a
# config key. No raw control byte may reach a terminal or a CI log through it, whichever report
# or message prints it. path_spell writes such a byte \xNN at print time; the rows gauntlet stores
# (baseline.tsv, exceptions.tsv) keep the bytes as they are.

esc_lib() {
  # shellcheck source=lib/core.sh
  . "$ROOT/lib/core.sh"
  # shellcheck source=lib/paths.sh
  . "$ROOT/lib/paths.sh"
}

# The name that clears the screen, sets the window title and returns the carriage.
esc_name() {
  printf 'x\033[2J\033]0;pwned\ay\r.ts'
}
ESC_SPELT='x\x1b[2J\x1b]0;pwned\x07y\x0d.ts'

# assert_clean <text> <label>: no byte below 0x20 but the newline and the tab (which the
# diff of the baseline and tool messages print), no 0x7f, and no C1 control in its UTF-8 form.
assert_clean() {
  local raw c1 seen
  raw=$(printf '%s' "$1" | LC_ALL=C tr -d '\011\012\040-\176\200-\377' | wc -c | tr -d ' ')
  seen=$(printf '%s' "$1" | LC_ALL=C sed 's/[^[:print:]]/?/g' | head -c 600)
  assert_eq 0 "$raw" "raw control bytes in $2: $seen"
  c1=$(printf '%s' "$1" | LC_ALL=C grep -a -c "$(printf '\302[\200-\237]')" || true)
  assert_eq 0 "$c1" "raw C1 controls in $2: $seen"
}

test_path_spell_writes_every_control_byte_below_space_and_del() {
  esc_lib
  assert_eq 'a\tb\nc' "$(path_spell "$(printf 'a\tb\nc')")" "tab and newline"
  assert_eq 'x\x1b[2J\x07\x0d' "$(path_spell "$(printf 'x\033[2J\a\r')")" "ESC, BEL, CR"
  assert_eq 'a\x7fb' "$(path_spell "$(printf 'a\177b')")" "DEL"
  assert_eq 'a\x01b\x1fc' "$(path_spell "$(printf 'a\001b\037c')")" "the ends of the range"
  assert_eq 'a b~c' "$(path_spell 'a b~c')" "printable ASCII stays"
}

# xterm reads U+009B, the UTF-8 bytes C2 9B, as CSI. Only that two-byte form is a control: a lone
# byte in 0x80-0x9f is the continuation byte of valid text (the euro sign is E2 82 AC).
test_path_spell_writes_c1_controls_and_keeps_valid_utf8() {
  esc_lib
  assert_eq 'a\xc2\x9bb' "$(path_spell "$(printf 'a\302\233b')")" "CSI"
  assert_eq '\xc2\x80\xc2\x9f' "$(path_spell "$(printf '\302\200\302\237')")" "the ends of the C1 range"
  assert_eq "$(printf 'caf\303\251-\342\202\254.ts')" "$(path_spell "$(printf 'caf\303\251-\342\202\254.ts')")" "accent and euro"
  assert_eq "$(printf '\303\261.ts')" "$(path_spell "$(printf '\303\261.ts')")" "n tilde"
  assert_eq "$(printf '\302\240')" "$(path_spell "$(printf '\302\240')")" "no-break space is not a control"
  assert_eq "$(printf 'a\302')" "$(path_spell "$(printf 'a\302')")" "a lone lead byte at the end"
  assert_eq "$(printf 'a\233b')" "$(path_spell "$(printf 'a\233b')")" "a lone byte 0x9b is not escaped"
}

test_path_spell_filters_lines_and_keeps_tabs_and_blank_lines() {
  esc_lib
  assert_eq "$(printf 'a\tb\n\\x1b[2Jc\\x0dd\n\nlast')" "$(printf 'a\tb\n\033[2Jc\rd\n\nlast\n' | path_spell)" "ESC and CR escaped, tab and blank line kept"
  assert_eq "$(printf 'a\tb\\x1bc')" "$(printf 'a\tb\033c\n' | path_spell)" "a tab on a line that is escaped for another byte"
  assert_eq 'x\xc2\x9by' "$(printf 'x\302\233y\n' | path_spell)" "C1 in a line"
  assert_eq 'a\x7fb' "$(printf 'a\177b\n' | path_spell)" "DEL in a line"
  assert_eq "" "$(path_spell < /dev/null)" "no input, no output"
}

# --- the reports and messages ---

# esc_repo: main holds the odd-named file with one TODO and a baseline, hook-free; branch feat.
esc_repo() {
  local name
  mkrepo
  name=$(esc_name)
  printf 'TODO a\n' > "$name"
  rule todo paths='**/*.ts'
  cases_of todo 'TODO x'
  must git add -A
  run "$G" baseline
  assert_eq 0 "$STATUS" "baseline: $OUT"
  must git add -A
  must git commit -q -m main
  must git checkout -q -b feat
}

test_check_ci_prints_no_raw_byte_of_a_tracked_name() {
  local name
  esc_repo
  name=$(esc_name)
  printf 'TODO a\nTODO b\n' > "$name"
  must git add -A
  must git commit -q -m feat
  run "$G" check --ci --base main
  assert_eq 1 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "[new]"
  assert_contains "$OUT" "  $ESC_SPELT:2  todo  TODO b"
  assert_contains "$OUT" "[baseline]"
  assert_clean "$OUT" "check --ci"
}

test_check_ci_escapes_the_touched_shadow_and_checks_blocks() {
  local name
  mkrepo
  name=$(esc_name)
  printf 'TODO a\n' > "$name"
  rule todo paths='**/*.ts'
  rule shady severity=shadow paths='**/*.ts'
  cases_of todo 'TODO x'
  cases_of shady 'TODO x'
  printf 'printf "bad \\033[2J\\n"\nexit 1\n' > chk.sh
  printf 'touched=on\ncheck.fmt=sh chk.sh\ncheck.fmt.ci=on\n' > .gauntlet/config
  must git add -A
  run "$G" baseline
  assert_eq 0 "$STATUS" "baseline: $OUT"
  must git add -A
  must git commit -q -m main
  must git checkout -q -b feat
  printf 'TODO a\nTODO b\n' > "$name"
  must git add -A
  run "$G" baseline
  assert_eq 0 "$STATUS" "baseline on feat: $OUT"
  must git add -A
  must git commit -q -m feat
  run "$G" check --ci --base main
  assert_eq 1 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "[touched]"
  assert_contains "$OUT" "[shadow] would have failed"
  assert_contains "$OUT" "  $ESC_SPELT:2  shady  TODO b"
  assert_contains "$OUT" "[checks]"
  assert_contains "$OUT" '    bad \x1b[2J'
  assert_clean "$OUT" "check --ci"
}

test_check_staged_prints_no_raw_byte_of_a_tracked_name() {
  local name
  esc_repo
  name=$(esc_name)
  printf '#!/bin/sh\nexec "%s" check --staged\n' "$G" > .git/hooks/pre-commit
  must chmod +x .git/hooks/pre-commit
  printf 'TODO a\nTODO b\n' > "$name"
  must git add -A
  run git commit -q -m feat
  assert_eq 1 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "[new]"
  assert_contains "$OUT" "  $ESC_SPELT:2  todo  TODO b"
  assert_clean "$OUT" "check --staged"
}

# A detector's message and its stderr are tool text, and a tracked name or a tool message in a
# failure of the run is printed too.
test_a_detector_message_with_control_bytes_is_escaped() {
  mkrepo
  printf 'x\n' > a.ts
  printf '#!/bin/sh\nfor f in "$@"; do printf "%%s:1:bad \\033]0;t\\007 \\033[2Jx\\r\\n" "$f"; done\n' > tools.sh
  rule todo paths='**/*.ts' engine=script 'detector=sh ./tools.sh {files}'
  script_row todo
  must git add -A
  run "$G" baseline
  assert_eq 0 "$STATUS" "baseline: $OUT"
  must git add -A
  must git commit -q -m main
  must git checkout -q -b feat
  printf 'y\n' > b.ts
  must git add -A
  run "$G" baseline
  must git add -A
  must git commit -q -m feat
  run "$G" check --ci --base main
  assert_eq 1 "$STATUS" "status: $OUT"
  assert_contains "$OUT" '  b.ts:1  todo  bad \x1b]0;t\x07 \x1b[2Jx\x0d'
  assert_clean "$OUT" "check --ci"
}

test_a_broken_detector_prints_its_stderr_escaped() {
  local id
  mkrepo
  id=$(printf 'to\033[2Jdo')
  printf 'x\n' > a.ts
  printf '#!/bin/sh\nprintf "oops \\033[2J\\033]0;t\\007 %%s\\n" "$1" >&2\nexit 3\n' > tools.sh
  must chmod +x tools.sh
  rule "$id" paths='**/*.ts' engine=script 'detector=sh ./tools.sh {files}'
  script_row "$id"
  must git add -A
  run "$G" baseline
  assert_eq 2 "$STATUS" "baseline: $OUT"
  assert_contains "$OUT" 'gauntlet: broken detector: to\x1b[2Jdo: exit 3'
  assert_contains "$OUT" 'gauntlet:   | oops \x1b[2J\x1b]0;t\x07'
  assert_clean "$OUT" "baseline"
}

test_an_unparsed_tool_line_is_printed_escaped() {
  local id
  mkrepo
  id=$(printf 'to\033[2Jdo')
  printf 'x\n' > a.ts
  printf '#!/bin/sh\nprintf "no match here \\033[2J\\n"\n' > tools.sh
  rule "$id" paths='**/*.ts' engine=script 'detector=sh ./tools.sh {files}'
  script_row "$id"
  must git add -A
  run "$G" baseline
  assert_eq 2 "$STATUS" "baseline: $OUT"
  assert_contains "$OUT" 'gauntlet: broken detector: to\x1b[2Jdo: unparsed line: no match here \x1b[2J'
  assert_clean "$OUT" "baseline"
}

# A name that the measure cannot read is printed in the failure.
test_an_unreadable_tracked_name_is_printed_escaped() {
  local name
  if [ "$(id -u)" -eq 0 ]; then skip "root reads every file"; return 77; fi
  mkrepo
  name=$(esc_name)
  printf 'TODO a\n' > "$name"
  rule todo paths='**/*.ts' engine=script 'detector=sh ./tools.sh'
  script_row todo
  printf '#!/bin/sh\nprintf "%%s:1:bad\\n" "$(printf "x\\033[2J\\033]0;pwned\\ay\\r.ts")"\n' > tools.sh
  must git add -A
  must chmod 000 "$name"
  run "$G" baseline
  must chmod 644 "$name"
  assert_eq 2 "$STATUS" "baseline: $OUT"
  assert_contains "$OUT" "gauntlet: cannot read $ESC_SPELT"
  assert_clean "$OUT" "baseline"
}

test_status_prints_no_raw_byte_of_a_tracked_name() {
  local name
  mkrepo
  name=$(esc_name)
  printf 'TODO a\n' > "$name"
  rule todo paths='**/*.ts'
  cases_of todo 'TODO x'
  must git add -A
  run "$G" baseline
  assert_eq 0 "$STATUS" "baseline: $OUT"
  run "$G" status
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "$ESC_SPELT"
  assert_clean "$OUT" "status"
  assert_eq "$OUT" "$(cat .gauntlet/STATUS.md)" "STATUS.md holds the text that was printed"
}

test_doctor_prints_no_raw_byte_of_config_rule_or_waiver_text() {
  local name
  mkrepo
  name=$(esc_name)
  printf 'TODO a\n' > "$name"
  rule todo paths='**/*.ts'
  cases_of todo 'TODO x'
  rule "$(printf 'to\033[2Jdo')" paths='**/*.ts'
  printf 'check.a\033[2Jb=true\nunk\033]0;t\007=1\ntouched=\033[2J\n' > .gauntlet/config
  printf 'type\ttarget\treason\tdate\tbranch\nwaive\t%s\tr\t2026-10-22\tother\n' "$name" > .gauntlet/exceptions.tsv
  must git add -A
  run "$G" doctor
  assert_eq 1 "$STATUS" "status: $OUT"
  assert_contains "$OUT" 'ok rule to\x1b[2Jdo'
  assert_contains "$OUT" 'name [a\x1b[2Jb] must use'
  assert_contains "$OUT" 'config key unk\x1b]0;t\x07 is not known'
  assert_contains "$OUT" 'touched must be on or off, got [\x1b[2J]'
  assert_contains "$OUT" "stale waive $ESC_SPELT (branch other)"
  assert_clean "$OUT" "doctor"
}

test_doctor_escapes_a_rule_file_problem_and_a_tool_name() {
  mkrepo
  rule todo paths='**/*.ts' format=$'pa\033[2Jth' $'detector=\033[2Jtool {files}'
  must git add -A
  run "$G" doctor
  assert_eq 1 "$STATUS" "status: $OUT"
  assert_contains "$OUT" 'format pa\x1b[2Jth is unknown'
  assert_contains "$OUT" 'tool \x1b[2Jtool for rule todo is missing'
  assert_clean "$OUT" "doctor"
}

test_a_message_that_dies_with_a_name_is_escaped() {
  mkrepo
  run "$G" waive "$(esc_name)" reason
  assert_eq 2 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "not a path in git or the working tree: $ESC_SPELT"
  assert_clean "$OUT" "waive"
}

# The stored rows are data: print-time escaping never reaches them.
test_stored_rows_keep_the_raw_bytes() {
  local name
  mkrepo
  name=$(esc_name)
  printf 'TODO a\n' > "$name"
  rule todo paths='**/*.ts'
  cases_of todo 'TODO x'
  must git add -A
  run "$G" baseline
  assert_eq 0 "$STATUS" "baseline: $OUT"
  run "$G" waive "$name" reason
  assert_eq 0 "$STATUS" "waive: $OUT"
  assert_contains "$(cat .gauntlet/baseline.tsv)" "$name"
  assert_contains "$(cat .gauntlet/exceptions.tsv)" "$name"
}

# A name that is valid text prints as it is: the escape is for controls, not for letters.
test_valid_utf8_names_print_unchanged_and_a_c1_name_is_escaped() {
  mkrepo
  printf 'TODO a\n' > "$(printf 'caf\303\251-\342\202\254.ts')"
  printf 'TODO a\n' > "$(printf '\303\261.ts')"
  printf 'TODO a\n' > "$(printf 'c\302\233d.ts')"
  rule todo paths='**/*.ts'
  cases_of todo 'TODO x'
  must git add -A
  run "$G" baseline
  assert_eq 0 "$STATUS" "baseline: $OUT"
  must git add -A
  must git commit -q -m main
  must git checkout -q -b feat
  printf 'TODO a\nTODO b\n' > "$(printf 'caf\303\251-\342\202\254.ts')"
  printf 'TODO a\nTODO b\n' > "$(printf '\303\261.ts')"
  printf 'TODO a\nTODO b\n' > "$(printf 'c\302\233d.ts')"
  must git add -A
  must git commit -q -m feat
  run "$G" check --ci --base main
  assert_eq 1 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "$(printf '  caf\303\251-\342\202\254.ts:2  todo  TODO b')"
  assert_contains "$OUT" "$(printf '  \303\261.ts:2  todo  TODO b')"
  assert_contains "$OUT" '  c\xc2\x9bd.ts:2  todo  TODO b'
  assert_clean "$OUT" "check --ci"
}

test_a_del_in_a_name_is_escaped() {
  local name
  esc_repo
  name=$(printf 'd\177l.ts')
  printf 'TODO a\n' > "$name"
  must git add -A
  must git commit -q -m feat
  run "$G" check --ci --base main
  assert_eq 1 "$STATUS" "status: $OUT"
  assert_contains "$OUT" '  d\x7fl.ts:1  todo  TODO a'
  assert_clean "$OUT" "check --ci"
}

# A rule file is named by its id, and its id is printed in every message about it.
test_a_broken_rule_file_named_with_control_bytes_is_printed_escaped() {
  mkrepo
  printf -- '---\nid: other\n---\nBroken.\n' > "$(printf '.gauntlet/rules/a\033[2Jb.md')"
  must git add -A
  run "$G" baseline
  assert_eq 2 "$STATUS" "baseline: $OUT"
  assert_contains "$OUT" 'rule a\x1b[2Jb: '
  assert_clean "$OUT" "baseline"
}

test_the_config_text_in_a_failure_of_check_is_printed_escaped() {
  mkrepo
  printf 'check.a\033[2Jb=true\n' > .gauntlet/config
  must git add -A
  must git commit -q -m config
  must git checkout -q -b feat
  printf 'x\n' > a.txt
  must git add -A
  must git commit -q -m feat
  run "$G" check --ci --base main
  assert_eq 2 "$STATUS" "bad key: $OUT"
  assert_contains "$OUT" 'gauntlet: bad check key check.a\x1b[2Jb: name [a\x1b[2Jb] must use'
  assert_clean "$OUT" "bad key"
  printf 'touched=\033[2J\n' > .gauntlet/config
  must git add -A
  must git commit -q -m touched
  run "$G" check --ci --base main
  assert_eq 2 "$STATUS" "touched: $OUT"
  assert_contains "$OUT" 'gauntlet: touched must be on or off, got [\x1b[2J]'
  assert_clean "$OUT" "touched"
}

test_test_rules_prints_a_case_name_escaped() {
  mkrepo
  rule todo paths='**/*.ts'
  printf 'ok\n' > "$(printf '.gauntlet/rules/todo.bad\033[2J.txt')"
  printf 'ok\n' > .gauntlet/rules/todo.good.txt
  must git add -A
  run "$G" test-rules
  assert_eq 1 "$STATUS" "test-rules: $OUT"
  assert_contains "$OUT" '  todo  todo.bad\x1b[2J.txt  bad case not flagged'
  assert_clean "$OUT" "test-rules"
}

# The messages of the git reads name the path, and git's own error line names it too.
test_a_failed_git_read_prints_the_path_escaped() {
  local name rc=0
  mkrepo
  # shellcheck source=lib/core.sh
  . "$ROOT/lib/core.sh"
  # shellcheck source=lib/base.sh
  . "$ROOT/lib/base.sh"
  name=$(esc_name)
  git_fails ls-tree "$name" HEAD
  base_has HEAD "$name" 2> "$TMP/err" || rc=$?
  assert_eq 2 "$rc" "base_has"
  assert_contains "$(cat "$TMP/err")" "gauntlet: cannot read $ESC_SPELT at HEAD: fatal: simulated failure reading $ESC_SPELT"
  assert_clean "$(cat "$TMP/err")" "base_has"
}

test_an_object_git_cannot_read_prints_its_path_escaped() {
  local name rc=0
  mkrepo
  # shellcheck source=lib/core.sh
  . "$ROOT/lib/core.sh"
  # shellcheck source=lib/base.sh
  . "$ROOT/lib/base.sh"
  name=$(esc_name)
  printf 'unique content\n' > "$name"
  must git add -A
  must git commit -q -m odd
  unreadable_object "HEAD:$name"
  at_base HEAD "$name" > /dev/null 2> "$TMP/err" || rc=$?
  assert_eq 2 "$rc" "at_base"
  assert_contains "$(cat "$TMP/err")" "gauntlet: cannot read $ESC_SPELT at HEAD"
  assert_clean "$(cat "$TMP/err")" "at_base"
}

test_a_detector_word_git_cannot_read_prints_escaped() {
  local name
  mkrepo
  name=$(printf 'tools/\033[2Jfind.sh')
  must mkdir -p tools
  printf '#!/bin/sh\nexit 0\n' > "$name"
  printf 'ok\n' > a.ts
  rule todo paths='**/*.ts' engine=script "detector=bash $name {files}"
  script_row todo
  must git add -A
  run "$G" baseline
  assert_eq 0 "$STATUS" "baseline: $OUT"
  must git add -A
  must git commit -q -m main
  must git checkout -q -b feat
  printf 'x\n' > b.txt
  must git add -A
  must git commit -q -m feat
  git_fails ls-tree "$name" HEAD
  run "$G" check --ci --base main
  assert_eq 2 "$STATUS" "check --ci: $OUT"
  assert_contains "$OUT" 'gauntlet: cannot read tools/\x1b[2Jfind.sh at HEAD: fatal: simulated failure reading tools/\x1b[2Jfind.sh'
  assert_clean "$OUT" "check --ci"
}

test_an_unknown_format_and_a_bad_format_file_are_printed_escaped() {
  local esc
  mkrepo
  esc=$(printf '\033[2J')
  printf 'x\n' > a.ts
  rule todo paths='**/*.ts' "format=pa${esc}th"
  must git add -A
  run "$G" baseline
  assert_eq 2 "$STATUS" "unknown format: $OUT"
  assert_contains "$OUT" 'gauntlet: unknown format pa\x1b[2Jth'
  assert_clean "$OUT" "unknown format"
  must mkdir -p .gauntlet/formats
  printf -- '---\nmatch:\n---\n' > ".gauntlet/formats/f${esc}x.md"
  rule todo paths='**/*.ts' "format=f${esc}x"
  must git add -A
  run "$G" baseline
  assert_eq 2 "$STATUS" "format without match: $OUT"
  assert_contains "$OUT" 'gauntlet: format f\x1b[2Jx needs match and numeric path and line groups'
  assert_clean "$OUT" "format without match"
  printf -- '---\nmatch: ^(.*):([0-9]+)$\npath: 1\nline: 22\n---\n' > ".gauntlet/formats/f${esc}x.md"
  run "$G" baseline
  assert_eq 2 "$STATUS" "format with a wide group: $OUT"
  assert_contains "$OUT" 'gauntlet: format f\x1b[2Jx: line is group 22; use a group from 0 to 9'
  assert_clean "$OUT" "format with a wide group"
}

test_status_and_promote_print_a_rule_id_escaped() {
  local id
  mkrepo
  id=$(printf 'a\033[2Jb')
  printf -- '---\nid: x\n' > ".gauntlet/rules/$id.md"
  must git add -A
  run "$G" status
  assert_eq 2 "$STATUS" "status: $OUT"
  assert_contains "$OUT" 'gauntlet: cannot read rule a\x1b[2Jb; run gauntlet doctor'
  assert_clean "$OUT" "status"
  rule "$id" severity=shadow paths='**/*.ts'
  run "$G" promote "$id"
  assert_eq 0 "$STATUS" "promote: $OUT"
  assert_contains "$OUT" 'promoted a\x1b[2Jb: shadow -> block'
  assert_clean "$OUT" "promote"
}

# A symlink detector file whose blob git cannot read: the message names the path. The other git
# commands of a gate stop on the same damaged object first, so the function is called directly.
test_an_unreadable_link_blob_prints_its_path_escaped() {
  local name rc=0
  mkrepo
  # shellcheck source=lib/core.sh
  . "$ROOT/lib/core.sh"
  # shellcheck source=lib/base.sh
  . "$ROOT/lib/base.sh"
  # shellcheck source=lib/exceptions.sh
  . "$ROOT/lib/exceptions.sh"
  # shellcheck source=lib/paths.sh
  . "$ROOT/lib/paths.sh"
  # shellcheck source=lib/check.sh
  . "$ROOT/lib/check.sh"
  name=$(printf 'l\033[2Jk\ry.sh')
  ln -s real.sh "$name"
  must git add -A
  must git commit -q -m link
  unreadable_object "HEAD:$name"
  path_identity HEAD "$name" > /dev/null 2> "$TMP/err" || rc=$?
  assert_eq 2 "$rc" "path_identity"
  assert_contains "$(cat "$TMP/err")" 'gauntlet: cannot read l\x1b[2Jk\x0dy.sh at HEAD'
  assert_clean "$(cat "$TMP/err")" "path_identity"
}

# --- W3b: the install lock ---

# esc_hooks_repo [bare]: a repo whose directory name holds an ESC, with the runner vendored unless
# "bare" is given, so every path under it that a message prints holds the byte.
esc_hooks_repo() {
  local dir
  dir="$TMP/r$(printf '\033')p"
  must mkdir -p "$dir"
  must cd "$dir"
  must git init -q .
  must git symbolic-ref HEAD refs/heads/main
  must git config user.name "Test User"
  must git config user.email "test@example.com"
  must git config commit.gpgsign false
  printf 'hello\n' > README.md
  must git add README.md
  must git commit -q -m init
  if [ "${1:-}" != bare ]; then
    must mkdir -p .gauntlet
    must cp -R "$ROOT/bin" "$ROOT/lib" .gauntlet/
  fi
}

test_the_lock_messages_print_the_path_escaped() {
  esc_hooks_repo
  must mkdir .git/gauntlet-install.lock
  run env GAUNTLET_LOCK_WAIT=0 "$G" install-hooks
  assert_eq 2 "$STATUS" "install-hooks: $OUT"
  assert_contains "$OUT" 'r\x1bp/.git/gauntlet-install.lock; if none is running, remove it'
  assert_clean "$OUT" "the lock held"
  "$G" install-hooks > "$TMP/out" 2> "$TMP/err" &
  local pid=$!
  for _ in $(seq 1 100); do
    if grep -Fq "waiting for another install" "$TMP/err"; then break; fi
    sleep 0.1 2> /dev/null || sleep 1
  done
  assert_contains "$(cat "$TMP/err")" 'waiting for another install to finish ('
  assert_contains "$(cat "$TMP/err")" 'r\x1bp/.git/gauntlet-install.lock'
  assert_clean "$(cat "$TMP/err")" "the wait"
  must rmdir .git/gauntlet-install.lock
  wait "$pid" || fail "install-hooks did not finish once the lock was free: $(cat "$TMP/out" "$TMP/err")"
  if [ "$(id -u)" -ne 0 ]; then
    must chmod 555 .git
    run env "$G" install-hooks
    chmod 755 .git
    assert_contains "$OUT" 'gauntlet: cannot create'
    assert_contains "$OUT" 'r\x1bp/.git/gauntlet-install.lock'
    assert_clean "$OUT" "the lock that cannot be made"
  fi
}

# --- W3b: the runner ignore and the base ---

# The base is whatever the config says: a ref that holds a control byte (git forbids one in a ref
# name, but not in branch.<b>.gauntletBase) is printed spelled, by doctor and by the gate.
test_the_base_that_does_not_resolve_is_printed_escaped() {
  local ref
  mkrepo
  must cp -R "$ROOT/bin" "$ROOT/lib" .gauntlet/
  ref=$(printf 'x\033[2Jy')
  must git config branch.main.gauntletBase "$ref"
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor: $OUT"
  assert_contains "$OUT" 'FAIL base x\x1b[2Jy does not resolve; run gauntlet base <ref>'
  assert_clean "$OUT" "doctor"
  run "$G" check --ci
  assert_eq 2 "$STATUS" "check --ci: $OUT"
  assert_contains "$OUT" 'gauntlet: unknown ref: x\x1b[2Jy; run gauntlet base <ref>'
  assert_clean "$OUT" "check --ci"
  must git config branch.main.gauntletBase "origin/$ref"
  must git remote add origin "$TMP/nowhere"
  run "$G" check --ci
  assert_contains "$OUT" 'gauntlet: fetch of origin/x\x1b[2Jy failed; using the local ref'
  assert_clean "$OUT" "the failed fetch"
}

# doctor prints the ignore pattern git matched, and the pattern is the project's text: [b<ESC>]in/
# matches bin/ and holds the byte. (git quotes the source file's path itself.)
test_the_ignore_pattern_is_printed_escaped() {
  mkrepo
  must cp -R "$ROOT/bin" "$ROOT/lib" .gauntlet/
  printf '[b\033]in/\n' > .gitignore
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor: $OUT"
  assert_contains "$OUT" 'FAIL runner files are ignored by git (.gauntlet/bin/gauntlet by .gitignore:1:[b\x1b]in/)'
  assert_clean "$OUT" "doctor"
}

# --- W3b: the hook advice ---

# esc_hooks_dir: a hooks directory inside the repo whose name holds an ESC, set as core.hooksPath,
# so every hook path a message prints holds the byte.
esc_hooks_dir() {
  ESC_DIR="hk$(printf '\033')d"
  esc_hooks_repo
  must mkdir "$ESC_DIR"
  must git config core.hooksPath "$ESC_DIR"
}

test_the_one_script_advice_prints_the_paths_escaped() {
  esc_hooks_dir
  printf '#!/bin/sh\necho shared\n' > "$ESC_DIR/pre-commit"
  chmod 755 "$ESC_DIR/pre-commit"
  must ln -s pre-commit "$ESC_DIR/pre-push"
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks: $OUT"
  assert_contains "$OUT" 'ACTION NEEDED: hk\x1bd/pre-commit and hk\x1bd/pre-push are the same file'
  assert_contains "$OUT" 'Add to hk\x1bd/pre-commit, as the first commands'
  assert_clean "$OUT" "the one-script advice"
  run "$G" doctor
  assert_contains "$OUT" 'FAIL hk\x1bd/pre-commit and hk\x1bd/pre-push are the same file'
  assert_clean "$OUT" "doctor"
}

test_the_no_runner_messages_print_the_path_escaped() {
  esc_hooks_repo bare
  run "$G" install-hooks
  assert_eq 2 "$STATUS" "install-hooks: $OUT"
  assert_contains "$OUT" 'gauntlet: no runner at '
  assert_contains "$OUT" 'r\x1bp/.gauntlet/bin/gauntlet; run gauntlet install first'
  assert_clean "$OUT" "the refusal"
  printf 'pre-commit:\n  parallel: true\n' > lefthook.yml
  "$G" install-hooks > "$TMP/out" 2> "$TMP/err" || fail "install-hooks failed for a config: $(cat "$TMP/out" "$TMP/err")"
  assert_contains "$(cat "$TMP/err")" 'gauntlet: warning: no runner at '
  assert_contains "$(cat "$TMP/err")" 'r\x1bp/.gauntlet/bin/gauntlet; run gauntlet install'
  assert_clean "$(cat "$TMP/err")" "the warning"
}

test_the_shared_hooks_dir_advice_prints_the_paths_escaped() {
  local shared
  esc_hooks_repo
  shared="$TMP/sh$(printf '\033')d"
  must mkdir "$shared"
  must git config core.hooksPath "$shared"
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks: $OUT"
  assert_contains "$OUT" 'sh\x1bd is a hooks directory shared with other repositories (core.hooksPath)'
  assert_contains "$OUT" 'ACTION NEEDED: add to '
  assert_contains "$OUT" 'sh\x1bd/pre-commit:'
  assert_clean "$OUT" "the shared hooks directory advice"
}
