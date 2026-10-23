# shellcheck shell=bash
# The gates: check --ci compares the branch with its merge-base, and check
# --staged is the commit gate (the index against HEAD, run from pre-commit).
# Sourced, never executed. Bash 3.2 compatible; awk, sort, cmp, diff and git only.
# Needs core.sh, rules.sh, measure.sh, base.sh, detect.sh and exceptions.sh
# sourced first.

# check_ci [--ci] [--base <ref>]: the CI gate, against the merge-base of HEAD and
# the base ref. Prints the report and returns 0 (ok), 1 (problems) or 2 (setup
# broken, or the tracked files differ from HEAD). Every check runs before the
# exit; there is no fail-fast.
check_ci() {
  local ci=0 base_ref='' dirty scratch status=0 start
  start=$(now_ms)
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --ci) ci=1 ;;
      --base)
        [ "$#" -ge 2 ] || die "usage: gauntlet check --ci [--base <ref>]"
        base_ref=$2
        shift
        ;;
      *) die "usage: gauntlet check --ci [--base <ref>]" ;;
    esac
    shift
  done
  [ "$ci" -eq 1 ] || die "usage: gauntlet check --ci [--base <ref>]"

  # Decision 2: the gate measures the working tree, so it must equal HEAD.
  dirty=$(git diff --name-only HEAD) || return 2
  if [ -n "$dirty" ]; then
    printf 'gauntlet checks what you push; commit or stash first\n' >&2
    return 2
  fi
  scratch=$(mktemp -d) || return 2
  check_run "$scratch" "$base_ref" "$start" || status=$?
  rm -rf "$scratch"
  return "$status"
}

