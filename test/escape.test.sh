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
}

# A terminal in 8-bit mode reads the single byte 0x9B as CSI, so a byte 0x80-0x9f that no valid UTF-8
# character uses is written \xNN. One that is part of a valid character is text and stays.
test_a_lone_byte_in_the_c1_range_is_escaped_and_valid_text_stays() {
  esc_lib
  assert_eq 'a\x9bb' "$(path_spell "$(printf 'a\233b')")" "a lone CSI"
  assert_eq '\x80\x9f' "$(path_spell "$(printf '\200\237')")" "the ends of the range"
  assert_eq "$(printf 'a\240b\377')" "$(path_spell "$(printf 'a\240b\377')")" "0xa0 and 0xff are not controls"
  assert_eq "$(printf '\342\202\254 \303\233 \340\245\260 \360\237\230\200')" \
    "$(path_spell "$(printf '\342\202\254 \303\233 \340\245\260 \360\237\230\200')")" "euro, U circumflex (C3 9B), a three-byte and a four-byte character"
  assert_eq "$(printf 'a\342')"'\x82b' "$(path_spell "$(printf 'a\342\202b')")" "a character that is cut short"
  assert_eq "$(printf 'a\342')"'\x82' "$(path_spell "$(printf 'a\342\202')")" "a character cut short by the end"
  assert_eq "$(printf '\300')"'\x9b' "$(path_spell "$(printf '\300\233')")" "an overlong lead byte"
  assert_eq "$(printf '\301')"'\x9b' "$(path_spell "$(printf '\301\233')")" "0xc1 is no lead byte either"
  assert_eq "$(printf '\365')"'\x80\x80\x80' "$(path_spell "$(printf '\365\200\200\200')")" "0xf5 is no lead byte"
  assert_eq "$(printf '\340')"'\x80\x80' "$(path_spell "$(printf '\340\200\200')")" "an overlong three-byte form"
  assert_eq "$(printf '\340')"'\x9f'"$(printf '\277')" "$(path_spell "$(printf '\340\237\277')")" "just below U+0800"
  assert_eq "$(printf '\340\240\200')" "$(path_spell "$(printf '\340\240\200')")" "U+0800, the first three-byte character"
  assert_eq "$(printf '\355\240')"'\x80' "$(path_spell "$(printf '\355\240\200')")" "a surrogate"
  assert_eq "$(printf '\360')"'\x80\x80\x80' "$(path_spell "$(printf '\360\200\200\200')")" "an overlong four-byte form"
  assert_eq "$(printf '\364')"'\x90\x80\x80' "$(path_spell "$(printf '\364\220\200\200')")" "above U+10FFFF"
  assert_eq "$(printf 'x\302')"'\xc2\x9b' "$(path_spell "$(printf 'x\302\302\233')")" "a lead byte, then a C1 pair"
}

# A name is one line: the newline that ends it is printed, not left to the caller's substitution.
test_a_name_ends_with_one_newline() {
  esc_lib
  path_spell 'a b' > "$TMP/name.out"
  assert_eq 4 "$(wc -c < "$TMP/name.out" | tr -d ' ')" "bytes printed for a name of three bytes"
  path_spell "$(printf 'a\nb')" > "$TMP/name.out"
  assert_eq 5 "$(wc -c < "$TMP/name.out" | tr -d ' ')" "bytes printed for a name with a newline in it"
  assert_eq 1 "$(wc -l < "$TMP/name.out" | tr -d ' ')" "one line"
}

test_lines_mode_writes_the_ends_of_every_range() {
  esc_lib
  assert_eq 'a\x01b' "$(printf 'a\001b\n' | path_spell)" "0x01"
  assert_eq 'a\x08b' "$(printf 'a\010b\n' | path_spell)" "0x08, the last before the tab"
  assert_eq "$(printf 'a\tb')" "$(printf 'a\tb\n' | path_spell)" "the tab stays"
  assert_eq 'a\x0bb' "$(printf 'a\013b\n' | path_spell)" "0x0b, the first after the newline"
  assert_eq 'a\x1fb' "$(printf 'a\037b\n' | path_spell)" "0x1f, the last control"
  assert_eq 'a b' "$(printf 'a b\n' | path_spell)" "0x20 is a space"
  assert_eq 'a\x7fb' "$(printf 'a\177b\n' | path_spell)" "0x7f"
  assert_eq '~' "$(printf '~\n' | path_spell)" "0x7e"
  assert_eq 'a\x80' "$(printf 'a\200\n' | path_spell)" "0x80"
}

