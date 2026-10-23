# shellcheck shell=bash
# status, promote and doctor: the rule lifecycle and the setup check (FRD-06 §4 and
# §9, FRD-07 §4.6, FRD-04 §6). Sourced, never executed. Bash 3.2 compatible; awk,
# cmp, grep, head, date, mv and coreutils only. Needs core.sh, rules.sh, paths.sh,
# detect.sh, measure.sh, base.sh, exceptions.sh, check.sh and hooks.sh sourced first.

# DOCTOR_FAILS: how many FAIL lines the current doctor run has printed.
DOCTOR_FAILS=0

# STATUS_AWK_FUNCS: awk functions every awk program in this file shares. is_date: a
# YYYY-MM-DD text that is a real calendar day, leap years included. civil: the day
# number of a valid date, from the days-from-civil formula (only differences are used,
# so the epoch does not matter). cell: a markdown table cell, with | escaped.
STATUS_AWK_FUNCS='
function is_leap(y) { return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }
function days_in(y, m) {
  if (m == 2) return is_leap(y) ? 29 : 28
  return (m == 4 || m == 6 || m == 9 || m == 11) ? 30 : 31
}
function is_date(s,   y, m, d) {
  if (s !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) return 0
  y = substr(s, 1, 4) + 0
  m = substr(s, 6, 2) + 0
  d = substr(s, 9, 2) + 0
  return m >= 1 && m <= 12 && d >= 1 && d <= days_in(y, m)
}
function civil(s,   y, m, d, era, yoe, doy, doe) {
  y = substr(s, 1, 4) + 0
  m = substr(s, 6, 2) + 0
  d = substr(s, 9, 2) + 0
  if (m <= 2) y--
  era = int((y >= 0 ? y : y - 399) / 400)
  yoe = y - era * 400
  doy = int((153 * (m > 2 ? m - 3 : m + 9) + 2) / 5) + d - 1
  doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
  return era * 146097 + doe - 719468
}
function cell(s,   n, i, out, p) {
  n = split(s, p, "|")
  out = p[1]
  for (i = 2; i <= n; i++) out = out "\\|" p[i]
  return out
}
'

# days_between <earlier> <later>: print the days from one valid date to the other,
# negative when the later date is first.
days_between() {
  GL_FROM=$1 GL_TO=$2 awk "$STATUS_AWK_FUNCS"'
    BEGIN { print civil(ENVIRON["GL_TO"]) - civil(ENVIRON["GL_FROM"]) }
  '
}

# valid_date <text>: succeed when <text> is YYYY-MM-DD and a real calendar day.
valid_date() {
  GL_DAY=$1 awk "$STATUS_AWK_FUNCS"'
    BEGIN { exit !is_date(ENVIRON["GL_DAY"]) }
  '
}

# status_cmd: regenerate .gauntlet/STATUS.md and print the same text. The totals are the
# committed baseline's, summed per rule, so no detector runs. The text has a rule table, the
# worst files by block total, the shadow rules due for promotion and the commit-stage rules over
# budget. It has no timestamp: the day is the only clock. A path in it is somebody else's text,
# so the text goes through path_spell once and the file and the terminal get the same bytes.
status_cmd() {
  local root today budget scratch status=0
  [ "$#" -eq 0 ] || die "usage: gauntlet status"
  root=$(repo_root) || return 2
  [ -d "$root/.gauntlet" ] || die "not a gauntlet repo: run gauntlet install"
  [ -f "$root/.gauntlet/baseline.tsv" ] || die "baseline .gauntlet/baseline.tsv is missing: run gauntlet install"
  [ ! -d "$root/.gauntlet/STATUS.md" ] || die ".gauntlet/STATUS.md is a directory; remove it, then run gauntlet status"
  today=$(status_today) || return 2
  budget=$(commit_budget) || return 2
  scratch=$(tmp_new -d) || return 2
  status_body "$root" "$scratch" "$today" "$budget" || status=$?
  if [ "$status" -eq 0 ]; then
    path_spell < "$scratch/body" > "$scratch/body.safe" || status=2
  fi
  if [ "$status" -eq 0 ]; then
    if status_write "$root" "$scratch/body.safe"; then
      cat "$scratch/body.safe" || status=2
    else
      status=2
    fi
  fi
  rm -rf "$scratch"
  return "$status"
}

