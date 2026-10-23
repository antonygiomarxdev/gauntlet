# shellcheck shell=bash
# Rule and format cases: each rule's bad and good fixtures under
# .gauntlet/rules/, and each output format's sample against its expected block.
# Sourced, never executed. Bash 3.2 compatible; awk, git and coreutils only.
# Needs core.sh, rules.sh, paths.sh and detect.sh sourced first.

# run_rule_tests <workdir>: test every rule's cases and every format's sample in
# the repo at <workdir>. Prints one "  <id>  <case>  <problem>" line per failure.
# Returns 0 when all pass, 1 when any fails, 2 when the setup is broken.
run_rule_tests() {
  local scratch rc=0
  scratch=$(mktemp -d) || return 2
  (cd "$1" || exit 2; cases_check "$scratch") || rc=$?
  rm -rf "$scratch"
  return "$rc"
}

# cases_check <scratch>: check every rule, then every format. Runs in the repo root.
cases_check() {
  local scratch=$1 id name rc st=0
  all_files > "$scratch/listing" || return 2
  rule_ids > "$scratch/ids" || return 2
  format_names > "$scratch/formats" || return 2
  while IFS= read -r id; do
    rc=0
    rule_cases "$id" "$scratch" || rc=$?
    case "$rc" in
      0) ;;
      1) st=1 ;;
      *) return 2 ;;
    esac
  done < "$scratch/ids"
  while IFS= read -r name; do
    rc=0
    format_cases "$name" "$scratch" || rc=$?
    case "$rc" in
      0) ;;
      1) st=1 ;;
      *) return 2 ;;
    esac
  done < "$scratch/formats"
  return "$st"
}

# case_scan <id> <listing> <files-out> <entries-out>: from the repo listing
# (one path per line), write the case files of rule <id> to files-out, and one
# "<kind><TAB><entry>" row per case to entries-out. A case is a direct child of
# .gauntlet/rules/ named <id>.bad* or <id>.good*; a directory case contributes
# every file under it.
case_scan() {
  : > "$3" || return 2
  : > "$4" || return 2
  GL_ID=$1 GL_FILES=$3 GL_ENTRIES=$4 awk '
    BEGIN {
      pre = ".gauntlet/rules/"
      id = ENVIRON["GL_ID"]
      files = ENVIRON["GL_FILES"]
      entries = ENVIRON["GL_ENTRIES"]
    }
    index($0, pre) != 1 { next }
    {
      rest = substr($0, length(pre) + 1)
      slash = index(rest, "/")
      top = slash ? substr(rest, 1, slash - 1) : rest
      if (index(top, id ".bad") == 1) kind = "bad"
      else if (index(top, id ".good") == 1) kind = "good"
      else next
      print $0 > files
      if (!((kind, top) in seen)) {
        seen[kind, top] = 1
        print kind "\t" top > entries
      }
    }
  ' "$2"
}

# case_verdict <id> <rows> <entries>: print a failure line for each bad case
# with no rows and each good case with rows. Rows are the detector's output.
case_verdict() {
  GL_ID=$1 GL_ENTRIES=$3 awk -F "$DETECT_TAB" '
    BEGIN {
      pre = ".gauntlet/rules/"
      id = ENVIRON["GL_ID"]
      while ((getline line < ENVIRON["GL_ENTRIES"]) > 0) {
        split(line, f, "\t")
        n++
        kind[n] = f[1]
        top[n] = f[2]
      }
    }
    index($2, pre) == 1 {
      rest = substr($2, length(pre) + 1)
      slash = index(rest, "/")
      t = slash ? substr(rest, 1, slash - 1) : rest
      hits[t]++
    }
    END {
      for (i = 1; i <= n; i++) {
        c = hits[top[i]] + 0
        if (kind[i] == "bad" && c == 0) print "  " id "  " top[i] "  bad case not flagged"
        if (kind[i] == "good" && c > 0) print "  " id "  " top[i] "  good case flagged: " c " rows"
      }
    }
  ' "$2"
}

