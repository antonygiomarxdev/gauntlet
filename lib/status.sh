# shellcheck shell=bash
# status, promote and doctor: the rule lifecycle and the setup check (FRD-06 §4 and
# §9, FRD-07 §4.6, FRD-04 §6). Sourced, never executed. Bash 3.2 compatible; awk,
# cmp, grep, head, tail, date and coreutils only. Needs core.sh, rules.sh, paths.sh,
# detect.sh, measure.sh, base.sh, exceptions.sh, check.sh and hooks.sh sourced first.

# DOCTOR_FAILS: how many FAIL lines the current doctor run has printed.
DOCTOR_FAILS=0

# status_cmd: regenerate .gauntlet/STATUS.md and print the same text. The totals are
# the committed baseline's, summed per rule, so no detector runs. The text has a rule
# table, the worst files by block total, the shadow rules due for promotion and the
# commit-stage rules over budget. It has no timestamp: the day is the only clock.
status_cmd() {
  local root today budget scratch status=0
  [ "$#" -eq 0 ] || die "usage: gauntlet status"
  root=$(repo_root) || return 2
  [ -d "$root/.gauntlet" ] || die "not a gauntlet repo: run gauntlet install"
  [ -f "$root/.gauntlet/baseline.tsv" ] || die "baseline .gauntlet/baseline.tsv is missing: run gauntlet install"
  today=$(status_today) || return 2
  budget=$(commit_budget) || return 2
  scratch=$(mktemp -d) || return 2
  status_body "$root" "$scratch" "$today" "$budget" || status=$?
  if [ "$status" -eq 0 ]; then
    if cp "$scratch/body" "$root/.gauntlet/STATUS.md"; then
      cat "$scratch/body" || status=2
    else
      printf 'gauntlet: cannot write .gauntlet/STATUS.md\n' >&2
      status=2
    fi
  fi
  rm -rf "$scratch"
  return "$status"
}

# status_today: print the day status measures against: GAUNTLET_TODAY when set,
# else today's date. Returns 2 with a message when it is not YYYY-MM-DD.
status_today() {
  local day=${GAUNTLET_TODAY:-}
  if [ -z "$day" ]; then
    day=$(date +%Y-%m-%d) || return 2
  fi
  case "$day" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *)
      printf 'gauntlet: GAUNTLET_TODAY must be YYYY-MM-DD, got [%s]\n' "$day" >&2
      return 2
      ;;
  esac
  printf '%s\n' "$day"
}