# status_write <root> <body>: put the text in .gauntlet/STATUS.md through a temp file in
# .gauntlet/ and a rename, so a kill never leaves a partial file. Returns 1 with a
# message when either step fails.
status_write() {
  local tmp="$1/.gauntlet/.STATUS.md.$$"
  # The temp file is made with the shell's umask, so the final file has the mode a
  # plain write would have. noclobber: an existing file is never taken over.
  # partial_begin names it, so the run's trap removes it if a signal ends the run.
  if ! ( set -C; : > "$tmp" ) 2> /dev/null; then
    printf 'gauntlet: cannot write .gauntlet/STATUS.md\n' >&2
    return 1
  fi
  partial_begin "$tmp"
  if cat "$2" > "$tmp" && mv -f "$tmp" "$1/.gauntlet/STATUS.md"; then
    partial_end
    return 0
  fi
  rm -f "$tmp"
  partial_end
  printf 'gauntlet: cannot write .gauntlet/STATUS.md\n' >&2
  return 1
}

# status_today: print the day status measures against: GAUNTLET_TODAY when set,
# else today's date. Returns 2 with a message when it is not a real YYYY-MM-DD date.
status_today() {
  local day=${GAUNTLET_TODAY:-}
  if [ -z "$day" ]; then
    day=$(date +%Y-%m-%d) || return 2
  fi
  if ! valid_date "$day"; then
    printf 'gauntlet: GAUNTLET_TODAY must be a real date, YYYY-MM-DD, got [%s]\n' "$day" >&2
    return 2
  fi
  printf '%s\n' "$day"
}

