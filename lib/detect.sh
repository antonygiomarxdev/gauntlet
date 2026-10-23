# shellcheck shell=bash
# Detectors: run one rule's detector and turn its output into rule rows.
# Sourced, never executed. Bash 3.2 compatible; sed, awk, git and coreutils.
# Needs core.sh, rules.sh and paths.sh sourced first. Safe under set -eu.

# GAUNTLET_LIB: the runner's lib directory, where the built-in formats live.
# Resolved outside a command substitution: BASH_SOURCE is unset inside one
# under set -u.
if [ -z "${GAUNTLET_LIB:-}" ]; then
  detect_src=${BASH_SOURCE[0]}
  GAUNTLET_LIB=$(cd "$(dirname "$detect_src")" && pwd -P)
fi

# Control bytes: the sed delimiter, the unparsed-line marker, and the tab that
# BSD sed cannot write as \t.
DETECT_DELIM=$(printf '\001')
DETECT_UNPARSED=$(printf '\002')
DETECT_TAB=$(printf '\t')

# Batch budget for the quoted {files} list, in characters. A character is at
# most 4 bytes, so 25000 characters keep each bash -c command under 100000
# bytes (the per-argument limit is 128 KiB).
DETECT_BATCH_CHARS=25000

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

# effective_format <engine> <format>: print the format a rule reads. An empty
# format field means the engine's default: github for ast-grep, path-line for
# every other engine.
effective_format() {
  if [ -n "$2" ]; then
    printf '%s\n' "$2"
  elif [ "$1" = ast-grep ]; then
    printf 'github\n'
  else
    printf 'path-line\n'
  fi
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

# quote_word <text>: set QUOTED to <text> as one single-quoted shell word.
# Sets a variable instead of printing, so batching forks nothing per path.
quote_word() {
  local q="'\\''" s=$1
  s=${s//\'/"$q"}
  QUOTED="'$s'"
}

# detect_fail <msg> <errf>: print "gauntlet: <msg>" and the first 5 lines of
# the detector's stderr, which the caller keeps in <errf>.
detect_fail() {
  printf 'gauntlet: %s\n' "$1" >&2
  head -n 5 "$2" 2>/dev/null | sed 's/^/gauntlet:   | /' >&2
}

# missing_tool_hint <tool>: print how to install an engine tool, with a leading ". "
# so it can follow the tool's name. Prints nothing for a tool with no hint.
missing_tool_hint() {
  case "$1" in
    rg|ast-grep) printf '%s\n' ". Install: brew install ripgrep ast-grep | apt install ripgrep; pipx install ast-grep-cli" ;;
  esac
}

# tool_present <tool> <root>: succeed when <tool> is on PATH, or when it is an
# executable path: absolute, or relative to the repo root <root>.
tool_present() {
  case "$1" in
    /*) [ -x "$1" ] ;;
    */*) [ -x "$2/$1" ] ;;
    *) command -v "$1" > /dev/null 2>&1 ;;
  esac
}

# detect_batch <root> <cmd> <id> <errf>: run one detector command in <root>,
# append its stdout to DETECT_RAW and its stderr to <errf>. Returns 2 after a
# message for a missing tool (127) or any exit code above 1.
detect_batch() {
  local out status tool=${2%% *} hint=
  out=$(cd "$1" && bash -c "$2" </dev/null 2>>"$4") && status=0 || status=$?
  case "$status" in
    0|1)
      DETECT_RAW="$DETECT_RAW$out
"
      ;;
    127)
      hint=$(missing_tool_hint "$tool")
      detect_fail "missing tool $tool$hint" "$4"
      return 2
      ;;
    *)
      detect_fail "broken detector: $3: exit $status" "$4"
      return 2
      ;;
  esac
}