# status_body <root> <scratch> <today> <budget>: write the STATUS.md text to
# <scratch>/body. The intermediate tables are kept in <scratch> too.
status_body() {
  local root=$1 scratch=$2 today=$3 budget=$4 id rf sev stage since
  : > "$scratch/rules.tsv" || return 2
  rule_ids > "$scratch/ids" || return 2
  while IFS= read -r id; do
    rf="$root/.gauntlet/rules/$id.md"
    sev=$(rule_get "$rf" severity) || { printf 'gauntlet: cannot read rule %s; run gauntlet doctor\n' "$id" >&2; return 2; }
    stage=$(rule_get "$rf" stage) || { printf 'gauntlet: cannot read rule %s; run gauntlet doctor\n' "$id" >&2; return 2; }
    since=$(rule_get "$rf" since) || { printf 'gauntlet: cannot read rule %s; run gauntlet doctor\n' "$id" >&2; return 2; }
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

  # due: a shadow rule at 7 days or more since its since date. Days come from the
  # days-from-civil formula, so leap years and year ends need no calendar library.
  GL_TODAY="$today" awk -F "$DETECT_TAB" '
    function civil(s,   y, m, d, era, yoe, doy, doe) {
      y = substr(s, 1, 4) + 0
      m = substr(s, 6, 2) + 0
      d = substr(s, 9, 2) + 0
      if (m <= 2) y--
      era = int(y / 400)
      yoe = y - era * 400
      doy = int((153 * (m > 2 ? m - 3 : m + 9) + 2) / 5) + d - 1
      doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
      return era * 146097 + doe - 719468
    }
    $2 == "shadow" && $4 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ {
      days = civil(ENVIRON["GL_TODAY"]) - civil($4)
      if (days < 0) days = 0
      if (days >= 7) printf "promote due: %s (shadow since %s, %d days), %d found\n", $1, $4, days, $5
    }
  ' "$scratch/status.tsv" > "$scratch/due" || return 2

  # slow: commit-stage rules whose recorded time is at or over the budget. time.tsv
  # is the rule<TAB>ms file measure writes; when it is absent nothing is listed.
  : > "$scratch/slow"
  if [ -f "$root/.gauntlet/time.tsv" ]; then
    GL_TIME="$root/.gauntlet/time.tsv" GL_BUDGET="$budget" awk -F "$DETECT_TAB" '
      FILENAME == ENVIRON["GL_TIME"] { ms[$1] = $2; next }
      $3 == "commit" && ($1 in ms) && ms[$1] + 0 >= ENVIRON["GL_BUDGET"] + 0 {
        printf "slow: %s %s ms (consider stage: push)\n", $1, ms[$1]
      }
    ' "$root/.gauntlet/time.tsv" "$scratch/status.tsv" > "$scratch/slow" || return 2
  fi

  {
    printf '| rule | severity | total |\n'
    printf '| --- | --- | --- |\n'
    awk -F "$DETECT_TAB" '{ printf "| %s | %s | %s |\n", $1, $2, $5 }' "$scratch/status.tsv"
    if [ -s "$scratch/files.top" ]; then
      printf '\n| file | block total |\n| --- | --- |\n'
      awk -F "$DETECT_TAB" '{ printf "| %s | %s |\n", $2, $1 }' "$scratch/files.top"
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
  ids=$(mktemp) || return 2
  if rule_ids > "$ids" && grep -Fxq -- "$id" "$ids"; then found=1; fi
  rm -f "$ids"
  [ "$found" -eq 1 ] || die "unknown rule $id"

  file="$root/.gauntlet/rules/$id.md"
  sev=$(rule_get "$file" severity) || return 2
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
  tmp=$(mktemp) || return 2
  if ! { head -n "$((n - 1))" "$file" && printf '%s\n' "$repl" && tail -n +"$((n + 1))" "$file"; } > "$tmp"; then
    rm -f "$tmp"
    return 2
  fi
  # Writing over the file keeps its mode; moving the temp file would not.
  if ! cat "$tmp" > "$file"; then
    rm -f "$tmp"
    printf 'gauntlet: cannot write %s\n' "$file" >&2
    return 2
  fi
  rm -f "$tmp"
  printf 'promoted %s: shadow -> block; commit the rule file\n' "$id"
}

# doctor_ok <thing>: print an ok line.
doctor_ok() {
  printf 'ok %s\n' "$1"
}

# doctor_fail <thing>: print a FAIL line and count it. The text is "<thing>: <how to fix>".
doctor_fail() {
  printf 'FAIL %s\n' "$1"
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
  scratch=$(mktemp -d) || return 2
  DOCTOR_FAILS=0
  doctor_checks "$root" "$scratch" || status=$?
  rm -rf "$scratch"
  [ "$status" -eq 0 ] || return "$status"
  [ "$DOCTOR_FAILS" -eq 0 ]
}

# doctor_checks <root> <scratch>: run the checks in order. Each prints its lines and
# counts its FAILs; a check returns 2 only when it cannot run at all.
doctor_checks() {
  local root=$1 scratch=$2
  cd "$root" || return 2
  hook_paths || return 2
  rule_ids > "$scratch/ids" || return 2
  doctor_tools "$root" "$scratch" || return 2
  doctor_hooks "$root" "$scratch" || return 2
  doctor_baseline "$root" "$scratch" || return 2
  doctor_config "$root" "$scratch" || return 2
  doctor_rules "$root" "$scratch" || return 2
  doctor_waivers "$root" "$scratch" || return 2
}

# doctor_tools <root> <scratch>: each rule's engine tool must be on PATH, or be an
# executable path. ast-grep names its own tool; rg, linter and script rules name it
# as the first word of the detector. One line per rule.
doctor_tools() {
  local root=$1 scratch=$2 id engine detector tool hint fix
  while IFS= read -r id; do
    engine=$(rule_get "$root/.gauntlet/rules/$id.md" engine) || engine=
    detector=$(rule_get "$root/.gauntlet/rules/$id.md" detector) || detector=
    case "$engine" in
      ast-grep) tool=ast-grep ;;
      rg|linter|script) tool=${detector%%[[:space:]]*} ;;
      *)
        doctor_fail "tool for rule $id: engine [$engine] is not known; fix .gauntlet/rules/$id.md"
        continue
        ;;
    esac
    if [ -z "$tool" ]; then
      doctor_fail "tool for rule $id: the detector is empty; fix .gauntlet/rules/$id.md"
    elif tool_present "$tool" "$root"; then
      doctor_ok "tool $tool for rule $id"
    else
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