# status_body <root> <scratch> <today> <budget>: write the STATUS.md text to
# <scratch>/body. The intermediate tables are kept in <scratch> too.
status_body() {
  local root=$1 scratch=$2 today=$3 budget=$4 id rf sev stage since times
  : > "$scratch/rules.tsv" || return 2
  rule_ids > "$scratch/ids" || return 2
  while IFS= read -r id; do
    rf="$root/.gauntlet/rules/$id.md"
    sev=$(rule_get "$rf" severity) || { printf 'gauntlet: cannot read rule %s; run gauntlet doctor\n' "$(path_spell "$id")" >&2; return 2; }
    stage=$(rule_get "$rf" stage) || { printf 'gauntlet: cannot read rule %s; run gauntlet doctor\n' "$(path_spell "$id")" >&2; return 2; }
    since=$(rule_get "$rf" since) || { printf 'gauntlet: cannot read rule %s; run gauntlet doctor\n' "$(path_spell "$id")" >&2; return 2; }
    [ -n "$stage" ] || stage=commit
    printf '%s\t%s\t%s\t%s\n' "$id" "$sev" "$stage" "$since" >> "$scratch/rules.tsv" || return 2
  done < "$scratch/ids"

  # status.tsv: id, severity, stage, since, total. The total is the rule's count
  # summed over every path in the baseline; a rule with no rows has 0.
  GL_RULES="$scratch/rules.tsv" awk -F "$DETECT_TAB" '
    FILENAME == ENVIRON["GL_RULES"] { order[++n] = $1; sev[$1] = $2; stage[$1] = $3; since[$1] = $4; next }
    ($1 in sev) { total[$1] += $4 }
    END {
      for (i = 1; i <= n; i++) {
        id = order[i]
        printf "%s\t%s\t%s\t%s\t%d\n", id, sev[id], stage[id], since[id], total[id] + 0
      }
    }
  ' "$scratch/rules.tsv" "$root/.gauntlet/baseline.tsv" > "$scratch/status.tsv" || return 2

  # files.raw: count and path, summed over the block rules only, for paths above 0.
  GL_RULES="$scratch/rules.tsv" awk -F "$DETECT_TAB" '
    FILENAME == ENVIRON["GL_RULES"] { sev[$1] = $2; next }
    ($1 in sev) && sev[$1] == "block" { file[$2] += $4 }
    END {
      for (p in file) if (file[p] > 0) printf "%d\t%s\n", file[p], p
    }
  ' "$scratch/rules.tsv" "$root/.gauntlet/baseline.tsv" > "$scratch/files.raw" || return 2
  LC_ALL=C sort -t "$DETECT_TAB" -k1,1nr -k2,2 "$scratch/files.raw" > "$scratch/files.sorted" || return 2
  head -n 5 "$scratch/files.sorted" > "$scratch/files.top" || return 2

  # due: a shadow rule whose since date is a real day, 7 days or more before today. A
  # since in the future gives 0 days and is not due.
  GL_TODAY="$today" awk -F "$DETECT_TAB" "$STATUS_AWK_FUNCS"'
    $2 == "shadow" && is_date($4) {
      days = civil(ENVIRON["GL_TODAY"]) - civil($4)
      if (days < 0) days = 0
      if (days >= 7) printf "promote due: %s (shadow since %s, %d days), %d found\n", $1, $4, days, $5
    }
  ' "$scratch/status.tsv" > "$scratch/due" || return 2

  # slow: commit-stage rules whose recorded time is at or over the budget. The times are
  # the file check --staged keeps (commit_times_path); when it is absent nothing is listed.
  : > "$scratch/slow"
  times=$(commit_times_path "$root") || return 2
  if [ -f "$times" ]; then
    GL_TIME="$times" GL_BUDGET="$budget" awk -F "$DETECT_TAB" '
      FILENAME == ENVIRON["GL_TIME"] { ms[$1] = $2; next }
      $3 == "commit" && ($1 in ms) && ms[$1] + 0 >= ENVIRON["GL_BUDGET"] + 0 {
        printf "slow: %s %s ms (consider stage: push)\n", $1, ms[$1]
      }
    ' "$times" "$scratch/status.tsv" > "$scratch/slow" || return 2
  fi

  {
    printf '| rule | severity | total |\n'
    printf '| --- | --- | --- |\n'
    awk -F "$DETECT_TAB" "$STATUS_AWK_FUNCS"'{ printf "| %s | %s | %s |\n", cell($1), cell($2), $5 }' "$scratch/status.tsv"
    if [ -s "$scratch/files.top" ]; then
      printf '\n| file | block total |\n| --- | --- |\n'
      awk -F "$DETECT_TAB" "$STATUS_AWK_FUNCS"'{ printf "| %s | %s |\n", cell($2), $1 }' "$scratch/files.top"
    fi
    if [ -s "$scratch/due" ]; then
      printf '\n'
      cat "$scratch/due"
    fi
    if [ -s "$scratch/slow" ]; then
      printf '\n'
      cat "$scratch/slow"
    fi
  } > "$scratch/body" || return 2
}