# check_run <scratch> <base-ref> <start-ms>: the work of check_ci, with every
# intermediate file kept in <scratch>. The report goes to stdout. Sections are
# collected in a body file so the header can carry the whole-run time.
check_run() {
  local scratch=$1 base_ref=$2 start=$3 root base sha id rf sev fix atb
  local known=0 n_rules ms end n body new_n=0 global_n=0 touched_n=0 baseline_n=0 mode
  local loosened_n=0 rt_n=0 rt_rc=0 checks_n=0 broken=0 t0 t1
  root=$(repo_root) || return 2
  mode=$(touched_mode) || return 2
  base=$(resolve_base "$base_ref") || return 2
  sha=$(merge_base "$base") || return 2
  # Every file the branch changes, deletions included: the scope of declared checks.
  # --no-renames: a rename lists both its old path (deleted) and its new one.
  git_nul_lines -c core.quotepath=off diff --name-only --no-renames -z "$sha" HEAD > "$scratch/changed" || return 2
  measure all "$scratch/now" || return 2
  rule_ids > "$scratch/ids" || return 2
  n_rules=$(awk 'END { print NR }' "$scratch/ids") || return 2
  # The branch's waived paths, read once; every filter below reads this file.
  waived_paths > "$scratch/waived" || return 2

  # rules.tsv: id, severity, 1 when the rule file exists at base, fix. Severity
  # and fix come from the current rule file; only the existence is read at base.
  : > "$scratch/rules.tsv"
  while IFS= read -r id; do
    rf="$root/.gauntlet/rules/$id.md"
    sev=$(rule_get "$rf" severity) || return 2
    # Fail closed: an unknown severity would otherwise match no comparison.
    if ! severity_rank "$sev" > /dev/null; then
      printf 'gauntlet: rule %s: bad severity [%s]\n' "$id" "$sev" >&2
      return 2
    fi
    fix=$(rule_get "$rf" fix) || return 2
    atb=0
    if git cat-file -e "$sha:.gauntlet/rules/$id.md" 2>/dev/null; then atb=1; fi
    printf '%s\t%s\t%s\t%s\n' "$id" "$sev" "$atb" "$fix" >> "$scratch/rules.tsv"
  done < "$scratch/ids"

  # The base's baseline, never re-measured. Absent means onboarding: checks
  # new, global, shadow and track are skipped; exact still runs.
  : > "$scratch/base.tsv"
  if git cat-file -e "$sha:.gauntlet/baseline.tsv" 2>/dev/null; then
    known=1
    at_base "$sha" .gauntlet/baseline.tsv > "$scratch/base.tsv" || return 2
  fi

  # located.byline: located rows in line order within each fingerprint, so the
  # last occurrences of a key are the new ones.
  LC_ALL=C sort -t "$DETECT_TAB" -k3,3n "$scratch/now/located.tsv" > "$scratch/located.byline" || return 2

  body="$scratch/body"
  : > "$body"
  if [ "$known" -eq 0 ]; then
    printf 'note: no baseline at base; new, global, shadow and track checks skipped\n' >> "$body"
  else
    new_rows block "$scratch" > "$scratch/new.rows" || return 2
    if [ -s "$scratch/new.rows" ]; then
      printf '[new]\n' >> "$body"
      violation_lines "$scratch/new.rows" >> "$body"
    fi
    new_n=$(awk 'END { print NR }' "$scratch/new.rows") || return 2
    global_rows block "$scratch" > "$scratch/global.rows" || return 2
    if [ -s "$scratch/global.rows" ]; then
      printf '[global]\n' >> "$body"
      awk -F '\t' '{ printf "  %s  %s → %s\n", $1, $2, $3 }' "$scratch/global.rows" >> "$body"
    fi
    global_n=$(count_global_extra "$scratch/new.rows" "$scratch/global.rows") || return 2
    # The diff is read only when the touched gate is on: touched=off makes no git call.
    : > "$scratch/touched.diff"
    if [ "$mode" = on ]; then
      git_nul_lines -c core.quotepath=off diff -M -z --name-status "$sha" HEAD > "$scratch/touched.diff" || return 2
    fi
    cmp_touched "$scratch/touched.diff" "$scratch/base.tsv" "$scratch/now/measure.tsv" "$scratch/rules.tsv" \
      "$scratch/waived" > "$scratch/touched.rows" || return 2
    if [ -s "$scratch/touched.rows" ]; then
      printf '[touched]\n' >> "$body"
      awk -F '\t' '{ printf "  %s  %s → %s  (%s)\n", $1, $2, $3, $4 }' "$scratch/touched.rows" >> "$body"
    fi
    touched_n=$(touched_uncovered "$scratch/new.rows" "$scratch/touched.rows") || return 2
  fi

  # Exact: the committed baseline must be byte-equal to what the code measures.
  if ! cmp -s "$root/.gauntlet/baseline.tsv" "$scratch/now/measure.tsv"; then
    printf '[baseline]\n' >> "$body"
    if [ -f "$root/.gauntlet/baseline.tsv" ]; then
      printf '  baseline differs from the code; run gauntlet baseline and commit it\n' >> "$body"
      # Labels, not paths: the output must be identical on every run.
      diff -u -L .gauntlet/baseline.tsv -L measured "$root/.gauntlet/baseline.tsv" \
        "$scratch/now/measure.tsv" > "$scratch/diff" || true
      awk 'NR <= 20' "$scratch/diff" >> "$body"
    else
      printf '  .gauntlet/baseline.tsv is missing; run gauntlet baseline and commit it\n' >> "$body"
    fi
    baseline_n=1
  fi

  # Loosening runs even on the onboarding branch; it is skipped only when the
  # base has no rules to compare with at all.
  if git cat-file -e "$sha:.gauntlet/rules" 2>/dev/null; then
    cmp_loosened "$sha" > "$scratch/loosened.rows" || return 2
    if [ -s "$scratch/loosened.rows" ]; then
      printf '[loosened]\n' >> "$body"
      awk -F '\t' '{ printf "  %s  %s\n", $1, $2 }' "$scratch/loosened.rows" >> "$body"
    fi
    loosened_n=$(awk 'END { print NR }' "$scratch/loosened.rows") || return 2
  fi

  # Rule tests and declared checks run on the onboarding branch too: only the
  # baseline comparisons above need a baseline at base.
  : > "$scratch/check.time"
  check_table "$root" "$scratch" || return 2
  if rule_tests_due "$scratch/changed"; then
    t0=$(now_ms)
    run_rule_tests "$root" > "$scratch/rule-tests.out" && rt_rc=0 || rt_rc=$?
    t1=$(now_ms)
    printf 'rule-tests\t%s\n' "$((t1 - t0))" >> "$scratch/check.time"
    # A setup that cannot run the tests still prints what it found, then exits 2.
    if [ "$rt_rc" -gt 1 ]; then broken=1; fi
    rt_n=$(awk 'END { print NR }' "$scratch/rule-tests.out") || return 2
    if [ -s "$scratch/rule-tests.out" ]; then
      printf '[rule-tests]\n' >> "$body"
      cat "$scratch/rule-tests.out" >> "$body" || return 2
    fi
  fi
  run_declared_checks "$root" "$scratch" || return 2
  checks_n=$(awk 'END { print NR }' "$scratch/checks.failed") || return 2
  if [ -s "$scratch/checks.failed" ]; then
    printf '[checks]\n' >> "$body"
    cat "$scratch/checks.body" >> "$body" || return 2
  fi

  if [ "$known" -eq 1 ]; then
    new_rows shadow "$scratch" > "$scratch/shadow.rows" || return 2
    if [ -s "$scratch/shadow.rows" ]; then
      printf '[shadow] would have failed\n' >> "$body"
      violation_lines "$scratch/shadow.rows" >> "$body"
    fi
    global_rows track "$scratch" > "$scratch/track.rows" || return 2
    if [ -s "$scratch/track.rows" ]; then
      printf '[track]\n' >> "$body"
      awk -F '\t' '{ printf "  %s  %s → %s (+%d); consider promoting\n", $1, $2, $3, $3 - $2 }' \
        "$scratch/track.rows" >> "$body"
    fi
  fi

  printf '[time]\n' >> "$body"
  awk -F '\t' '{ printf "  %s  %s ms\n", $1, $2 }' "$scratch/now/time.tsv" "$scratch/check.time" >> "$body"

  # R18: one problem per [new] line, one per [global] rule whose rise its [new]
  # lines do not account for, one per [touched] line, one for [baseline], one
  # per [loosened] line, one per [rule-tests] line, one per failed check. Shadow
  # and track count nothing.
  n=$((new_n + global_n + touched_n + baseline_n + loosened_n + rt_n + checks_n))

  end=$(now_ms)
  ms=$((end - start))
  printf 'gauntlet  ci · %s rules · %s.%s s\n' "$n_rules" "$((ms / 1000))" "$(((ms % 1000) / 100))"
  cat "$body"
  if [ "$broken" -eq 1 ]; then
    printf 'gauntlet: rule tests could not run\n' >&2
    return 2
  fi
  if [ "$n" -eq 0 ]; then
    printf 'gauntlet: ok\n'
    return 0
  fi
  printf 'gauntlet: FAIL (%s problems)\n' "$n"
  return 1
}

# rule_tests_due <changed>: succeed when a file under .gauntlet/rules/ or
# .gauntlet/formats/ is in the changed list (R5). <changed> is one path per line.
rule_tests_due() {
  awk '
    index($0, ".gauntlet/rules/") == 1 || index($0, ".gauntlet/formats/") == 1 { hit = 1 }
    END { exit !hit }
  ' "$1"
}