# doctor_hooks <root> <scratch>: the vendored runner must exist and be executable,
# since the hooks call it. Then the gate line must be in each hook install-hooks
# would use. A lefthook or prek config needs the snippet in it (HOOK-AC7).
doctor_hooks() {
  local root=$1 scratch=$2 target kind dir f
  if [ -x "$root/.gauntlet/bin/gauntlet" ]; then
    doctor_ok "runner .gauntlet/bin/gauntlet"
  else
    doctor_fail "runner .gauntlet/bin/gauntlet is missing or not executable: run gauntlet install"
  fi
  target=$(hook_target) || return 2
  kind=${target%% *}
  dir=${target#"$kind"}
  dir=${dir# }
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
    husky|dir|print)
      doctor_hook_file pre-commit "$dir/pre-commit" "$HOOK_LINE_STAGED" "$HOOK_GATE_STAGED" "$kind"
      doctor_hook_file pre-push "$dir/pre-push" "$HOOK_LINE_CI" "$HOOK_GATE_CI" "$kind"
      ;;
  esac
  return 0
}

# doctor_hook_file <stage> <file> <plain> <gate> <kind>: <file> must hold one of the
# gate lines. A hook install-hooks can edit is fixed by running it. A hook it only
# prints (kind print), or one hook_editable refuses, also gets the line to add by hand.
doctor_hook_file() {
  local stage=$1 file=$2 line=$3 gate=$4 kind=$5 shown manual=0
  shown=$(display_path "$file")
  if [ -f "$file" ] && hook_has_gate "$file" "$line" "$gate"; then
    doctor_ok "$stage gate in $shown"
    return 0
  fi
  if [ "$kind" = print ]; then
    manual=1
  else
    hook_editable "$file" || manual=1
  fi
  if [ "$manual" -eq 1 ]; then
    doctor_fail "$stage gate missing from $shown: run gauntlet install-hooks, or add this line by hand: $gate"
  else
    doctor_fail "$stage gate missing from $shown: run gauntlet install-hooks"
  fi
  return 0
}

# doctor_baseline <root> <scratch>: the committed baseline must equal what the code
# measures now: the same comparison check --ci makes, over the tracked files. A dirty
# tree does not change that.
doctor_baseline() {
  local root=$1 scratch=$2 rc=0
  if [ ! -f "$root/.gauntlet/baseline.tsv" ]; then
    doctor_fail "baseline .gauntlet/baseline.tsv is missing: run gauntlet baseline and commit it"
    return 0
  fi
  ( measure all "$scratch/measure" ) || rc=$?
  if [ "$rc" -ne 0 ]; then
    doctor_fail "baseline cannot be checked: measuring the code failed (see above); fix the rule or tool it names"
  elif cmp -s "$root/.gauntlet/baseline.tsv" "$scratch/measure/measure.tsv"; then
    doctor_ok "baseline is exact"
  else
    doctor_fail "baseline differs from the code: run gauntlet baseline and commit it"
  fi
  return 0
}

# doctor_config <root> <scratch>: the keys of .gauntlet/config are base, touched and
# check.*. Check keys are validated by the same rules check --ci uses, and touched
# must be on or off.
doctor_config() {
  local root=$1 scratch=$2 key before=$DOCTOR_FAILS cfg
  cfg="$root/.gauntlet/config"
  if [ ! -f "$cfg" ]; then
    doctor_ok "config keys"
    return 0
  fi
  awk '
    /^[[:space:]]*#/ { next }
    {
      eq = index($0, "=")
      if (eq == 0) next
      key = substr($0, 1, eq - 1)
      gsub(/^[ \t]+|[ \t]+$/, "", key)
      print key
    }
  ' "$cfg" > "$scratch/keys" || return 2
  while IFS= read -r key; do
    case "$key" in
      base|touched|check.*) ;;
      *) doctor_fail "config key $key is not known: use base, touched or check.<name>" ;;
    esac
  done < "$scratch/keys"

  check_key_rows "$cfg" > "$scratch/checks" || return 2
  awk -F "$DETECT_TAB" '$1 == "BAD" { print $2 ": " $3 }' "$scratch/checks" > "$scratch/bad" || return 2
  while IFS= read -r key; do
    doctor_fail "bad check key $key"
  done < "$scratch/bad"

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
  local root=$1 scratch=$2 id file line
  while IFS= read -r id; do
    file="$root/.gauntlet/rules/$id.md"
    if rule_validate "$file" > "$scratch/problems"; then
      doctor_ok "rule $id"
    else
      while IFS= read -r line; do
        doctor_fail "rule $id: ${line#"$file: "}; fix .gauntlet/rules/$id.md"
      done < "$scratch/problems"
    fi
  done < "$scratch/ids"
  return 0
}

# doctor_waivers <root> <scratch>: list the waive rows whose branch is not the
# current one (EXC-AC11). They never fail: a stale waiver exempts nothing, and
# removing it is a later step.
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
    cat "$scratch/stale" || return 2
  else
    doctor_ok "no stale waivers"
  fi
  return 0
}