# promote_cmd <id>: set a shadow rule's severity to block (LIFE-AC3). Any other
# severity exits 2 and nothing changes. Only the severity line is rewritten: its
# trailing comment and every other byte stay, and so does the file mode.
promote_cmd() {
  local id root file ids found=0 sev hit n repl tmp
  [ "$#" -eq 1 ] || die "usage: gauntlet promote <id>"
  id=$1
  root=$(repo_root) || return 2
  ids=$(tmp_new) || return 2
  if rule_ids > "$ids" && GL_ID=$id awk '$0 == ENVIRON["GL_ID"] { found = 1 } END { exit !found }' "$ids"; then
    found=1
  fi
  rm -f "$ids"
  [ "$found" -eq 1 ] || die "unknown rule $id"

  file="$root/.gauntlet/rules/$id.md"
  sev=$(rule_get "$file" severity) || die "cannot read rule $id; run gauntlet doctor"
  if [ "$sev" != shadow ]; then
    die "rule $id has severity [$sev]; only a shadow rule can be promoted"
  fi

  # hit: the line number of the severity line in the frontmatter and that line with
  # shadow replaced by block. The line is read the way rule_get reads it.
  hit=$(awk '
    { t = $0; sub(/\r$/, "", t) }
    t == "---" { n++; next }
    n == 1 {
      colon = index(t, ":")
      if (colon == 0 || substr(t, 1, colon - 1) != "severity") next
      rest = substr($0, colon + 1)
      if (!match(rest, /^[ \t]*shadow/)) exit 1
      ws = substr(rest, 1, RLENGTH - 6)
      printf "%d\t%s\n", NR, substr($0, 1, colon) ws "block" substr(rest, RLENGTH + 1)
      exit 0
    }
  ' "$file") || return 2
  n=${hit%%"$DETECT_TAB"*}
  repl=${hit#*"$DETECT_TAB"}

  # Splice by line, not by rewriting every line: head and tail copy the other bytes
  # exactly, including a missing final newline.
  tmp=$(tmp_new) || return 2
  if ! { head -n "$((n - 1))" "$file" && printf '%s\n' "$repl" && tail -n +"$((n + 1))" "$file"; } > "$tmp"; then
    rm -f "$tmp"
    return 2
  fi
  # Writing over the file keeps its mode; moving the temp file would not.
  if ! cat "$tmp" > "$file"; then
    rm -f "$tmp"
    printf 'gauntlet: cannot write %s\n' "$(path_spell "$file")" >&2
    return 2
  fi
  rm -f "$tmp"
  printf 'promoted %s: shadow -> block; commit the rule file\n' "$(path_spell "$id")"
}

# doctor_ok <thing>: print an ok line.
doctor_ok() {
  printf 'ok %s\n' "$(path_spell "$1")"
}

# doctor_fail <thing>: print a FAIL line and count it. The text is "<thing>: <how to fix>".
doctor_fail() {
  printf 'FAIL %s\n' "$(path_spell "$1")"
  DOCTOR_FAILS=$((DOCTOR_FAILS + 1))
}

# doctor_cmd: check the setup and print one line per check, "ok <thing>" or
# "FAIL <thing>: <how to fix>". Exits 1 on any FAIL, and 2 when the setup is broken
# (not in a git repo, or no .gauntlet/ directory). A stale waiver is listed and
# never fails.
doctor_cmd() {
  local root scratch status=0
  [ "$#" -eq 0 ] || die "usage: gauntlet doctor"
  root=$(repo_root) || return 2
  [ -d "$root/.gauntlet" ] || die "not a gauntlet repo: run gauntlet install"
  scratch=$(tmp_new -d) || return 2
  DOCTOR_FAILS=0
  doctor_checks "$root" "$scratch" || status=$?
  rm -rf "$scratch"
  [ "$status" -eq 0 ] || return "$status"
  [ "$DOCTOR_FAILS" -eq 0 ]
}

# doctor_checks <root> <scratch>: run the checks in order. Each prints its lines and
# counts its FAILs; a check returns 2 only when it cannot run at all. <scratch>/causes
# lists the rules whose tool or engine is already a FAIL, so later checks that would
# repeat that cause stay quiet.
doctor_checks() {
  local root=$1 scratch=$2
  hook_paths || return 2
  rule_ids > "$scratch/ids" || return 2
  : > "$scratch/causes" || return 2
  doctor_tools "$root" "$scratch" || return 2
  doctor_hooks "$root" "$scratch" || return 2
  doctor_baseline "$root" "$scratch" || return 2
  doctor_config "$root" "$scratch" || return 2
  doctor_rules "$root" "$scratch" || return 2
  doctor_waivers "$root" "$scratch" || return 2
}

# doctor_tools <root> <scratch>: each rule's engine tool must be on PATH or be an
# executable path. ast-grep names its own tool; rg, linter and script rules name it as
# the first word of the detector. A first word with quoting, a variable, an assignment
# or a leading ~ is not a plain name, and bash -c may run it fine, so it is not
# checked. An unknown engine or an empty detector is doctor_rules' to report; it is
# only recorded here.
doctor_tools() {
  local root=$1 scratch=$2 id engine detector tool hint fix
  while IFS= read -r id; do
    engine=$(rule_get "$root/.gauntlet/rules/$id.md" engine) || engine=
    detector=$(rule_get "$root/.gauntlet/rules/$id.md" detector) || detector=
    case "$engine" in
      ast-grep) tool=ast-grep ;;
      rg|linter|script) tool=${detector%%[[:space:]]*} ;;
      *)
        printf '%s\n' "$id" >> "$scratch/causes"
        continue
        ;;
    esac
    if [ -z "$tool" ]; then
      printf '%s\n' "$id" >> "$scratch/causes"
      continue
    fi
    case "$tool" in
      *=*|*\$*|*\'*|*\"*|*\`*|\~*)
        doctor_ok "tool $id: cannot check ($tool)"
        continue
        ;;
    esac
    if tool_present "$tool" "$root"; then
      doctor_ok "tool $tool for rule $id"
    else
      printf '%s\n' "$id" >> "$scratch/causes"
      hint=$(missing_tool_hint "$tool")
      if [ -n "$hint" ]; then
        fix=${hint#. }
      else
        fix="install it or fix the detector in .gauntlet/rules/$id.md"
      fi
      doctor_fail "tool $tool for rule $id is missing: $fix"
    fi
  done < "$scratch/ids"
  return 0
}