# check_table <root> <scratch>: read the declared checks from .gauntlet/config
# into <scratch>/checks.raw, one "<name>\t<ci>\t<paths>\t<command>" row per
# check, sorted by name. Keys are check.<name>, check.<name>.paths and
# check.<name>.ci, names matching ^[A-Za-z0-9_-]+$. Any other check. key, an
# attribute with no command, an empty command, or a ci that is not on or off
# is a bad key: the table is refused and the key is named on stderr (exit 2).
check_table() {
  local root=$1 scratch=$2 bad
  : > "$scratch/checks.all"
  if [ -f "$root/.gauntlet/config" ]; then
    awk '
      /^[[:space:]]*#/ { next }
      {
        eq = index($0, "=")
        if (eq == 0) next
        key = substr($0, 1, eq - 1)
        gsub(/^[ \t]+|[ \t]+$/, "", key)
        if (substr(key, 1, 6) != "check.") next
        val = substr($0, eq + 1)
        gsub(/^[ \t]+|[ \t]+$/, "", val)
        rest = substr(key, 7)
        if (rest ~ /^[A-Za-z0-9_-]+$/) { cmd[rest] = val; declared[rest] = key }
        else if (rest ~ /^[A-Za-z0-9_-]+\.(paths|ci)$/) {
          name = substr(rest, 1, index(rest, ".") - 1)
          attr_key[name] = key
          if (rest ~ /\.paths$/) paths[name] = val
          else ci[name] = val
        }
        else bad[key] = 1
      }
      END {
        for (name in attr_key)
          if (!(name in declared)) print "BAD\t" attr_key[name] "\tattribute without a command"
        for (name in declared) {
          if (cmd[name] == "") { print "BAD\t" declared[name] "\tempty command"; continue }
          c = (name in ci) ? ci[name] : "off"
          if (c != "on" && c != "off") {
            print "BAD\t" declared[name] ".ci\t.ci must be on or off, got [" c "]"
            continue
          }
          printf "%s\t%s\t%s\t%s\n", name, c, paths[name], cmd[name]
        }
        for (key in bad) print "BAD\t" key "\tnot a check key; use check.<name>, check.<name>.paths or check.<name>.ci"
      }
    ' "$root/.gauntlet/config" > "$scratch/checks.all" || return 2
  fi
  LC_ALL=C sort "$scratch/checks.all" > "$scratch/checks.raw" || return 2
  # Sorted before the first bad row is taken, so the reported key is the same on every run.
  bad=$(awk -F '\t' '$1 == "BAD" { print $2 ": " $3; exit }' "$scratch/checks.raw") || return 2
  if [ -n "$bad" ]; then
    printf 'gauntlet: bad check key %s\n' "$bad" >&2
    return 2
  fi
}

# run_declared_checks <root> <scratch>: run each check of <scratch>/checks.raw
# that is in scope and, under CI=true, has ci=on. Each runs as bash -c from the
# repo root; output goes to a temp file. A failure appends "  <name>  exit <code>"
# and the last 20 output lines (indented) to <scratch>/checks.body and a line to
# <scratch>/checks.failed. Every check that runs adds its time to check.time.
run_declared_checks() {
  local root=$1 scratch=$2 row name ci paths cmd code out kept t0 t1
  out="$scratch/check.out"
  kept="$scratch/check.kept"
  : > "$scratch/checks.body"
  : > "$scratch/checks.failed"
  # The table is read on fd 3, so no check can consume its rows through stdin.
  while IFS= read -r row <&3; do
    name=${row%%"$DETECT_TAB"*}
    row=${row#*"$DETECT_TAB"}
    ci=${row%%"$DETECT_TAB"*}
    row=${row#*"$DETECT_TAB"}
    paths=${row%%"$DETECT_TAB"*}
    cmd=${row#*"$DETECT_TAB"}
    if [ "${CI:-}" = true ] && [ "$ci" != on ]; then continue; fi
    if ! check_in_scope "$paths" "$scratch/changed"; then continue; fi

    t0=$(now_ms)
    (cd "$root" && bash -c "$cmd") < /dev/null 3<&- > "$out" 2>&1 && code=0 || code=$?
    t1=$(now_ms)
    printf 'check:%s\t%s\n' "$name" "$((t1 - t0))" >> "$scratch/check.time"
    if [ "$code" -ne 0 ]; then
      printf 'x\n' >> "$scratch/checks.failed"
      printf '  %s  exit %s\n' "$name" "$code" >> "$scratch/checks.body"
      tail -n 20 "$out" > "$kept" || return 2
      awk '{ printf "    %s\n", $0 }' "$kept" >> "$scratch/checks.body" || return 2
    fi
    rm -f "$out" "$kept"
  done 3< "$scratch/checks.raw"
}

# check_in_scope <paths> <changed>: succeed when the check has no paths (always)
# or when a changed path starts with one of the space-separated prefixes.
check_in_scope() {
  local paths=$1 changed=$2
  if [ -z "$paths" ]; then return 0; fi
  GL_PATHS=$paths awk '
    BEGIN { n = split(ENVIRON["GL_PATHS"], p, " ") }
    { for (i = 1; i <= n; i++) if (index($0, p[i]) == 1) hit = 1 }
    END { exit !hit }
  ' "$changed"
}

# new_rows <severity> <scratch>: print one row per new occurrence of a rule of
# that severity that exists at base: rule, path, line, fix, message. An
# occurrence is new when its fingerprint count rose; the last occurrences in
# line order are the new ones. Waived rows are dropped.
new_rows() {
  local sev=$1 scratch=$2
  GL_SEV=$sev GL_RULES="$scratch/rules.tsv" GL_BASE="$scratch/base.tsv" \
    GL_NOW="$scratch/now/measure.tsv" GL_LOC="$scratch/located.byline" awk -F '\t' '
    FILENAME == ENVIRON["GL_RULES"] { sev[$1] = $2; atb[$1] = $3; fix[$1] = $4; next }
    FILENAME == ENVIRON["GL_BASE"] { bc[$1 SUBSEP $2 SUBSEP $3] = $4; next }
    FILENAME == ENVIRON["GL_NOW"] {
      k = $1 SUBSEP $2 SUBSEP $3
      if (sev[$1] == ENVIRON["GL_SEV"] && atb[$1] == "1" && $4 - bc[k] > 0) need[k] = 1
      next
    }
    FILENAME == ENVIRON["GL_LOC"] {
      k = $1 SUBSEP $2 SUBSEP $4
      seen[k]++
      if (k in need && seen[k] > bc[k] + 0) {
        m = $0
        for (i = 0; i < 4; i++) sub(/^[^\t]*\t/, "", m)
        printf "%s\t%s\t%s\t%s\t%s\n", $1, $2, $3, fix[$1], m
      }
    }
  ' "$scratch/rules.tsv" "$scratch/base.tsv" "$scratch/now/measure.tsv" "$scratch/located.byline" > "$scratch/new.raw" || return 2
  LC_ALL=C sort -t "$DETECT_TAB" -k1,1 -k2,2 -k3,3n "$scratch/new.raw" > "$scratch/new.sorted" || return 2
  # A waived path drops its rows; one awk pass over the waived set, not a fork per row.
  GL_WAIVED="$scratch/waived" awk -F '\t' '
    FILENAME == ENVIRON["GL_WAIVED"] { waived[$0] = 1; next }
    !($2 in waived)
  ' "$scratch/waived" "$scratch/new.sorted" || return 2
}

# global_rows <severity> <scratch> [now-file]: print rule, base total, current
# total for each rule of that severity that exists at base whose total rose.
# The current total is read from [now-file], default <scratch>/now/measure.tsv.
global_rows() {
  local sev=$1 scratch=$2 now=${3:-}
  [ -n "$now" ] || now="$scratch/now/measure.tsv"
  GL_SEV=$sev GL_RULES="$scratch/rules.tsv" GL_BASE="$scratch/base.tsv" \
    GL_NOW="$now" awk -F '\t' '
    FILENAME == ENVIRON["GL_RULES"] { sev[$1] = $2; atb[$1] = $3; next }
    FILENAME == ENVIRON["GL_BASE"] { bt[$1] += $4; next }
    FILENAME == ENVIRON["GL_NOW"] { nt[$1] += $4; next }
    END {
      for (r in sev)
        if (sev[r] == ENVIRON["GL_SEV"] && atb[r] == "1" && nt[r] + 0 > bt[r] + 0)
          printf "%s\t%s\t%s\n", r, bt[r] + 0, nt[r] + 0
    }
  ' "$scratch/rules.tsv" "$scratch/base.tsv" "$now" > "$scratch/global.raw" || return 2
  LC_ALL=C sort "$scratch/global.raw"
}

# touched_uncovered <new-rows> <touched-rows>: count the touched rows whose file
# has no [new] line. R20: a file with a [new] line is already explained by it, so
# it is not counted again; [touched] still prints it.
touched_uncovered() {
  GL_NEW=$1 awk -F '\t' '
    FILENAME == ENVIRON["GL_NEW"] { covered[$2] = 1; next }
    !($1 in covered) { n++ }
    END { print n + 0 }
  ' "$1" "$2"
}

# count_global_extra <new-rows> <global-rows>: print how many [global] rules rose
# further than their [new] lines account for (the rise came from waived paths).
count_global_extra() {
  GL_NEW=$1 awk -F '\t' '
    FILENAME == ENVIRON["GL_NEW"] { newc[$1]++; next }
    $3 - $2 > newc[$1] + 0 { n++ }
    END { print n + 0 }
  ' "$1" "$2"
}

# violation_lines <rows>: print each new_rows row as a violation line and its
# fix line. The message runs to the end of the row, so it may contain tabs.
violation_lines() {
  awk -F '\t' '{
    m = $0
    for (i = 0; i < 4; i++) sub(/^[^\t]*\t/, "", m)
    printf "  %s:%s  %s  %s\n      fix: %s\n", $2, $3, $1, m, $4
  }' "$1"
}

# touched_mode: print the touched gate's setting, on or off (config touched=,
# default off). Any other value is a broken setup: exit 2, so it never turns
# the gate off silently.
touched_mode() {
  local value
  value=$(config_get touched off) || return 2
  case "$value" in
    on|off) printf '%s\n' "$value" ;;
    *)
      printf 'gauntlet: touched must be on or off, got [%s]\n' "$value" >&2
      return 2
      ;;
  esac
}

