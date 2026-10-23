# shellcheck shell=bash
# The CI gate: check --ci compares the branch with its merge-base. Sourced,
# never executed. Bash 3.2 compatible; awk, sort, cmp, diff and git only.
# Needs core.sh, rules.sh, measure.sh and base.sh sourced first.

# is_waived <rule> <path>: true when a waiver covers the violation. Waivers
# arrive in a later task; until then nothing is waived.
is_waived() {
  return 1
}

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
  root=$(repo_root) || return 2
  mode=$(touched_mode) || return 2
  base=$(resolve_base "$base_ref") || return 2
  sha=$(merge_base "$base") || return 2
  measure all "$scratch/now" || return 2
  rule_ids > "$scratch/ids" || return 2
  n_rules=$(awk 'END { print NR }' "$scratch/ids") || return 2

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
    cmp_touched "$sha" "$scratch/base.tsv" "$scratch/now/measure.tsv" "$scratch/rules.tsv" \
      > "$scratch/touched.rows" || return 2
    if [ -s "$scratch/touched.rows" ]; then
      printf '[touched]\n' >> "$body"
      awk -F '\t' '{ printf "  %s  %s → %s  (%s)\n", $1, $2, $3, $4 }' "$scratch/touched.rows" >> "$body"
    fi
    # R20: a file with a [new] line is already explained by it, so it is not
    # counted again here; [touched] still prints it.
    touched_n=$(GL_NEW="$scratch/new.rows" awk -F '\t' '
      FILENAME == ENVIRON["GL_NEW"] { covered[$2] = 1; next }
      !($1 in covered) { n++ }
      END { print n + 0 }
    ' "$scratch/new.rows" "$scratch/touched.rows") || return 2
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
  awk -F '\t' '{ printf "  %s  %s ms\n", $1, $2 }' "$scratch/now/time.tsv" >> "$body"

  # R18: one problem per [new] line, one per [global] rule whose rise its [new]
  # lines do not account for, one per [touched] line, one for [baseline].
  # Shadow and track count nothing.
  n=$((new_n + global_n + touched_n + baseline_n))

  end=$(now_ms)
  ms=$((end - start))
  printf 'gauntlet  ci · %s rules · %s.%s s\n' "$n_rules" "$((ms / 1000))" "$(((ms % 1000) / 100))"
  cat "$body"
  if [ "$n" -eq 0 ]; then
    printf 'gauntlet: ok\n'
    return 0
  fi
  printf 'gauntlet: FAIL (%s problems)\n' "$n"
  return 1
}

# new_rows <severity> <scratch>: print one row per new occurrence of a rule of
# that severity that exists at base: rule, path, line, fix, message. An
# occurrence is new when its fingerprint count rose; the last occurrences in
# line order are the new ones. Waived rows are dropped.
new_rows() {
  local sev=$1 scratch=$2 row rule rest path
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
  : > "$scratch/new.kept"
  while IFS= read -r row; do
    rule=${row%%"$DETECT_TAB"*}
    rest=${row#*"$DETECT_TAB"}
    path=${rest%%"$DETECT_TAB"*}
    if ! is_waived "$rule" "$path"; then
      printf '%s\n' "$row" >> "$scratch/new.kept"
    fi
  done < "$scratch/new.sorted"
  cat "$scratch/new.kept"
}

# global_rows <severity> <scratch>: print rule, base total, current total for
# each rule of that severity that exists at base whose total rose.
global_rows() {
  local sev=$1 scratch=$2
  GL_SEV=$sev GL_RULES="$scratch/rules.tsv" GL_BASE="$scratch/base.tsv" \
    GL_NOW="$scratch/now/measure.tsv" awk -F '\t' '
    FILENAME == ENVIRON["GL_RULES"] { sev[$1] = $2; atb[$1] = $3; next }
    FILENAME == ENVIRON["GL_BASE"] { bt[$1] += $4; next }
    FILENAME == ENVIRON["GL_NOW"] { nt[$1] += $4; next }
    END {
      for (r in sev)
        if (sev[r] == ENVIRON["GL_SEV"] && atb[r] == "1" && nt[r] + 0 > bt[r] + 0)
          printf "%s\t%s\t%s\n", r, bt[r] + 0, nt[r] + 0
    }
  ' "$scratch/rules.tsv" "$scratch/base.tsv" "$scratch/now/measure.tsv" > "$scratch/global.raw" || return 2
  LC_ALL=C sort "$scratch/global.raw"
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

# cmp_touched <merge-base> <base.tsv> <measure.tsv> <rules.tsv>: the touched
# gate (opt-in via config touched=on). Each file the branch changes must come
# out with less block debt than it had at the merge-base. Prints one tab row
# per file that breaks that rule (path, base, now, reason) and returns 0;
# prints nothing when the gate is off. Debt counts only block rules that exist
# at base, and waived rows are skipped.
cmp_touched() {
  local mb=$1 base=$2 now=$3 rules=$4 mode scratch status=0
  mode=$(touched_mode) || return 2
  [ "$mode" = on ] || return 0
  scratch=$(mktemp -d) || return 2
  cmp_touched_in "$mb" "$base" "$now" "$rules" "$scratch" || status=$?
  rm -rf "$scratch"
  return "$status"
}

# cmp_touched_in <merge-base> <base.tsv> <measure.tsv> <rules.tsv> <scratch>:
# the work of cmp_touched, with intermediate files kept in <scratch>.
cmp_touched_in() {
  local mb=$1 base=$2 now=$3 rules=$4 scratch=$5
  # R15: `.gauntlet/` is never judged. R100 (pure rename) and D are skipped.
  # Both are early-outs: judged anyway, their verdict would be the same.
  # -z output is one token per line: a status, then one path (two for R or C).
  git_nul_lines -c core.quotepath=off diff -M -z --name-status "$mb" HEAD > "$scratch/diff" || return 2
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
  ' "$scratch/diff" > "$scratch/changes" || return 2

  # sums: fingerprint rows of block rules that exist at base, for the changed
  # paths only. B rows are the base's debt at the old paths, N rows the current
  # debt at the new paths. The base is never re-measured.
  GL_CH="$scratch/changes" GL_RULES="$rules" GL_BASE="$base" GL_NOW="$now" awk -F '\t' '
    FILENAME == ENVIRON["GL_CH"] { old[$2] = 1; nw[$3] = 1; next }
    FILENAME == ENVIRON["GL_RULES"] { if ($2 == "block" && $3 == "1") blk[$1] = 1; next }
    FILENAME == ENVIRON["GL_BASE"] { if (($2 in old) && ($1 in blk)) print "B\t" $1 "\t" $2 "\t" $4; next }
    FILENAME == ENVIRON["GL_NOW"] { if (($2 in nw) && ($1 in blk)) print "N\t" $1 "\t" $2 "\t" $4 }
  ' "$scratch/changes" "$rules" "$base" "$now" > "$scratch/sums" || return 2

  # Waivers drop a row from the totals (is_waived is a stub until waivers land).
  : > "$scratch/kept"
  local row rest rule path
  while IFS= read -r row; do
    rest=${row#*"$DETECT_TAB"}
    rule=${rest%%"$DETECT_TAB"*}
    rest=${rest#*"$DETECT_TAB"}
    path=${rest%%"$DETECT_TAB"*}
    if ! is_waived "$rule" "$path"; then
      printf '%s\n' "$row" >> "$scratch/kept"
    fi
  done < "$scratch/sums"

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