# doctor_runner <root>: the vendored runner must load. `--version` sources the entry
# point's libraries before it does anything, so it proves that every lib file loads
# too. The hooks call this file, so a broken copy would fail every commit.
doctor_runner() {
  local root=$1
  if [ -f "$root/.gauntlet/bin/gauntlet" ] && [ -x "$root/.gauntlet/bin/gauntlet" ] \
    && "$root/.gauntlet/bin/gauntlet" --version < /dev/null > /dev/null 2>&1; then
    doctor_ok "runner .gauntlet/bin/gauntlet"
  else
    doctor_fail ".gauntlet/bin or .gauntlet/lib is broken or missing: run gauntlet install from a gauntlet checkout (a .gitignore entry such as lib/ also drops .gauntlet/lib)"
  fi
}

# doctor_formats <root> <scratch>: each rule's format must be a built-in that the running
# runner ships, or a project file under .gauntlet/formats/. A name that is neither is one FAIL
# on its rule, and the rule is recorded as a cause, so the baseline does not repeat it. A
# built-in that the vendored copy lacks is one FAIL per format name, listing its rules. The
# vendored check runs only when .gauntlet/lib exists and is not the running runner's lib; a
# missing lib is the runner FAIL.
doctor_formats() {
  local root=$1 scratch=$2 id engine format name vendored="" here check_vendored=1
  here=$(cd "$GAUNTLET_LIB" && pwd -P) || return 2
  if [ -d "$root/.gauntlet/lib" ]; then
    vendored=$(cd "$root/.gauntlet/lib" && pwd -P) || vendored=
  fi
  if [ -z "$vendored" ] || [ "$vendored" = "$here" ]; then
    check_vendored=0
  fi
  : > "$scratch/missing-formats" || return 2
  while IFS= read -r id; do
    engine=$(rule_get "$root/.gauntlet/rules/$id.md" engine) || engine=
    format=$(rule_get "$root/.gauntlet/rules/$id.md" format) || format=
    name=$(effective_format "$engine" "$format") || continue
    if [ -f "$root/.gauntlet/formats/$name.md" ]; then
      continue
    fi
    if [ ! -f "$GAUNTLET_LIB/formats/$name.md" ]; then
      doctor_fail "rule $id: format $name is unknown: use a built-in format or add .gauntlet/formats/$name.md"
      printf '%s\n' "$id" >> "$scratch/causes" || return 2
      continue
    fi
    if [ "$check_vendored" -eq 1 ] && [ ! -f "$vendored/formats/$name.md" ]; then
      printf '%s\t%s\n' "$name" "$id" >> "$scratch/missing-formats" || return 2
    fi
  done < "$scratch/ids"
  LC_ALL=C sort -u "$scratch/missing-formats" > "$scratch/missing-formats.sorted" || return 2
  awk -F "$DETECT_TAB" '
    $1 != cur {
      if (cur != "") print cur "\t" list
      cur = $1
      list = $2
      next
    }
    { list = list ", " $2 }
    END { if (cur != "") print cur "\t" list }
  ' "$scratch/missing-formats.sorted" > "$scratch/missing-grouped" || return 2
  while IFS="$DETECT_TAB" read -r name rules; do
    doctor_fail "built-in format $name is missing from .gauntlet/lib (rules: $rules): run gauntlet install from a gauntlet checkout (a .gitignore entry such as lib/ also drops .gauntlet/lib)"
  done < "$scratch/missing-grouped"
  return 0
}