# cmp_touched <diff> <base.tsv> <measure.tsv> <rules.tsv> <waived>: the touched
# gate (opt-in via config touched=on). <diff> is `git diff -M -z --name-status`
# output, one token per line (git_nul_lines): the base-to-tree diff the caller
# judges, the merge-base to HEAD in check --ci, the index against HEAD at commit.
# Each file it changes must come out with less block debt than it had at base.
# Prints one tab row per file that breaks that rule (path, base, now, reason) and
# returns 0; prints nothing when the gate is off. Debt counts only block rules
# that exist at base; rows of waived paths are skipped.
cmp_touched() {
  local diff=$1 base=$2 now=$3 rules=$4 waived=$5 mode scratch status=0
  mode=$(touched_mode) || return 2
  [ "$mode" = on ] || return 0
  scratch=$(mktemp -d) || return 2
  cmp_touched_in "$diff" "$base" "$now" "$rules" "$waived" "$scratch" || status=$?
  rm -rf "$scratch"
  return "$status"
}

# cmp_touched_in <diff> <base.tsv> <measure.tsv> <rules.tsv> <waived> <scratch>:
# the work of cmp_touched, with intermediate files kept in <scratch>.
cmp_touched_in() {
  local diff=$1 base=$2 now=$3 rules=$4 waived=$5 scratch=$6
  # R15: `.gauntlet/` is never judged. R100 (pure rename) and D are skipped.
  # Both are early-outs: judged anyway, their verdict would be the same.
  # -z output is one token per line: a status, then one path (two for R or C).
  awk '
    {
      if (need == 0) { st = $0; need = (st ~ /^[RC]/) ? 2 : 1; k = 0; next }
      p[++k] = $0
      need--
      if (need > 0) next
      old = p[1]
      nw = (k == 2) ? p[2] : p[1]
      if (index(old, ".gauntlet/") == 1 || index(nw, ".gauntlet/") == 1) next
      if (st == "A" || st == "M") printf "%s\t%s\t%s\n", st, old, old
      else if (st ~ /^R/ && st != "R100") printf "R\t%s\t%s\n", old, nw
    }
  ' "$diff" > "$scratch/changes" || return 2

  # sums: fingerprint rows of block rules that exist at base, for the changed
  # paths only. B rows are the base's debt at the old paths, N rows the current
  # debt at the new paths. The base is never re-measured.
  GL_CH="$scratch/changes" GL_RULES="$rules" GL_BASE="$base" GL_NOW="$now" awk -F '\t' '
    FILENAME == ENVIRON["GL_CH"] { old[$2] = 1; nw[$3] = 1; next }
    FILENAME == ENVIRON["GL_RULES"] { if ($2 == "block" && $3 == "1") blk[$1] = 1; next }
    FILENAME == ENVIRON["GL_BASE"] { if (($2 in old) && ($1 in blk)) print "B\t" $1 "\t" $2 "\t" $4; next }
    FILENAME == ENVIRON["GL_NOW"] { if (($2 in nw) && ($1 in blk)) print "N\t" $1 "\t" $2 "\t" $4 }
  ' "$scratch/changes" "$rules" "$base" "$now" > "$scratch/sums" || return 2

  # Waivers drop a path's rows from the totals. Sum rows are B or N, rule, path,
  # count: the path is field 3.
  GL_WAIVED="$waived" awk -F '\t' '
    FILENAME == ENVIRON["GL_WAIVED"] { waived[$0] = 1; next }
    !($3 in waived)
  ' "$waived" "$scratch/sums" > "$scratch/kept" || return 2

  GL_CH="$scratch/changes" GL_KEPT="$scratch/kept" awk -F '\t' '
    FILENAME == ENVIRON["GL_CH"] { st[++n] = $1; old[n] = $2; nw[n] = $3; next }
    FILENAME == ENVIRON["GL_KEPT"] {
      if ($1 == "B") base[$3] += $4
      else now[$3] += $4
      next
    }
    END {
      for (i = 1; i <= n; i++) {
        p = nw[i]
        c = now[p] + 0
        if (st[i] == "A") { b = 0; bad = c > 0; why = "must be 0" }
        else {
          b = base[old[i]] + 0
          if (b > 0) { bad = c >= b; why = "must go down" }
          else { bad = c > 0; why = "must stay 0" }
        }
        if (bad) printf "%s\t%d\t%d\t%s\n", p, b, c, why
      }
    }
  ' "$scratch/changes" "$scratch/kept" > "$scratch/touched" || return 2
  cat "$scratch/touched"
}