# rule_cases <id> <scratch>: check one rule's cases. Returns 0 when they pass,
# 1 when one fails (its lines are printed), 2 on a broken setup.
rule_cases() {
  local id=$1 scratch=$2 st=0
  local files="$scratch/files" entries="$scratch/entries" copy="$scratch/rule/$1.md"
  mkdir -p "$scratch/rule" || return 2
  case_scan "$id" "$scratch/listing" "$files" "$entries" || return 2
  if [ ! -s "$files" ]; then
    printf '  %s  bad  no cases\n' "$id"
    return 1
  fi
  if ! awk -F "$DETECT_TAB" '$1 == "bad" { found = 1 } END { exit !found }' "$entries"; then
    printf '  %s  bad  no cases\n' "$id"
    st=1
  fi
  # The rule runs with its paths and exclude ignored, so every case is seen.
  awk '
    { sub(/\r$/, "") }
    /^---$/ { n++; print; next }
    n == 1 && /^paths:/ { print "paths: **"; next }
    n == 1 && /^exclude:/ { print "exclude:"; next }
    { print }
  ' ".gauntlet/rules/$id.md" > "$copy" || return 2
  run_detector "$copy" "$files" "$scratch/rows" || return 2
  case_verdict "$id" "$scratch/rows" "$entries" > "$scratch/problems" || return 2
  if [ -s "$scratch/problems" ]; then
    cat "$scratch/problems"
    st=1
  fi
  return "$st"
}

# format_names: print the name of every built-in and project format, once each,
# sorted. A project format shadows the built-in of the same name.
format_names() {
  local root f
  root=$(repo_root) || return 2
  for f in "$GAUNTLET_LIB"/formats/*.md "$root"/.gauntlet/formats/*.md; do
    [ -f "$f" ] || continue
    f=${f##*/}
    printf '%s\n' "${f%.md}"
  done | LC_ALL=C sort -u
}

# fence_block <file> <lang> <out>: write the body of the first ```<lang> block in
# file to out. Returns 0 when found, 1 when there is none, 2 on an error.
fence_block() {
  local st=0
  GL_LANG=$2 awk '
    { sub(/\r$/, "") }
    !inside && !done && $0 == ("```" ENVIRON["GL_LANG"]) { inside = 1; found = 1; next }
    inside && $0 == "```" { inside = 0; done = 1; next }
    inside { print }
    END { exit !found }
  ' "$1" > "$3" && st=0 || st=$?
  if [ "$st" -gt 1 ]; then return 2; fi
  return "$st"
}

# format_cases <name> <scratch>: check one format's sample against its expected
# block. Prints failure lines; returns 0, 1 or 2 as rule_cases does.
format_cases() {
  local name=$1 scratch=$2 file rc st=0 have_s=0 have_e=0 got want err
  file=$(format_file "$name") || return 2
  rc=0
  fence_block "$file" sample "$scratch/sample" || rc=$?
  case "$rc" in
    0) have_s=1 ;;
    1) printf '  %s  sample  no cases\n' "$name"; st=1 ;;
    *) return 2 ;;
  esac
  rc=0
  fence_block "$file" expected "$scratch/expected" || rc=$?
  case "$rc" in
    0) have_e=1 ;;
    1) printf '  %s  expected  no cases\n' "$name"; st=1 ;;
    *) return 2 ;;
  esac
  if [ "$have_s" -eq 1 ] && [ "$have_e" -eq 1 ]; then
    if ! parse_output "$name" "$scratch/sample" "$scratch/parsed" 2> "$scratch/perr"; then
      err=$(cat "$scratch/perr") || return 2
      printf '  %s  sample  does not parse: %s\n' "$name" "$err"
      st=1
    else
      got=$(cat "$scratch/parsed") || return 2
      want=$(cat "$scratch/expected") || return 2
      if [ "$got" != "$want" ]; then
        printf '  %s  expected  parsed sample differs from expected block\n' "$name"
        st=1
      fi
    fi
  fi
  return "$st"
}