# The work is linear in the length of the line. A minified bundle is one long line, and it used to
# take minutes when it held a single character that needs a look.
esc_long_line() {
  local half=$((${1:-400000} / 2))
  {
    head -c "$half" /dev/zero | tr '\0' a
    printf '\302\251'
    head -c "$((half - 10))" /dev/zero | tr '\0' b
    printf '\033\n'
  } > "$TMP/long"
}

esc_time_long_line() {
  local start end
  start=$(now_ms)
  path_spell < "$TMP/long" > "$TMP/long.out"
  end=$(now_ms)
  ELAPSED=$((end - start))
  assert_eq 399997 "$(wc -c < "$TMP/long.out" | tr -d ' ')" "size of the escaped line"
}

test_a_long_line_with_one_copyright_sign_and_one_escape_is_fast() {
  local start end
  esc_lib
  esc_long_line
  esc_time_long_line
  if [ "$ELAPSED" -ge 2500 ]; then fail "400 KB line took $ELAPSED ms"; fi
  head -c 100000 /dev/zero | tr '\0' '\033' > "$TMP/long"
  printf '\n' >> "$TMP/long"
  start=$(now_ms)
  path_spell < "$TMP/long" > "$TMP/long.out"
  end=$(now_ms)
  if [ $((end - start)) -ge 2500 ]; then fail "a line of 100000 escapes took $((end - start)) ms"; fi
}

test_a_long_line_is_linear_under_busybox_awk_too() {
  local bb
  bb=$(command -v busybox) || { skip "busybox not installed"; return 77; }
  esc_lib
  must mkdir -p "$TMP/bb"
  printf '#!/bin/sh\nexec "%s" awk "$@"\n' "$bb" > "$TMP/bb/awk"
  must chmod +x "$TMP/bb/awk"
  PATH="$TMP/bb:$PATH"
  # This awk copies the whole string on every substr call, so a walk over one long string is
  # quadratic: 1.6 MB takes about 80 s that way (400 KB took 95 s in the first version, 5 s in a
  # per-character walk). Walked in pieces it is linear: about 3 s. The run is cut off at 25 s.
  esc_long_line 1600000
  with_timeout 25 path_spell < "$TMP/long" > "$TMP/long.out" || fail "a 1.6 MB line took more than 25 s under busybox awk"
  assert_eq 1599997 "$(wc -c < "$TMP/long.out" | tr -d ' ')" "size of the escaped line"
}