# cmp_loosened <merge-base>: the no-loosening check (decision 6, EXC-AC5..AC8).
# Compares each rule file at the merge-base with the working tree and prints a
# tab row (rule, what changed) for each loosening that no new exceptions.tsv
# row covers. Prints nothing when nothing was loosened.
cmp_loosened() {
  local mb=$1 scratch status=0
  scratch=$(mktemp -d) || return 2
  cmp_loosened_in "$mb" "$scratch" || status=$?
  rm -rf "$scratch"
  return "$status"
}

# cmp_loosened_in <merge-base> <scratch>: the work of cmp_loosened, with
# intermediate files kept in <scratch>. Only rules that exist at the base are
# judged; a rule added on the branch is never loosened.
cmp_loosened_in() {
  local mb=$1 scratch=$2 root name rest id
  root=$(repo_root) || return 2
  exc_new_rows "$mb" "$scratch/exc.new" || return 2
  awk -F "$DETECT_TAB" '$1 == "loosen" { print $2 }' "$scratch/exc.new" > "$scratch/new.loosen" || return 2
  awk -F "$DETECT_TAB" '$1 == "remove" { print $2 }' "$scratch/exc.new" > "$scratch/new.remove" || return 2
  git_nul_lines -c core.quotepath=off ls-tree -r --name-only -z "$mb" .gauntlet/rules > "$scratch/base.rules" || return 2

  : > "$scratch/out"
  while IFS= read -r name; do
    case "$name" in .gauntlet/rules/*.md) ;; *) continue ;; esac
    rest=${name#.gauntlet/rules/}
    case "$rest" in */*) continue ;; esac
    id=${rest%.md}
    # The same case files rule_ids skips.
    case "$id" in *.bad|*.bad.*|*.good|*.good.*) continue ;; esac
    at_base "$mb" "$name" > "$scratch/base.md" || return 2

    if [ ! -f "$root/$name" ]; then
      if ! GL_ID=$id awk '$0 == ENVIRON["GL_ID"] { found = 1 } END { exit !found }' "$scratch/new.remove"; then
        printf '%s\trule file removed\n' "$id" >> "$scratch/out"
      fi
      continue
    fi

    loosen_changes "$mb" "$scratch" "$id" "$scratch/base.md" "$root/$name" > "$scratch/changes" || return 2
    if [ -s "$scratch/changes" ] &&
      ! GL_ID=$id awk 'index($0, ENVIRON["GL_ID"] ":") == 1 { found = 1 } END { exit !found }' "$scratch/new.loosen"; then
      GL_ID=$id awk '{ printf "%s\t%s\n", ENVIRON["GL_ID"], $0 }' "$scratch/changes" >> "$scratch/out" || return 2
    fi
  done < "$scratch/base.rules"
  cat "$scratch/out"
}