# doctor_hooks <root> <scratch>: the runner must load, then the gate line must be in each
# hook install-hooks would use. A lefthook or prek config needs the snippet in it (HOOK-AC7).
doctor_hooks() {
  local root=$1 scratch=$2 target kind dir f execcheck=1
  doctor_runner "$root"
  doctor_formats "$root" "$scratch" || return 2
  target=$(hook_target) || return 2
  kind=${target%% *}
  dir=${target#"$kind"}
  dir=${dir# }
  # git runs a hook in a plain hooks dir, and husky v8 is the same: a file without the exec
  # bit is ignored. A husky v9 layout is run through its wrapper, which needs no exec bit on
  # the user's file. The layout comes from hook_target, the same decision install-hooks makes.
  if [ "$kind" = husky-v9 ]; then
    execcheck=0
  fi
  case "$kind" in
    configs)
      config_files > "$scratch/configs" || return 2
      while IFS= read -r f; do
        if config_has_gate "$f"; then
          doctor_ok "gate in $f"
        else
          doctor_fail "gate missing from $f: run gauntlet install-hooks and add the snippet it prints"
        fi
      done < "$scratch/configs"
      ;;
    husky|husky-v9|dir|print)
      doctor_hook_file pre-commit "$dir/pre-commit" "$HOOK_LINE_STAGED" "$HOOK_GATE_STAGED" "$kind" "$execcheck"
      doctor_hook_file pre-push "$dir/pre-push" "$HOOK_LINE_CI" "$HOOK_GATE_CI" "$kind" "$execcheck" "$HOOK_OLD_LINE_CI" "$HOOK_OLD_GATE_CI"
      ;;
  esac
  return 0
}

# doctor_hook_file <stage> <file> <plain> <gate> <kind> <execcheck> [<old-plain> <old-gate>]:
# <file> must hold a gate line. When execcheck is 1 the hook must be executable, since git
# ignores it otherwise. A hook install-hooks cannot edit, and a hooks dir it only prints for
# (kind print), get the line to add by hand: running install-hooks would print the same thing.
# A line of the old forms (the pre-push line without --pre-push) is named: it keeps judging the
# checked-out branch whatever git pushes, and nothing else shows it.
doctor_hook_file() {
  local stage=$1 file=$2 line=$3 gate=$4 kind=$5 execcheck=$6 old_line=${7:-} old_gate=${8:-} shown manual=0 old=0
  shown=$(display_path "$file")
  if [ "$execcheck" -eq 1 ] && [ -f "$file" ] && [ ! -x "$file" ]; then
    doctor_fail "$stage hook $shown is not executable: chmod +x $shown"
  fi
  if [ -f "$file" ] && hook_has_gate "$file" "$line" "$gate"; then
    doctor_ok "$stage gate in $shown"
    return 0
  fi
  if [ -n "$old_line" ] && [ -f "$file" ] && hook_has_gate "$file" "$old_line" "$old_gate"; then
    old=1
  fi
  if [ "$kind" = print ]; then
    manual=1
  else
    hook_editable "$file" || manual=1
  fi
  if [ "$old" -eq 1 ]; then
    if [ "$manual" -eq 1 ]; then
      doctor_fail "$stage gate in $shown has no --pre-push, so it judges the checked-out branch whatever git pushes: replace that line by hand with: $gate"
    else
      doctor_fail "$stage gate in $shown has no --pre-push, so it judges the checked-out branch whatever git pushes: run gauntlet install-hooks"
    fi
  elif [ "$manual" -eq 1 ]; then
    doctor_fail "$stage gate missing from $shown: add this line by hand as the first command, after the shebang line if there is one: $gate"
  else
    doctor_fail "$stage gate missing from $shown: run gauntlet install-hooks"
  fi
  return 0
}