# A long line is walked in pieces of 1024 bytes, and no piece ends inside a character: whatever
# sits across the end of a piece is judged as it is anywhere else in the line.
test_the_end_of_a_piece_of_a_long_line_cuts_no_character() {
  local off pad item want
  esc_lib
  for off in 1019 1020 1021 1022 1023 1024 1025 1026 2046 2047 2048 2049; do
    pad=$(head -c "$off" /dev/zero | tr '\0' a)
    for item in $'\303\251' $'\342\202\254' $'\360\237\230\200' $'\302\240'; do
      assert_eq "$pad$item" "$(printf '%s%s\n' "$pad" "$item" | path_spell)" "valid text after $off bytes"
    done
    assert_eq "$pad"'\xc2\x9b' "$(printf '%s\302\233\n' "$pad" | path_spell)" "a C1 pair after $off bytes"
    assert_eq "$pad"'\x9b' "$(printf '%s\233\n' "$pad" | path_spell)" "a lone CSI after $off bytes"
    assert_eq "$pad"'\x1b' "$(printf '%s\033\n' "$pad" | path_spell)" "ESC after $off bytes"
    # A character, then continuation bytes no lead byte owns: each is a lone byte.
    want=$'\303\200''\x80\x80\x80\x9f'
    assert_eq "$pad$want" "$(printf '%s\303\200\200\200\200\237\n' "$pad" | path_spell)" "a run of continuation bytes after $off bytes"
  done
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
  printf '#!/bin/sh\nfor f in "$@"; do printf "%%s:1:bad \\033]0;t\\007\\r \\033[2Jx\\r\\n" "$f"; done\n' > tools.sh
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
  # The carriage return inside the message is written; the one that ends the line is the line ending
  # and is not shown (a CRLF source), so the message ends at the x.
  assert_contains "$OUT" '  b.ts:1  todo  bad \x1b]0;t\x07\x0d \x1b[2Jx'
  assert_not_contains "$OUT" '\x1b[2Jx\x0d'
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
  assert_contains "$OUT" 'gauntlet: cannot read files named by detectors at HEAD: fatal: simulated failure reading tools/\x1b[2Jfind.sh'
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

test_the_replace_advice_for_an_older_gauntlet_line_prints_the_path_escaped() {
  esc_hooks_dir
  printf '#!/bin/sh\r\n%s\r\n' '.gauntlet/bin/gauntlet check --ci || exit $?  # gauntlet' > "$ESC_DIR/pre-push"
  chmod 755 "$ESC_DIR/pre-push"
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks: $OUT"
  assert_contains "$OUT" 'ACTION NEEDED: replace the line ending in "# gauntlet" in hk\x1bd/pre-push with:'
  assert_clean "$OUT" "the replace advice"
  run "$G" doctor
  assert_contains "$OUT" 'FAIL pre-push gate in hk\x1bd/pre-push is an older gauntlet line (it differs from the current one): replace the line ending in "# gauntlet" in hk\x1bd/pre-push with:'
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

test_the_cannot_write_message_prints_the_path_and_the_reason_escaped() {
  if [ "$(id -u)" -eq 0 ]; then
    skip "running as root: a read-only file is still writable here"
    return 77
  fi
  esc_hooks_dir
  printf '#!/bin/sh\necho mine\n' > "$ESC_DIR/pre-commit"
  chmod 444 "$ESC_DIR/pre-commit"
  run "$G" install-hooks
  assert_eq 2 "$STATUS" "install-hooks: $OUT"
  assert_contains "$OUT" 'gauntlet: cannot write hk\x1bd/pre-commit: Permission denied; fix the permissions or add the line by hand'
  assert_clean "$OUT" "the cannot-write message"
  chmod 644 "$ESC_DIR/pre-commit"
  rm -f "$ESC_DIR/pre-commit"
  chmod 555 "$ESC_DIR"
  run "$G" install-hooks
  chmod 755 "$ESC_DIR"
  assert_contains "$OUT" 'gauntlet: cannot write hk\x1bd/pre-commit: '
  assert_clean "$OUT" "the cannot-write message for a read-only directory"
}

test_the_core_hooks_path_message_prints_git_text_escaped() {
  local real
  esc_hooks_repo
  real=$(command -v git)
  must mkdir -p "$TMP/shim"
  cat > "$TMP/shim/git" <<SHIM
#!/bin/sh
case " \$* " in
  *" config "*" --get core.hooksPath"*)
    printf 'fatal: bad value x\033[2Jy\n' >&2
    exit 128
    ;;
esac
exec "$real" "\$@"
SHIM
  must chmod +x "$TMP/shim/git"
  run env PATH="$TMP/shim:$PATH" "$G" install-hooks
  assert_eq 2 "$STATUS" "install-hooks: $OUT"
  assert_contains "$OUT" 'gauntlet: cannot read core.hooksPath: fatal: bad value x\x1b[2Jy'
  assert_clean "$OUT" "the hooksPath message"
}

# The files doctor names are read from the vendored bin/gauntlet, so their names are text somebody wrote.
test_doctor_prints_the_lib_files_it_names_escaped() {
  mkrepo
  must cp -R "$ROOT/bin" "$ROOT/lib" .gauntlet/
  printf '. "$GAUNTLET_BIN/../lib/x%s.sh"\n' "$(printf '\033[2J')" >> .gauntlet/bin/gauntlet
  run "$G" doctor
  assert_eq 1 "$STATUS" "doctor: $OUT"
  assert_contains "$OUT" 'FAIL .gauntlet/lib lacks files the runner sources (x\x1b[2J.sh)'
  assert_clean "$OUT" "doctor"
}

# The note for a detector doctor cannot check prints the word it saw, which is the project's text.
test_doctor_prints_the_unchecked_tool_word_escaped() {
  mkrepo
  rule s1 engine=linter "detector=\"r$(printf '\033[2J')g\" x {files}" paths=nothing/**
  must cp -R "$ROOT/bin" "$ROOT/lib" .gauntlet/
  run "$G" doctor
  assert_contains "$OUT" 'note tool for rule s1 not checked: the detector starts with "r\x1b[2Jg"'
  assert_clean "$OUT" "doctor"
}

# --- base and ref text ---

# The base= of the tracked config is somebody else's text, and so is a ref name a hook is given.

# esc_ref <kind>: a ref name with a control in it: "esc" has ESC and BEL, "csi" has U+009B.
esc_ref() {
  case "$1" in
    esc) printf 'x\033]0;pwned\a\033[2J' ;;
    *) printf 'x\302\233y' ;;
  esac
}

# esc_ref_spelt <kind>: the same name as path_spell writes it.
esc_ref_spelt() {
  case "$1" in
    esc) printf 'x\\x1b]0;pwned\\x07\\x1b[2J' ;;
    *) printf 'x\\xc2\\x9by' ;;
  esac
}

test_a_base_in_the_config_with_a_control_is_refused_escaped() {
  local kind ref spelt
  for kind in esc csi; do
    mkrepo
    ref=$(esc_ref "$kind")
    spelt=$(esc_ref_spelt "$kind")
    printf 'base=%s\n' "$ref" > .gauntlet/config
    must git add -A
    must git commit -q -m "base $kind"
    run "$G" check --ci
    assert_eq 2 "$STATUS" "check --ci $kind: $OUT"
    assert_contains "$OUT" "gauntlet: bad base= in .gauntlet/config: $spelt"
    assert_clean "$OUT" "check --ci $kind"
    run "$G" base
    assert_eq 2 "$STATUS" "base $kind: $OUT"
    assert_contains "$OUT" "gauntlet: bad base= in .gauntlet/config: $spelt"
    assert_clean "$OUT" "base $kind"
    cd "$TMP" || fail "cannot cd to $TMP"
    rm -rf "$TMP/repo"
  done
}

test_a_valid_base_in_the_config_is_printed_as_it_is() {
  mkrepo
  printf 'base=origin/main\n' > .gauntlet/config
  run "$G" base
  assert_eq 0 "$STATUS" "base: $OUT"
  assert_eq origin/main "$OUT" "base"
}

# git echoes the refspec it is given in its own error, and gauntlet names the ref it failed to fetch.
test_a_failed_fetch_of_a_base_with_a_control_prints_escaped() {
  local kind ref spelt
  for kind in esc csi; do
    mkrepo
    must git init -q --bare "$TMP/origin.git"
    must git remote add origin "$TMP/origin.git"
    ref=$(esc_ref "$kind")
    spelt=$(esc_ref_spelt "$kind")
    run "$G" check --ci --base "origin/$ref"
    assert_eq 2 "$STATUS" "check --ci $kind: $OUT"
    assert_contains "$OUT" "gauntlet: fetch of origin/$spelt failed; using the local ref"
    assert_contains "$OUT" "fatal: "
    assert_contains "$OUT" "gauntlet: unknown ref: origin/$spelt"
    assert_clean "$OUT" "check --ci $kind"
    cd "$TMP" || fail "cannot cd to $TMP"
    rm -rf "$TMP/repo" "$TMP/origin.git"
  done
}

test_the_pre_push_refusal_prints_a_branch_name_escaped() {
  local kind ref spelt zero sha
  mkrepo
  zero=0000000000000000000000000000000000000000
  sha=1111111111111111111111111111111111111111
  for kind in esc csi; do
    ref=$(esc_ref "$kind")
    spelt=$(esc_ref_spelt "$kind")
    OUT=$(printf 'refs/heads/%s %s refs/heads/%s %s\n' "$ref" "$sha" "$ref" "$zero" | "$G" check --ci --pre-push 2>&1) && STATUS=0 || STATUS=$?
    assert_eq 1 "$STATUS" "pre-push $kind: $OUT"
    assert_contains "$OUT" "gauntlet checks the checked-out branch; check out $spelt and push again"
    assert_clean "$OUT" "pre-push $kind"
  done
}

test_gauntlet_base_prints_the_ref_escaped() {
  local kind ref spelt
  mkrepo
  for kind in esc csi; do
    ref=$(esc_ref "$kind")
    spelt=$(esc_ref_spelt "$kind")
    must git config branch.main.gauntletBase "$ref"
    run "$G" base
    assert_eq 0 "$STATUS" "base $kind: $OUT"
    assert_eq "$spelt" "$OUT" "base $kind"
    assert_clean "$OUT" "base $kind"
  done
}

# --- names that start with "::" ---

# GitHub's runner trims the blanks of an output line and runs one that starts with "::" as a
# workflow command: ::error:: makes an annotation, ::stop-commands:: switches the commands off.
# A tracked file or a rule can be called that, so no line of a report may start with it.

test_a_name_that_starts_with_colons_is_written_with_its_first_colon_escaped() {
  esc_lib
  assert_eq '\x3a:error::x.ts' "$(path_spell '::error::x.ts')" "a name"
  assert_eq '  \x3a:x' "$(path_spell '  ::x')" "after blanks"
  assert_eq "$(printf '\302\240\\x3a:x')" "$(path_spell "$(printf '\302\240::x')")" "after a no-break space"
  assert_eq "$(printf '\343\200\200\\x3a:x')" "$(path_spell "$(printf '\343\200\200::x')")" "after an ideographic space"
  assert_eq '\x3a::x' "$(path_spell ':::x')" "three colons"
  assert_eq 'a::x' "$(path_spell 'a::x')" "colons that are not first"
  assert_eq ':x' "$(path_spell ':x')" "one colon"
  assert_eq '\x1b::x' "$(path_spell "$(printf '\033::x')")" "an escaped byte comes first"
  assert_eq '::error::x' "$(printf '::error::x\n' | path_spell)" "standard input is left as it is"
}

# The runner trims what .NET calls white space before it looks for "::": besides the blank and the
# tab, the no-break space, U+1680, U+2000 to U+200A, U+2028, U+2029, U+202F, U+205F and U+3000.
# Zero-width and other format characters are not white space: a line behind one is no command.
# shellcheck disable=SC2016 # the expected text holds a literal \x3a
test_a_name_after_each_kind_of_white_space_is_escaped_and_after_other_characters_is_not() {
  local ws
  esc_lib
  for ws in $'\302\240' $'\341\232\200' $'\342\200\200' $'\342\200\201' $'\342\200\202' $'\342\200\203' \
    $'\342\200\204' $'\342\200\205' $'\342\200\206' $'\342\200\207' $'\342\200\210' $'\342\200\211' \
    $'\342\200\212' $'\342\200\250' $'\342\200\251' $'\342\200\257' $'\342\201\237' $'\343\200\200'; do
    assert_eq "$ws"'\x3a:x' "$(path_spell "$ws::x")" "after white space $(printf '%s' "$ws" | od -An -tx1 | tr -d ' \n')"
    assert_eq "$ws"'\x3a:x' "$(printf '%s::x\n' "$ws" | report_spell)" "in a report, after white space $(printf '%s' "$ws" | od -An -tx1 | tr -d ' \n')"
  done
  for ws in $'\342\200\213' $'\342\200\214' $'\342\200\220' $'\342\200\252' $'\342\201\240' $'\357\273\277' $'\303\251'; do
    assert_eq "$ws::x" "$(path_spell "$ws::x")" "after $(printf '%s' "$ws" | od -An -tx1 | tr -d ' \n'), which is not white space"
  done
}

# The blanks before the colons can fill several pieces of a long line, and a piece never ends inside a
# no-break space: the colon is found wherever it is.
test_a_command_after_a_long_run_of_blanks_is_escaped() {
  local off pad
  esc_lib
  for off in 1020 1021 1022 1023 1024 1025 3000; do
    pad=$(head -c "$off" /dev/zero | tr '\0' ' ')
    assert_eq "$pad"'\x3a:error::x' "$(printf '%s::error::x\n' "$pad" | report_spell)" "after $off blanks"
    assert_eq "$pad"$'\302\240''\x3a:x' "$(printf '%s\302\240::x\n' "$pad" | report_spell)" "after $off blanks and a no-break space"
    assert_eq "$pad"'::x' "$(printf '%s::x\n' "$pad" | path_spell)" "path_spell leaves a line as it is after $off blanks"
  done
}

test_report_spell_escapes_a_line_that_starts_with_colons_after_blanks() {
  esc_lib
  assert_eq '\x3a:error::a' "$(printf '::error::a\n' | report_spell)" "at the start"
  assert_eq '  \x3a:warning::b' "$(printf '  ::warning::b\n' | report_spell)" "after blanks"
  assert_eq "$(printf '\t\\x3a:c')" "$(printf '\t::c\n' | report_spell)" "after a tab"
  assert_eq 'x  ::d' "$(printf 'x  ::d\n' | report_spell)" "not at the start"
  assert_eq '\x3a:e\x1b' "$(printf '::e\033\n' | report_spell)" "and the rest is escaped as always"
  assert_eq "$(printf 'a\n\\x3a:b\n  c')" "$(printf 'a\n::b\n  c\n' | report_spell)" "line by line"
}

# esc_colon_repo: main with the todo rule over a format that reads a path with colons in it, a
# baseline and no violation; the branch feat adds the file with the name that is a command.
esc_colon_repo() {
  mkrepo
  must mkdir -p .gauntlet/formats
  printf -- '---\nmatch: ^(.+):([0-9]+):(.*)$\npath: 1\nline: 2\nmessage: 3\n---\n' > .gauntlet/formats/colon.md
  rule todo paths='**/*.ts' format=colon
  cases_of todo 'TODO x'
  must git add -A
  run "$G" baseline
  assert_eq 0 "$STATUS" "baseline: $OUT"
  must git add -A
  must git commit -q -m main
  must git checkout -q -b feat
}

# assert_no_command <text> <label>: no line starts, after blanks, with two colons.
assert_no_command() {
  local n
  n=$(printf '%s\n' "$1" | grep -c '^[[:space:]]*::' || true)
  assert_eq 0 "$n" "lines that start with :: in $2: $1"
}

test_check_ci_prints_no_line_that_starts_with_colons() {
  esc_colon_repo
  printf 'TODO b\n' > '::error::x.ts'
  must git add -A
  run "$G" baseline
  must git add -A
  must git commit -q -m feat
  run "$G" check --ci --base main
  assert_eq 1 "$STATUS" "check --ci: $OUT"
  assert_contains "$OUT" '  \x3a:error::x.ts:1  todo  TODO b'
  assert_no_command "$OUT" "check --ci"
}

test_the_touched_gate_prints_no_line_that_starts_with_colons() {
  esc_colon_repo
  must git checkout -q main
  printf 'TODO a\n' > '::stop-commands::t.ts'
  printf 'touched=on\n' > .gauntlet/config
  must git add -A
  run "$G" baseline
  must git add -A
  must git commit -q -m debt
  must git checkout -q -b touch
  printf 'TODO a\nok\n' > '::stop-commands::t.ts'
  must git add -A
  run "$G" baseline
  must git add -A
  must git commit -q -m touch
  run "$G" check --ci --base main
  assert_eq 1 "$STATUS" "check --ci: $OUT"
  assert_contains "$OUT" '[touched]'
  assert_contains "$OUT" '  \x3a:stop-commands::t.ts  1 → 1  (must go down)'
  assert_no_command "$OUT" "check --ci"
}

test_check_staged_prints_no_line_that_starts_with_colons() {
  esc_colon_repo
  printf 'TODO b\n' > '::error::x.ts'
  must git add -A
  run "$G" check --staged
  assert_eq 1 "$STATUS" "check --staged: $OUT"
  assert_contains "$OUT" '  \x3a:error::x.ts:1  todo  TODO b'
  assert_no_command "$OUT" "check --staged"
}

# A rule is named by its file, and the [time] section prints every rule.
test_a_rule_called_like_a_command_prints_no_line_that_starts_with_colons() {
  mkrepo
  rule '::warning::r' paths='**/*.ts'
  printf 'ok\n' > a.ts
  cases_of '::warning::r' 'TODO x'
  must git add -A
  run "$G" baseline
  assert_eq 0 "$STATUS" "baseline: $OUT"
  must git add -A
  must git commit -q -m main
  must git checkout -q -b feat
  printf 'x\n' > b.txt
  must git add -A
  must git commit -q -m feat
  run "$G" check --ci --base main
  assert_eq 0 "$STATUS" "check --ci: $OUT"
  assert_contains "$OUT" '  \x3a:warning::r  '
  assert_no_command "$OUT" "check --ci"
  must git add -A
  printf 'ok\n' > .gauntlet/rules/'::warning::r.bad.txt'
  run "$G" test-rules
  assert_eq 1 "$STATUS" "test-rules: $OUT"
  assert_contains "$OUT" '  \x3a:warning::r  '
  assert_no_command "$OUT" "test-rules"
}

test_a_failed_check_prints_no_line_that_starts_with_colons() {
  mkrepo
  printf "check.noisy=printf '::error::boom\\\\n'; exit 1\n" > .gauntlet/config
  must git add -A
  run "$G" baseline
  must git add -A
  must git commit -q -m main
  must git checkout -q -b feat
  printf 'x\n' > b.txt
  must git add -A
  must git commit -q -m feat
  run "$G" check --ci --base main
  assert_eq 1 "$STATUS" "check --ci: $OUT"
  assert_contains "$OUT" '[checks]'
  assert_contains "$OUT" '    \x3a:error::boom'
  assert_no_command "$OUT" "check --ci"
}

# --- a source line from a CRLF file ---

# Git on Windows checks out CRLF, and the line a detector prints ends with the carriage return. It is
# the line ending and not text: one is dropped from the line that is shown, and the rows gauntlet
# stores keep it, so the baseline of such a file is the one it always was.
test_a_crlf_source_line_is_shown_without_its_carriage_return() {
  mkrepo
  rule todo paths='**/*.ts'
  cases_of todo 'TODO x'
  printf 'ok\n' > a.ts
  must git add -A
  run "$G" baseline
  assert_eq 0 "$STATUS" "baseline: $OUT"
  must git add -A
  must git commit -q -m main
  must git checkout -q -b feat
  printf 'ok\r\nTODO b\r\nTODO\rc\r\nTODO d\r\r\n' > a.ts
  must git add -A
  run "$G" baseline
  assert_eq 0 "$STATUS" "baseline: $OUT"
  must git add -A
  must git commit -q -m feat
  run "$G" check --ci --base main
  assert_eq 1 "$STATUS" "check --ci: $OUT"
  assert_eq 1 "$(printf '%s\n' "$OUT" | grep -c -x '  a.ts:2  todo  TODO b')" "the end of the line: $OUT"
  assert_eq 1 "$(printf '%s\n' "$OUT" | grep -c -x '  a.ts:3  todo  TODO\\x0dc')" "a carriage return inside the line: $OUT"
  assert_eq 1 "$(printf '%s\n' "$OUT" | grep -c -x '  a.ts:4  todo  TODO d\\x0d')" "only one carriage return is the ending: $OUT"
  assert_not_contains "$OUT" "[baseline]"
  # The fingerprint never held the carriage return, so the baseline is what it has always been.
  assert_eq "$(printf 'todo\ta.ts\tTODO b\t1\ntodo\ta.ts\tTODO d\t1\ntodo\ta.ts\tTODOc\t1')" "$(cat .gauntlet/baseline.tsv)" "baseline"
}

test_a_crlf_source_line_is_shown_without_its_carriage_return_at_commit_too() {
  mkrepo
  rule todo paths='**/*.ts'
  cases_of todo 'TODO x'
  printf 'ok\n' > a.ts
  must git add -A
  run "$G" baseline
  must git add -A
  must git commit -q -m main
  printf 'TODO b\r\nTODO\rc\r\n' > a.ts
  must git add -A
  run "$G" check --staged
  assert_eq 1 "$STATUS" "check --staged: $OUT"
  assert_eq 1 "$(printf '%s\n' "$OUT" | grep -c -x '  a.ts:1  todo  TODO b')" "the end of the line: $OUT"
  assert_eq 1 "$(printf '%s\n' "$OUT" | grep -c -x '  a.ts:2  todo  TODO\\x0dc')" "a carriage return inside the line: $OUT"
}
