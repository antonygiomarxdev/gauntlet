# shellcheck shell=bash
# Rule files: .gauntlet/rules/<id>.md with a frontmatter block of key: value
# lines. Sourced, never executed. Bash 3.2 compatible; awk and coreutils only.

# rule_get <file> <key>: print the value of key in the frontmatter (the lines
# between the first two --- lines). A trailing "  # comment" is stripped for
# the enum-like keys only, because detector strings may contain " #".
rule_get() {
  local strip=0
  case "$2" in
    severity|stage|engine|since|format) strip=1 ;;
  esac
  # Print only after the closing fence is seen; an unclosed block exits 3.
  awk -v want="$2" -v strip="$strip" '
    { sub(/\r$/, "") }
    /^---$/ { n++; if (n == 2) exit; next }
    n == 1 && !found {
      colon = index($0, ":")
      if (colon == 0 || substr($0, 1, colon - 1) != want) next
      val = substr($0, colon + 1)
      sub(/^[ \t]+/, "", val)
      if (strip == 1) sub(/[ \t]+#.*$/, "", val)
      sub(/[ \t]+$/, "", val)
      found = 1
    }
    END {
      if (n < 2) exit 3
      if (found) print val
    }
  ' "$1"
}

# rule_ids: print the stems of .gauntlet/rules/*.md, sorted.
rule_ids() {
  local root f
  root=$(repo_root) || exit 2
  for f in "$root"/.gauntlet/rules/*.md; do
    [ -f "$f" ] || continue
    f=${f##*/}
    printf '%s\n' "${f%.md}"
  done | LC_ALL=C sort
}

# rule_validate <file>: print "<file>: <problem>" for each error and return 1
# when there is any.
rule_validate() {
  local file=$1 bad=0 id severity stage engine detector fix source since stem root
  problem() {
    printf '%s: %s\n' "$file" "$1"
    bad=1
  }
  if [ ! -f "$file" ]; then
    problem "cannot read rule file"
    return 1
  fi
  if ! rule_get "$file" id >/dev/null; then
    problem "frontmatter must be closed by a second ---"
    return 1
  fi
  stem=${file##*/}
  stem=${stem%.md}
  id=$(rule_get "$file" id)
  severity=$(rule_get "$file" severity)
  stage=$(rule_get "$file" stage)
  engine=$(rule_get "$file" engine)
  detector=$(rule_get "$file" detector)
  fix=$(rule_get "$file" fix)
  source=$(rule_get "$file" source)
  since=$(rule_get "$file" since)

  [ "$id" = "$stem" ] || problem "id [$id] must equal the file stem [$stem]"
  case "$severity" in
    block|shadow|track) ;;
    *) problem "severity must be block, shadow or track, got [$severity]" ;;
  esac
  [ -n "$stage" ] || stage=commit
  case "$stage" in
    commit|push) ;;
    *) problem "stage must be commit or push, got [$stage]" ;;
  esac
  case "$engine" in
    linter|ast-grep|rg) ;;
    script)
      root=$(repo_root) || exit 2
      if ! awk -F'\t' -v id="$stem" '$1 == "script" && $2 == id { found = 1 } END { exit !found }' \
        "$root/.gauntlet/exceptions.tsv" 2>/dev/null; then
        problem "engine=script needs a script row for [$stem] in .gauntlet/exceptions.tsv"
      fi
      ;;
    *) problem "engine must be linter, ast-grep, rg or script, got [$engine]" ;;
  esac
  [ -n "$detector" ] || problem "detector must not be empty"
  [ -n "$fix" ] || problem "fix must not be empty"
  [ -n "$source" ] || problem "source must not be empty"
  case "$since" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) problem "since must be YYYY-MM-DD, got [$since]" ;;
  esac

  [ "$bad" -eq 0 ]
}

# severity_rank <sev>: print block=3, shadow=2, track=1; return 1 otherwise.
severity_rank() {
  case "$1" in
    block) printf '3\n' ;;
    shadow) printf '2\n' ;;
    track) printf '1\n' ;;
    *) return 1 ;;
  esac
}