# doctor_baseline <root> <scratch>: the committed baseline must equal what the code
# measures now: the same comparison check --ci makes, over the tracked files. A dirty
# tree does not change that. When measuring fails for a cause a rule FAIL already names
# (<scratch>/causes), this check says nothing more: it would repeat that cause.
doctor_baseline() {
  local root=$1 scratch=$2 rc=0 reason hint id want="$1/.gauntlet/baseline.tsv"
  if [ ! -f "$root/.gauntlet/baseline.tsv" ]; then
    doctor_fail "baseline .gauntlet/baseline.tsv is missing: run gauntlet baseline and commit it"
    return 0
  fi
  if [ -s "$scratch/causes" ]; then
    # A rule with a tool or engine cause cannot be measured, and its FAIL line already says
    # why. The other rules are measured and compared as usual, so an error from one of them
    # is always shown, whatever the cause rules say.
    awk 'NR == FNR { cause[$0] = 1; next } !($0 in cause)' "$scratch/causes" "$scratch/ids" > "$scratch/ids.rest" || return 2
    if [ ! -s "$scratch/ids.rest" ]; then
      return 0
    fi
    set --
    while IFS= read -r id; do
      set -- "$@" "$id"
    done < "$scratch/ids.rest"
    ( measure all "$scratch/measure" "$@" ) > "$scratch/measure.out" 2> "$scratch/measure.err" || rc=$?
    awk -F "$DETECT_TAB" 'NR == FNR { rest[$0] = 1; next } ($1 in rest)' "$scratch/ids.rest" \
      "$root/.gauntlet/baseline.tsv" > "$scratch/baseline.rest" || return 2
    want="$scratch/baseline.rest"
  else
    ( measure all "$scratch/measure" ) > "$scratch/measure.out" 2> "$scratch/measure.err" || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    reason=$(awk '/^gauntlet: / { sub(/^gauntlet: /, ""); print; exit }' "$scratch/measure.err")
    if [ -z "$reason" ]; then
      reason="measuring the code failed"
    fi
    # Only a reason that names a rule or a tool is fixed there; the others say what to do.
    case "$reason" in
      "broken detector"*|"missing tool"*|"unknown format"*|"format "*|"unknown rule"*|"measuring the code failed") hint="; fix the rule or tool it names" ;;
      *) hint= ;;
    esac
    doctor_fail "baseline cannot be checked: $reason$hint"
  elif cmp -s "$want" "$scratch/measure/measure.tsv"; then
    if [ -s "$scratch/causes" ]; then
      doctor_ok "baseline is exact for the rules that can be measured"
    else
      doctor_ok "baseline is exact"
    fi
  else
    doctor_fail "baseline differs from the code: run gauntlet baseline and commit it"
  fi
  return 0
}