# loosen_changes <merge-base> <scratch> <rule-id> <base-rule> <current-rule>:
# print one line per way the rule was loosened since the merge-base. Raising a
# severity, widening paths, narrowing exclude and a format that stays the same
# are not loosening.
loosen_changes() {
  local mb=$1 scratch=$2 id=$3 brule=$4 crule=$5
  local root bsev csev rb rc bp cp be ce beng ceng bdet cdet bfe cfe bfmt cfmt gp
  root=$(repo_root) || return 2
  bsev=$(rule_get "$brule" severity) || return 2
  csev=$(rule_get "$crule" severity) || return 2
  rb=$(severity_rank "$bsev") || rb=0
  rc=$(severity_rank "$csev") || rc=0
  if [ "$rb" -gt "$rc" ]; then printf 'severity %s → %s\n' "$bsev" "$csev"; fi

  bp=$(rule_get "$brule" paths) || return 2
  cp=$(rule_get "$crule" paths) || return 2
  be=$(rule_get "$brule" exclude) || return 2
  ce=$(rule_get "$crule" exclude) || return 2
  [ -n "$bp" ] || bp='**'
  [ -n "$cp" ] || cp='**'
  list_missing "paths narrowed:" "$bp" "$cp"
  list_missing "exclude widened:" "$ce" "$be"

  beng=$(rule_get "$brule" engine) || return 2
  ceng=$(rule_get "$crule" engine) || return 2
  if [ "$beng" != "$ceng" ]; then printf 'engine %s → %s\n' "$beng" "$ceng"; fi
  bdet=$(rule_get "$brule" detector) || return 2
  cdet=$(rule_get "$crule" detector) || return 2
  if [ "$bdet" != "$cdet" ]; then printf 'detector changed\n'; fi
  # Each word of an unchanged detector that names a file is judged by that
  # file's blob. The words are split with globbing off, so {files} and flags
  # are plain words that name nothing. A changed string is reported above.
  if [ "$bdet" = "$cdet" ]; then
    (set -f; for w in $cdet; do printf '%s\n' "$w"; done) > "$scratch/words" || return 2
    while IFS= read -r w; do
      w=${w#./}
      if blob_changed "$mb" "$w"; then printf 'detector file %s changed\n' "$w"; fi
    done < "$scratch/words"
  fi

  # A format decides which output lines count, so it is judged for block rules.
  bfe=$(rule_get "$brule" format) || return 2
  cfe=$(rule_get "$crule" format) || return 2
  bfmt=$(effective_format "$beng" "$bfe") || return 2
  cfmt=$(effective_format "$ceng" "$cfe") || return 2
  if [ "$csev" = block ]; then
    if [ "$bfmt" != "$cfmt" ]; then printf 'format %s → %s\n' "$bfmt" "$cfmt"; fi
    gp=.gauntlet/formats/$cfmt.md
    if blob_changed "$mb" "$gp"; then
      if ! git cat-file -e "$mb:$gp" 2>/dev/null; then
        printf 'format file %s added\n' "$gp"
      elif ! git cat-file -e "HEAD:$gp" 2>/dev/null; then
        printf 'format file %s removed\n' "$gp"
      else
        printf 'format file %s changed\n' "$gp"
      fi
    fi
  fi
}

# blob_changed <merge-base> <path>: true when <path> has a different git blob at
# the merge-base than at HEAD; a path absent on one side is a different blob.
# Blob ids, not file reads: a symlink compares by its link text, and HEAD is
# clean (check --ci refuses a dirty tree), so HEAD is what CI runs.
blob_changed() {
  local a b
  a=$(git rev-parse -q --verify "$1:$2" 2>/dev/null) || a=
  b=$(git rev-parse -q --verify "HEAD:$2" 2>/dev/null) || b=
  [ "$a" != "$b" ]
}

# list_missing <label> <list> <other>: print "<label> <glob>" for each word of
# <list> that <other> lacks. Words are space-separated globs.
list_missing() {
  GL_LABEL=$1 GL_LIST=$2 GL_OTHER=$3 awk 'BEGIN {
    n = split(ENVIRON["GL_OTHER"], o, " ")
    for (i = 1; i <= n; i++) have[o[i]] = 1
    m = split(ENVIRON["GL_LIST"], l, " ")
    for (i = 1; i <= m; i++) if (!(l[i] in have)) print ENVIRON["GL_LABEL"], l[i]
  }'
}

# check_staged [--staged]: the commit gate, run from pre-commit (ADR-0007). It
# judges the working-tree content of the staged files against HEAD's baseline:
# new block violations and touched files block; shadow and track are reported.
# Only stage=commit rules run here; push owns the rest. On a pass it rewrites
# the index's .gauntlet/baseline.tsv and stages it into this commit, so the
# commit carries the baseline it measures. Prints the report and returns 0 (ok),
# 1 (problems) or 2 (setup broken).
check_staged() {
  local start status=0 scratch
  start=$(now_ms)
  [ "$#" -eq 0 ] || die "usage: gauntlet check --staged"
  scratch=$(mktemp -d) || return 2
  check_staged_run "$scratch" "$start" || status=$?
  rm -rf "$scratch"
  return "$status"
}

