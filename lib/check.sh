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
  local known=0 n_rules ms end n body problems
  root=$(repo_root) || return 2
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
  problems="$scratch/problems"
  : > "$body"
  : > "$problems"
  if [ "$known" -eq 0 ]; then
    printf 'note: no baseline at base; new, global, shadow and track checks skipped\n' >> "$body"
  else
    new_rows block "$scratch" > "$scratch/new.rows" || return 2
    if [ -s "$scratch/new.rows" ]; then
      printf '[new]\n' >> "$body"
      violation_lines "$scratch/new.rows" >> "$body"
      cut -f1 "$scratch/new.rows" >> "$problems"
    fi
    global_rows block "$scratch" > "$scratch/global.rows" || return 2
    if [ -s "$scratch/global.rows" ]; then
      printf '[global]\n' >> "$body"
      awk -F '\t' '{ printf "  %s  %s → %s\n", $1, $2, $3 }' "$scratch/global.rows" >> "$body"
      cut -f1 "$scratch/global.rows" >> "$problems"
    fi
  fi

  # Exact: the committed baseline must be byte-equal to what the code measures.
  if ! cmp -s "$root/.gauntlet/baseline.tsv" "$scratch/now/measure.tsv"; then
    printf '[baseline]\n  baseline differs from the code; run gauntlet baseline and commit it\n' >> "$body"
    diff -u "$root/.gauntlet/baseline.tsv" "$scratch/now/measure.tsv" > "$scratch/diff" || true
    awk 'NR <= 20' "$scratch/diff" >> "$body"
    printf 'baseline\n' >> "$problems"
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

  LC_ALL=C sort -u "$problems" > "$scratch/problems.u" || return 2
  n=$(awk 'END { print NR }' "$scratch/problems.u") || return 2

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

# violation_lines <rows>: print each new_rows row as a violation line and its
# fix line. The message runs to the end of the row, so it may contain tabs.
violation_lines() {
  awk -F '\t' '{
    m = $0
    for (i = 0; i < 4; i++) sub(/^[^\t]*\t/, "", m)
    printf "  %s:%s  %s  %s\n      fix: %s\n", $2, $3, $1, m, $4
  }' "$1"
}