# doctor_config_copy <config> <copy>: the config as doctor reads it. A byte-order mark on line 1
# is dropped only when line 1 is then a comment or blank, which check already accepts. A BOM
# before a key stays, so that key is reported as unknown, and the report says the mark is there.
doctor_config_copy() {
  GL_BOM=$(printf '\357\273\277') LC_ALL=C awk '
    NR == 1 && index($0, ENVIRON["GL_BOM"]) == 1 {
      rest = substr($0, 4)
      if (rest ~ /^[ \t\r]*(#.*)?$/) { print rest; next }
    }
    { print }
  ' "$1" > "$2" || return 2
}

# doctor_config <root> <scratch>: the keys of .gauntlet/config are base, touched and
# check.*. check_key_rows validates them, the same way check does, so the two cannot
# drift. touched must be on or off. Each problem is one FAIL line, and its text names the fix.
doctor_config() {
  local root=$1 scratch=$2 before=$DOCTOR_FAILS cfg problem bom
  cfg="$root/.gauntlet/config"
  if [ -f "$cfg" ]; then
    doctor_config_copy "$cfg" "$scratch/config.copy" || return 2
    check_key_rows "$scratch/config.copy" > "$scratch/keys" || return 2
    bom=$(GL_BOM=$(printf '\357\273\277') LC_ALL=C awk '
      NR == 1 && index($0, ENVIRON["GL_BOM"]) == 1 { found = 1 }
      END { print found + 0 }
    ' "$cfg") || return 2
    GL_BOM_LINE1=$bom awk -F "$DETECT_TAB" '
      $1 == "#BAD" { print "bad check key " $2 ": " $3 }
      $1 == "#MALFORMED" { print $3 }
      $1 == "#UNKNOWN" {
        msg = $3
        if (ENVIRON["GL_BOM_LINE1"] == "1" && $4 == 1) msg = msg "; a byte-order mark is present on line 1"
        print msg
      }
    ' "$scratch/keys" > "$scratch/key-problems" || return 2
    LC_ALL=C sort "$scratch/key-problems" > "$scratch/key-problems.sorted" || return 2
    while IFS= read -r problem; do
      doctor_fail "$problem"
    done < "$scratch/key-problems.sorted"
  fi
  if ! touched_mode > /dev/null 2>&1; then
    doctor_fail "touched must be on or off, got [$(config_get touched off)]: fix the touched line in .gauntlet/config"
  fi
  if [ "$DOCTOR_FAILS" -eq "$before" ]; then
    doctor_ok "config keys"
  fi
  return 0
}

# doctor_rules <root> <scratch>: every rule must pass rule_validate. One line per rule.
doctor_rules() {
  local root=$1 scratch=$2 id file line fix
  while IFS= read -r id; do
    file="$root/.gauntlet/rules/$id.md"
    if rule_validate "$file" > "$scratch/problems"; then
      doctor_ok "rule $id"
    else
      while IFS= read -r line; do
        line=${line#"$file: "}
        # The script-row problem (rules.sh rule_validate) is fixed in exceptions.tsv;
        # every other problem is fixed in the rule file.
        case "$line" in
          "engine=script needs a script row"*) fix=$(exc_script_hint "$id") ;;
          *) fix=.gauntlet/rules/$id.md ;;
        esac
        doctor_fail "rule $id: $line; fix $fix"
      done < "$scratch/problems"
    fi
  done < "$scratch/ids"
  return 0
}

# doctor_waivers <root> <scratch>: list the waive rows whose branch is not the current one
# (EXC-AC11). They never fail: a stale waiver exempts nothing, and removing it is a later
# step. Loosen and remove rows are not waivers and are never listed.
doctor_waivers() {
  local root=$1 scratch=$2 branch file
  file=$(exc_file) || return 2
  branch=$(current_branch) || return 2
  : > "$scratch/stale"
  if [ -f "$file" ]; then
    GL_BRANCH=$branch awk -F "$DETECT_TAB" '
      $1 == "waive" && $5 != ENVIRON["GL_BRANCH"] { printf "stale waive %s (branch %s)\n", $2, $5 }
    ' "$file" > "$scratch/stale" || return 2
  fi
  if [ -s "$scratch/stale" ]; then
    path_spell < "$scratch/stale" || return 2
  else
    doctor_ok "no stale waivers"
  fi
  return 0
}