# check_staged_run <scratch> <start-ms>: the work of check_staged, with every
# intermediate file kept in <scratch>. The checks compare with HEAD's baseline.
# Auto-tighten starts from the baseline as the index holds it (the one this
# commit would carry), so a regenerated baseline is never reverted by the hook.
check_staged_run() {
  local scratch=$1 start=$2 root branch id stage sev fix atb rf budget base_name
  local known=0 partial=0 by_path=0 has_index=0 unstaged_base=0
  local new_n=0 touched_n=0 problems=0 n_commit ms end body
  local -a ids
  body="$scratch/body"
  budget=${GAUNTLET_COMMIT_BUDGET_MS:-5000}
  case "$budget" in
    ''|*[!0-9]*)
      printf 'gauntlet: GAUNTLET_COMMIT_BUDGET_MS must be a whole number of milliseconds, got [%s]\n' "$budget" >&2
      return 2
      ;;
  esac
  root=$(repo_root) || return 2
  # The first commit has no HEAD to compare with: it passes with a note.
  if ! git rev-parse -q --verify HEAD > /dev/null 2>&1; then
    printf 'note: no HEAD yet; the commit gate has nothing to compare and passes\n'
    return 0
  fi
  branch=$(current_branch) || return 2
  # A detached HEAD has no branch to waive on: no waiver applies, and nothing fails on it.
  if [ "$branch" = HEAD ]; then
    : > "$scratch/waived"
  else
    waived_paths > "$scratch/waived" || return 2
  fi

  # commit.ids: the stage=commit rules (stage defaults to commit). rules.tsv:
  # id, severity, 1 when the rule file exists at HEAD, fix.
  : > "$scratch/commit.ids"
  : > "$scratch/rules.tsv"
  rule_ids > "$scratch/ids" || return 2
  while IFS= read -r id; do
    rf="$root/.gauntlet/rules/$id.md"
    stage=$(rule_get "$rf" stage) || return 2
    [ -n "$stage" ] || stage=commit
    case "$stage" in
      commit) ;;
      push) continue ;;
      *)
        printf 'gauntlet: rule %s: bad stage [%s]\n' "$id" "$stage" >&2
        return 2
        ;;
    esac
    sev=$(rule_get "$rf" severity) || return 2
    # Fail closed: an unknown severity would otherwise match no comparison.
    if ! severity_rank "$sev" > /dev/null; then
      printf 'gauntlet: rule %s: bad severity [%s]\n' "$id" "$sev" >&2
      return 2
    fi
    fix=$(rule_get "$rf" fix) || return 2
    atb=0
    if git cat-file -e "HEAD:.gauntlet/rules/$id.md" 2>/dev/null; then atb=1; fi
    printf '%s\n' "$id" >> "$scratch/commit.ids"
    printf '%s\t%s\t%s\t%s\n' "$id" "$sev" "$atb" "$fix" >> "$scratch/rules.tsv"
  done < "$scratch/ids"
  n_commit=$(awk 'END { print NR }' "$scratch/commit.ids") || return 2

  # Measure the staged paths' working-tree content, commit-stage rules only.
  # measure with no rule ids would measure every rule, so no ids means empty files.
  if [ -s "$scratch/commit.ids" ]; then
    ids=()
    while IFS= read -r id; do ids[${#ids[@]}]=$id; done < "$scratch/commit.ids"
    measure staged "$scratch/now" "${ids[@]}" || return 2
  else
    mkdir -p "$scratch/now" || return 2
    : > "$scratch/now/measure.tsv" || return 2
    : > "$scratch/now/located.tsv" || return 2
    : > "$scratch/now/time.tsv" || return 2
  fi

  # staged.diff: HEAD against the index, renames followed. staged.paths: every
  # path it names, both sides of a rename and deletions included.
  git_nul_lines -c core.quotepath=off diff --cached -M -z --name-status > "$scratch/staged.diff" || return 2
  awk '
    BEGIN { need = 0 }
    need == 0 { need = ($0 ~ /^[RC]/) ? 2 : 1; next }
    { print; need-- }
  ' "$scratch/staged.diff" > "$scratch/staged.paths" || return 2

  # A whole-program detector reports every file: only the staged paths' rows are
  # kept, before any check or tighten reads them.
  filter_to_staged "$scratch" "$scratch/now/measure.tsv" || return 2
  filter_to_staged "$scratch" "$scratch/now/located.tsv" || return 2

  # Partial staging (decision 4): a staged path that also has unstaged changes.
  # The baseline is left out: this hook is the one that writes it.
  git_nul_lines -c core.quotepath=off diff --name-only --no-renames -z > "$scratch/unstaged" || return 2
  partial=$(GL_STAGED="$scratch/staged.paths" GL_BASELINE=.gauntlet/baseline.tsv awk '
    FILENAME == ENVIRON["GL_STAGED"] { if ($0 != ENVIRON["GL_BASELINE"]) staged[$0] = 1; next }
    $0 in staged { hit = 1 }
    END { print hit + 0 }
  ' "$scratch/staged.paths" "$scratch/unstaged") || return 2

  # `git commit <path>` runs the hook on a next-index-<pid> file: its add never
  # reaches the index the commit keeps, so auto-tighten cannot land (see ADR-0007).
  base_name=${GIT_INDEX_FILE:-}
  base_name=${base_name##*/}
  case "$base_name" in next-index-*) by_path=1 ;; esac

  # HEAD's baseline is the reference for the new, touched, shadow and track checks.
  : > "$scratch/base.tsv"
  if git cat-file -e "HEAD:.gauntlet/baseline.tsv" 2>/dev/null; then
    known=1
    at_base HEAD .gauntlet/baseline.tsv > "$scratch/base.tsv" || return 2
  fi
  # The index's baseline is what auto-tighten starts from.
  : > "$scratch/index.tsv"
  if git cat-file -e ":.gauntlet/baseline.tsv" 2>/dev/null; then
    has_index=1
    git show ":.gauntlet/baseline.tsv" > "$scratch/index.tsv" || return 2
  fi
  # Unstaged work in the baseline: tighten never overwrites it.
  if [ "$known" -eq 1 ] && [ "$has_index" -eq 1 ]; then
    if [ ! -f "$root/.gauntlet/baseline.tsv" ] || ! cmp -s "$root/.gauntlet/baseline.tsv" "$scratch/index.tsv"; then
      unstaged_base=1
    fi
  fi
  LC_ALL=C sort -t "$DETECT_TAB" -k3,3n "$scratch/now/located.tsv" > "$scratch/located.byline" || return 2

  # tight.tsv is the baseline this commit carries (ADR-0003): the index's rows,
  # minus the commit-stage rows of every staged path, plus the rows just measured.
  # Rows of push-stage rules, of unstaged paths and of rules no longer on disk
  # stay as the index has them.
  GL_IDS="$scratch/commit.ids" GL_STAGED="$scratch/staged.paths" awk -F "$DETECT_TAB" '
    FILENAME == ENVIRON["GL_IDS"] { commit[$0] = 1; next }
    FILENAME == ENVIRON["GL_STAGED"] { staged[$0] = 1; next }
    !(($1 in commit) && ($2 in staged))
  ' "$scratch/commit.ids" "$scratch/staged.paths" "$scratch/index.tsv" > "$scratch/kept.tsv" || return 2
  cat "$scratch/kept.tsv" "$scratch/now/measure.tsv" > "$scratch/tight.raw" || return 2
  LC_ALL=C sort "$scratch/tight.raw" > "$scratch/tight.tsv" || return 2

  : > "$body"
  if [ "$known" -eq 0 ]; then
    printf 'note: no baseline at HEAD; new, touched, shadow and track checks skipped\n' >> "$body"
  else
    new_rows block "$scratch" > "$scratch/new.rows" || return 2
    new_n=$(awk 'END { print NR }' "$scratch/new.rows") || return 2
    if [ -s "$scratch/new.rows" ]; then
      printf '[new]\n' >> "$body"
      violation_lines "$scratch/new.rows" >> "$body"
    fi
    cmp_touched "$scratch/staged.diff" "$scratch/base.tsv" "$scratch/now/measure.tsv" "$scratch/rules.tsv" \
      "$scratch/waived" > "$scratch/touched.rows" || return 2
    if [ -s "$scratch/touched.rows" ]; then
      printf '[touched]\n' >> "$body"
      awk -F '\t' '{ printf "  %s  %s → %s  (%s)\n", $1, $2, $3, $4 }' "$scratch/touched.rows" >> "$body"
    fi
    touched_n=$(touched_uncovered "$scratch/new.rows" "$scratch/touched.rows") || return 2
    new_rows shadow "$scratch" > "$scratch/shadow.rows" || return 2
    if [ -s "$scratch/shadow.rows" ]; then
      printf '[shadow] would have failed\n' >> "$body"
      violation_lines "$scratch/shadow.rows" >> "$body"
    fi
    global_rows track "$scratch" "$scratch/tight.tsv" > "$scratch/track.rows" || return 2
    if [ -s "$scratch/track.rows" ]; then
      printf '[track]\n' >> "$body"
      awk -F '\t' '{ printf "  %s  %s → %s (+%d); consider promoting\n", $1, $2, $3, $3 - $2 }' \
        "$scratch/track.rows" >> "$body"
    fi
  fi

  # R18: one problem per [new] line and one per [touched] line not explained by a
  # [new] line. Shadow and track count nothing.
  problems=$((new_n + touched_n))
  # Each reason that keeps auto-tighten from running is printed, pass or fail.
  if [ "$known" -eq 1 ]; then
    if [ "$by_path" -eq 1 ]; then
      printf 'note: partial commit by path; run gauntlet baseline before pushing\n' >> "$body"
    fi
    if [ "$partial" -eq 1 ]; then
      printf 'note: partially staged; run gauntlet baseline before pushing\n' >> "$body"
    fi
    if [ "$has_index" -eq 0 ]; then
      printf 'note: baseline.tsv is not in the index; nothing tightened\n' >> "$body"
    elif [ "$unstaged_base" -eq 1 ]; then
      printf 'note: baseline.tsv has unstaged changes; run gauntlet baseline before pushing\n' >> "$body"
    fi
    # Auto-tighten runs only on a pass (decision 5), and only when nothing above skipped it.
    if [ "$problems" -eq 0 ] && [ "$by_path" -eq 0 ] && [ "$partial" -eq 0 ] \
      && [ "$has_index" -eq 1 ] && [ "$unstaged_base" -eq 0 ]; then
      tighten_baseline "$root" "$scratch" >> "$body" || return 2
    fi
  fi

  end=$(now_ms)
  ms=$((end - start))
  if GL_MS=$ms GL_BUDGET=$budget awk 'BEGIN { exit !(ENVIRON["GL_MS"] + 0 > ENVIRON["GL_BUDGET"] + 0) }'; then
    printf '[slow] over the 5 s commit budget\n' >> "$body"
  fi
  printf '[time]\n' >> "$body"
  awk -F '\t' '{ printf "  %s  %s ms\n", $1, $2 }' "$scratch/now/time.tsv" >> "$body" || return 2

  printf 'gauntlet  commit · %s rules · %s.%s s\n' "$n_commit" "$((ms / 1000))" "$(((ms % 1000) / 100))"
  cat "$body"
  if [ "$problems" -eq 0 ]; then
    printf 'gauntlet: ok\n'
    return 0
  fi
  printf 'gauntlet: FAIL (%s problems)\n' "$problems"
  return 1
}

# filter_to_staged <scratch> <file>: keep the rows of <file> whose path (field 2)
# is a staged path, in place and in order. Both measured files have the path there.
filter_to_staged() {
  local scratch=$1 file=$2
  GL_STAGED="$scratch/staged.paths" awk -F "$DETECT_TAB" '
    FILENAME == ENVIRON["GL_STAGED"] { staged[$0] = 1; next }
    ($2 in staged) { print }
  ' "$scratch/staged.paths" "$file" > "$scratch/filter.tmp" || return 2
  cp "$scratch/filter.tmp" "$file" || return 2
}

# tighten_baseline <root> <scratch>: when tight.tsv differs from the index's
# baseline, write it to the working-tree .gauntlet/baseline.tsv and git add it, so
# it lands in the commit being made (ADR-0007: the add must run in pre-commit).
# The caller has checked that the working tree equals the index copy. Prints one
# line per commit-stage rule whose total changed, or one line when only rows
# moved. Prints nothing when nothing needed writing.
tighten_baseline() {
  local root=$1 scratch=$2
  if cmp -s "$scratch/tight.tsv" "$scratch/index.tsv"; then return 0; fi
  GL_IDS="$scratch/commit.ids" GL_OLD="$scratch/index.tsv" awk -F "$DETECT_TAB" '
    FILENAME == ENVIRON["GL_IDS"] { want[$0] = 1; next }
    FILENAME == ENVIRON["GL_OLD"] { old[$1] += $4; next }
    { new[$1] += $4 }
    END {
      for (r in want)
        if (old[r] + 0 != new[r] + 0) printf "%s\t%d\t%d\n", r, old[r] + 0, new[r] + 0
    }
  ' "$scratch/commit.ids" "$scratch/index.tsv" "$scratch/tight.tsv" > "$scratch/tighten.raw" || return 2
  LC_ALL=C sort "$scratch/tighten.raw" > "$scratch/tighten.tsv" || return 2
  cp "$scratch/tight.tsv" "$root/.gauntlet/baseline.tsv" || return 2
  (cd "$root" && git add .gauntlet/baseline.tsv) || return 2
  if [ -s "$scratch/tighten.tsv" ]; then
    awk -F '\t' '{ printf "  %s  %s → %s   baseline updated and staged into this commit\n", $1, $2, $3 }' \
      "$scratch/tighten.tsv" || return 2
  else
    printf '  baseline updated and staged into this commit\n'
  fi
}