# detect_scan <root> <cmd> <id> <errf> <files>: run <cmd> once, or, when it
# has {files}, once per batch of quoted paths from <files>. An empty list runs
# nothing.
detect_scan() {
  local root=$1 cmd=$2 id=$3 errf=$4 files=$5 batch="" blen=0 p full limit
  case "$cmd" in
    *'{files}'*) ;;
    *)
      detect_batch "$root" "$cmd" "$id" "$errf" || return 2
      return 0
      ;;
  esac
  # The command's own text counts against the budget too.
  limit=$((DETECT_BATCH_CHARS - ${#cmd}))
  while IFS= read -r p || [ -n "$p" ]; do
    quote_word "$p"
    if [ -n "$batch" ] && [ $((blen + ${#QUOTED})) -gt "$limit" ]; then
      # Assign before passing: inside an argument, ${var//pat/"rep"} keeps its
      # inner quotes on bash 4.2 and older (compat32 mode), breaking the batch.
      full=${cmd//'{files}'/"$batch"}
      detect_batch "$root" "$full" "$id" "$errf" || return 2
      batch=""
      blen=0
    fi
    batch="$batch $QUOTED"
    blen=$((blen + ${#QUOTED} + 1))
  done < "$files"
  if [ -n "$batch" ]; then
    full=${cmd//'{files}'/"$batch"}
    detect_batch "$root" "$full" "$id" "$errf" || return 2
  fi
  return 0
}

# parse_output <format-name> <raw-file> <out-file>: parse a detector's raw output
# with the named format and write "path<TAB>line<TAB>message" rows to out-file.
# Empty and ignored lines are dropped. Returns 2 with a message on stderr when
# a line matches neither the format's match nor its ignore, or when the format
# does not compile. run_detector and test-rules both parse through here.
parse_output() {
  local raw=$2 out=$3 s row bad
  load_format "$1" || return 2
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
  sed -n -E "$s" "$raw" > "$out" 2>/dev/null || {
    printf 'format %s does not compile\n' "$1" >&2
    return 2
  }
  bad=$(GL_MARK=$DETECT_UNPARSED awk 'index($0, ENVIRON["GL_MARK"]) == 1 { print substr($0, 2); exit }' "$out") || return 2
  if [ -n "$bad" ]; then
    printf 'unparsed line: %s\n' "$bad" >&2
    return 2
  fi
  return 0
}

# detect_rule <scratch> <rule-file> <files-list> <out-tsv>: the work of
# run_detector, with its intermediate files kept in <scratch>.
detect_rule() {
  local scratch=$1 rule=$2 files=$3 out=$4
  local id engine detector paths exclude format cmd root errf scoped want bad
  id=${rule##*/}
  id=${id%.md}
  engine=$(rule_get "$rule" engine) || return 2
  detector=$(rule_get "$rule" detector) || return 2
  paths=$(rule_get "$rule" paths) || return 2
  exclude=$(rule_get "$rule" exclude) || return 2
  format=$(rule_get "$rule" format) || return 2
  format=$(effective_format "$engine" "$format") || return 2
  load_format "$format" || return 2
  root=$(repo_root) || return 2

  case "$engine" in
    ast-grep)
      quote_word "$detector"
      cmd="ast-grep scan --rule $QUOTED --format github {files}"
      ;;
    rg|linter|script) cmd=$detector ;;
    *)
      printf 'gauntlet: broken detector: %s: unknown engine %s\n' "$id" "$engine" >&2
      return 2
      ;;
  esac
  case "$cmd" in
    *'{files}'*) scoped=1 ;;
    *) scoped=0 ;;
  esac

  errf="$scratch/err"
  : > "$errf" || return 2
  DETECT_RAW=
  detect_scan "$root" "$cmd" "$id" "$errf" "$files" || return 2
  printf '%s\n' "$DETECT_RAW" > "$scratch/raw" || return 2

  if ! parse_output "$format" "$scratch/raw" "$scratch/parsed" 2> "$scratch/perr"; then
    printf 'gauntlet: broken detector: %s: ' "$id" >&2
    cat "$scratch/perr" >&2
    return 2
  fi

  # Strip a leading ./ or the repo root from each path.
  GL_ROOT="$root/" awk -F "$DETECT_TAB" '
    NF == 0 { next }
    {
      p = $1
      if (index(p, "./") == 1) p = substr(p, 3)
      if (index(p, ENVIRON["GL_ROOT"]) == 1) p = substr(p, length(ENVIRON["GL_ROOT"]) + 1)
      print p "\t" substr($0, length($1) + 2)
    }
  ' "$scratch/parsed" > "$scratch/rows" || return 2

  # Keep rows for the input list; a whole-program detector is filtered by the
  # rule's paths and exclude instead. The keep-list goes to awk as a file: an
  # environment variable is capped at 128 KiB, and large repos exceed it.
  if [ "$scoped" -eq 1 ]; then
    want=$files
  else
    want="$scratch/want"
    awk -F "$DETECT_TAB" 'NF { print $1 }' "$scratch/rows" |
      LC_ALL=C sort -u | select_files "$paths" "$exclude" > "$want" || return 2
  fi
  bad=0
  GL_WANT_FILE="$want" GL_RULE="$id" awk -F "$DETECT_TAB" '
    BEGIN {
      while ((getline line < ENVIRON["GL_WANT_FILE"]) > 0) keep[line] = 1
    }
    NF && ($1 in keep) { print ENVIRON["GL_RULE"] "\t" $0 }
  ' "$scratch/rows" > "$out" || bad=$?
  return "$bad"
}

# run_detector <rule-file> <files-list> <out-tsv>: run the rule's detector and
# write "rule<TAB>path<TAB>line<TAB>message" rows to out-tsv. Returns 0, or 2
# with a message on stderr for a missing tool, a broken detector or format.
run_detector() {
  local scratch st=0
  scratch=$(mktemp -d) || return 2
  detect_rule "$scratch" "$@" || st=$?
  rm -rf "$scratch"
  return "$st"
}
