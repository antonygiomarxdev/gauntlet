# shellcheck shell=bash
# Detectors: run one rule's detector and turn its output into rule rows.
# Sourced, never executed. Bash 3.2 compatible; sed, awk, git and coreutils.
# Needs core.sh, rules.sh and paths.sh sourced first.

# GAUNTLET_LIB: the runner's lib directory, where the built-in formats live.
GAUNTLET_LIB=${GAUNTLET_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)}

# Control bytes: the sed delimiter, the unparsed-line marker, and the tab that
# BSD sed cannot write as \t.
DETECT_DELIM=$(printf '\001')
DETECT_UNPARSED=$(printf '\002')
DETECT_TAB=$(printf '\t')

# format_file <name>: print the path of the format <name>: the project's
# .gauntlet/formats/<name>.md first, then the built-in one. Returns 2 and says
# "unknown format" on stderr when neither exists.
format_file() {
  local root candidate
  root=$(repo_root) || return 2
  for candidate in "$root/.gauntlet/formats/$1.md" "$GAUNTLET_LIB/formats/$1.md"; do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  printf 'gauntlet: unknown format %s\n' "$1" >&2
  return 2
}

# load_format <name>: read the format file into FMT_MATCH, FMT_PATH, FMT_LINE,
# FMT_MESSAGE and FMT_IGNORE. Returns 2 for an unknown or malformed format.
load_format() {
  local file valid=1
  file=$(format_file "$1") || return 2
  FMT_MATCH=$(rule_get "$file" match) || return 2
  FMT_PATH=$(rule_get "$file" path) || return 2
  FMT_LINE=$(rule_get "$file" line) || return 2
  FMT_MESSAGE=$(rule_get "$file" message) || return 2
  FMT_IGNORE=$(rule_get "$file" ignore) || return 2
  [ -n "$FMT_MATCH" ] || valid=0
  case "$FMT_PATH" in ''|*[!0-9]*) valid=0 ;; esac
  case "$FMT_LINE" in ''|*[!0-9]*) valid=0 ;; esac
  case "$FMT_MESSAGE" in *[!0-9]*) valid=0 ;; esac
  if [ "$valid" -ne 1 ]; then
    printf 'gauntlet: format %s needs match and numeric path and line groups\n' "$1" >&2
    return 2
  fi
}

# shell_quote <text>: print text as one single-quoted shell word.
shell_quote() {
  local q="'\\''" s=$1
  s=${s//\'/"$q"}
  printf "'%s'" "$s"
}

# run_detector <rule-file> <files-list> <out-tsv>: run the rule's detector and
# write "rule<TAB>path<TAB>line<TAB>message" rows to out-tsv. Returns 0, or 2
# with a message on stderr for a missing tool, a broken detector or format.
run_detector() {
  local rule=$1 files=$2 out=$3
  local id engine detector paths exclude format cmd tool root raw s row rows bad
  local want status hint p quoted="" scoped=0
  id=${rule##*/}
  id=${id%.md}
  engine=$(rule_get "$rule" engine) || return 2
  detector=$(rule_get "$rule" detector) || return 2
  paths=$(rule_get "$rule" paths) || return 2
  exclude=$(rule_get "$rule" exclude) || return 2
  format=$(rule_get "$rule" format) || return 2
  if [ -z "$format" ]; then
    case "$engine" in
      ast-grep) format=github ;;
      *) format=path-line ;;
    esac
  fi
  load_format "$format" || return 2
  root=$(repo_root) || return 2

  case "$engine" in
    ast-grep) cmd="ast-grep scan --rule $(shell_quote "$detector") --format github {files}" ;;
    rg|linter|script) cmd=$detector ;;
    *)
      printf 'gauntlet: broken detector: %s: unknown engine %s\n' "$id" "$engine" >&2
      return 2
      ;;
  esac
  tool=${cmd%% *}

  case "$cmd" in
    *'{files}'*)
      if [ ! -s "$files" ]; then
        : > "$out" || return 2
        return 0
      fi
      while IFS= read -r p || [ -n "$p" ]; do
        quoted="$quoted $(shell_quote "$p")"
      done < "$files"
      cmd=${cmd//'{files}'/"$quoted"}
      scoped=1
      ;;
  esac

  raw=$(cd "$root" && bash -c "$cmd" 2>/dev/null)
  status=$?
  case "$status" in
    0|1) ;;
    127)
      hint=
      case "$tool" in
        rg|ast-grep) hint=". Install: brew install ripgrep ast-grep | apt install ripgrep; pipx install ast-grep-cli" ;;
      esac
      printf 'gauntlet: missing tool %s%s\n' "$tool" "$hint" >&2
      return 2
      ;;
    *)
      printf 'gauntlet: broken detector: %s: exit %s\n' "$id" "$status" >&2
      return 2
      ;;
  esac

  # One sed pass: drop empty and ignored lines, rewrite matches into rows, and
  # mark every other line as unparsed (printed with the marker, never dropped).
  s="/^\$/d"
  if [ -n "$FMT_IGNORE" ]; then
    s="$s
\\${DETECT_DELIM}${FMT_IGNORE}${DETECT_DELIM}d"
  fi
  row="\\$FMT_PATH$DETECT_TAB\\$FMT_LINE$DETECT_TAB"
  if [ -n "$FMT_MESSAGE" ]; then row="$row\\$FMT_MESSAGE"; fi
  s="$s
s${DETECT_DELIM}${FMT_MATCH}${DETECT_DELIM}${row}${DETECT_DELIM}
t emit
s/.*/${DETECT_UNPARSED}&/p
b
:emit
p"
  rows=$(printf '%s\n' "$raw" | sed -n -E "$s") || {
    printf 'gauntlet: format %s does not compile\n' "$format" >&2
    return 2
  }
  bad=$(printf '%s\n' "$rows" | awk -v m="$DETECT_UNPARSED" 'index($0, m) == 1 { print substr($0, 2); exit }')
  if [ -n "$bad" ]; then
    printf 'gauntlet: broken detector: %s: unparsed line: %s\n' "$id" "$bad" >&2
    return 2
  fi

  # Strip a leading ./ or the repo root from each path.
  rows=$(printf '%s\n' "$rows" | awk -F "$DETECT_TAB" -v root="$root/" '
    NF == 0 { next }
    {
      p = $1
      if (index(p, "./") == 1) p = substr(p, 3)
      if (index(p, root) == 1) p = substr(p, length(root) + 1)
      print p "\t" substr($0, length($1) + 2)
    }')

  # Keep rows for the input list; a whole-program detector is filtered by the
  # rule's paths and exclude instead.
  if [ "$scoped" -eq 1 ]; then
    want=$(cat "$files")
  else
    want=$(printf '%s\n' "$rows" | awk -F "$DETECT_TAB" 'NF { print $1 }' |
      LC_ALL=C sort -u | select_files "$paths" "$exclude")
  fi
  printf '%s\n' "$rows" | GL_WANT="$want" GL_RULE="$id" awk -F "$DETECT_TAB" '
    BEGIN {
      n = split(ENVIRON["GL_WANT"], w, "\n")
      for (i = 1; i <= n; i++) keep[w[i]] = 1
    }
    NF && ($1 in keep) { print ENVIRON["GL_RULE"] "\t" $0 }
  ' > "$out" || return 2
}
