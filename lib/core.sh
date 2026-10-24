# shellcheck shell=bash
# Core helpers shared by every gauntlet command. Sourced, never executed.
# Bash 3.2 compatible. Uses only bash, awk, git and coreutils.

# shellcheck disable=SC2034 # read by bin/gauntlet
GAUNTLET_VERSION=0.1.0-dev

# path_spell [<name>]: print text that somebody else wrote so that it cannot move the cursor,
# clear the screen, hide text with a carriage return or set the terminal title. Every byte below
# 0x20 and 0x7f is written \xNN, and so is each C1 control (U+0080 to U+009F) in its UTF-8 form,
# the two bytes C2 80 to C2 9F: xterm reads C2 9B as CSI. A terminal in 8-bit mode reads the
# single byte 0x9B as CSI too, so a byte 0x80 to 0x9f that no valid UTF-8 character uses is
# written \xNN as well; the continuation byte of a valid character is text (the euro sign is
# E2 82 AC) and stays. Everything else is printed as it is, non-ASCII included. This is the one
# escape for printed text, applied where the text is printed and never to the rows gauntlet stores.
#   with an argument: a name. The tab is written \t, the newline \n, and the result is one line.
#   without one: filter standard input line by line; a line's own newline and its tabs, which
#   the diff of the baseline and tool messages print, stay.
# A name that starts with "::" (after blanks) gets its first colon written \x3a: GitHub's runner
# trims the blanks of an output line and runs one that starts with "::" as a workflow command
# (::error::, ::stop-commands::), and a tracked file can be named that. Standard input is left
# as it is in this form, since it is mostly the output of tools; report_spell is the form for
# a report that is made of names.
# The bytes are read in the C locale, where a character is a byte. The two-byte C1 form is not
# found by an awk that decodes UTF-8 whatever the locale.
path_spell() {
  if [ "$#" -gt 0 ]; then
    GL_SPELL_NAME=$1 spell_awk name
  else
    spell_awk lines
  fi
}

# sh_quote <text>: <text> as one word for a shell, in single quotes, an embedded single quote
# written '\'' (close, escaped quote, open). For a command that gauntlet asks the user to paste
# (R60): a ref, a branch, a rule id, a path or text of the config is whatever the repository
# chose, and `$(...)`, a quote, a space or a separator in it would be run or split when pasted.
# The result is then printed through path_spell like any other text, which only rewrites control
# bytes. Display-only text (a name in a sentence) keeps path_spell alone.
sh_quote() {
  local rest=$1 out=''
  while :; do
    case $rest in
      *"'"*)
        out=$out${rest%%"'"*}"'\\''"
        rest=${rest#*"'"}
        ;;
      *) break ;;
    esac
  done
  printf "'%s'\n" "$out$rest"
}

# gauntlet_junk <path under .gauntlet>: succeed for a name the run never reads and an OS, an editor
# or gauntlet itself leaves there: STATUS.md and the install lock, a Finder's .DS_Store, a swap file
# (*.swp), a mergetool backup (*.orig). doctor leaves such an ignored file out of its ignored-files
# check and check --ci leaves such an untracked file out of its refusal (R65); one list, so the two
# cannot drift.
gauntlet_junk() {
  case "$1" in
    STATUS.md|.install.lock|.install.lock/*|.DS_Store|*/.DS_Store|*.swp|*.orig) return 0 ;;
  esac
  return 1
}

# report_spell: path_spell for the lines of a report that gauntlet builds from names, rule ids
# and tool output: standard input line by line, and a line that starts with "::" after blanks
# has its first colon written \x3a, so no line of a report is a workflow command whatever a
# tracked file or a rule is called.
report_spell() {
  spell_awk report
}

# spell_awk <name|lines|report>: the awk program of path_spell and report_spell. A line with no
# byte that needs a look is printed as it is. Any other is walked once: the text between two
# escapes is written in one piece and nothing is accumulated, so the work is linear in the
# length of the line. Some awks (busybox) copy the whole string on every substr call, so a long
# line is walked in pieces of CH bytes, none of which ends inside a UTF-8 character: the copies
# are of one piece.
spell_awk() {
  LC_ALL=C awk -v mode="$1" '
    function spell(s, name,   n, p, e, e0, k, b, at) {
      n = length(s)
      at = (lead && match(s, LEAD)) ? RLENGTH - 1 : 0
      for (p = 1; p <= n; p = e) {
        e = p + CH
        if (e <= n) {
          # Back to the lead byte when the piece would end inside a character: a character has
          # at most three continuation bytes, and a longer run of them has no lead byte to keep.
          e0 = e
          for (k = 0; k < 3; k++) {
            b = ord[substr(s, e, 1)]
            if (b < 128 || b > 191) break
            e--
          }
          b = ord[substr(s, e, 1)]
          if (b >= 128 && b <= 191) e = e0
        }
        walk(substr(s, p, e - p), name, at - p + 1)
      }
    }
    # at: where the first colon of a leading "::" sits in s, a number outside 1 to length(s) for none.
    function walk(s, name, at,   n, i, run, v, need, lo, hi, j, b, w) {
      n = length(s); i = 1; run = 1
      while (i <= n) {
        if (i == at) {
          if (i > run) printf "%s", substr(s, run, i - run)
          printf "%s", "\\x3a"
          i++; run = i
          continue
        }
        v = ord[substr(s, i, 1)]
        if (v >= 32 && v < 127) { i++; continue }
        w = ""; need = 0
        if (v < 128) {
          if (v == 9 && !name) { i++; continue }
          w = (v == 9) ? "\\t" : (v == 10) ? "\\n" : sprintf("\\x%02x", v)
        } else {
          # A lead byte and the continuation bytes it needs are one valid character.
          if (v >= 194 && v <= 244) {
            need = (v < 224) ? 1 : (v < 240) ? 2 : 3
            lo = 128; hi = 191
            if (v == 224) lo = 160; else if (v == 237) hi = 159; else if (v == 240) lo = 144; else if (v == 244) hi = 143
            for (j = 1; j <= need; j++) {
              b = ord[substr(s, i + j, 1)] + 0
              if (b < lo || b > hi) { need = 0; break }
              lo = 128; hi = 191
            }
          }
          b = ord[substr(s, i + 1, 1)] + 0
          if (need > 0 && v == 194 && b < 160) { w = sprintf("\\xc2\\x%02x", b); need = 1 }
          else if (need > 0) { i += need + 1; continue }
          else if (v < 160) w = sprintf("\\x%02x", v)
          else { i++; continue }
        }
        if (i > run) printf "%s", substr(s, run, i - run)
        printf "%s", w
        i += need + 1; run = i
      }
      if (n >= run) printf "%s", substr(s, run, n - run + 1)
    }
    BEGIN {
      for (i = 1; i < 256; i++) ord[sprintf("%c", i)] = i
      CH = 1024
      # Tab and newline are no reason to look at a line closely: only the rest are.
      unsafe = "[\001-\010\013-\037\177\200-\237]"
      # What the runner trims before it looks for "::": the blanks and the other white space
      # of Unicode (NBSP, U+1680, U+2000 to U+200A, U+2028, U+2029, U+202F, U+205F, U+3000).
      LEAD = "^([ \t]|\302\240|\341\232\200|\342\200[\200-\212\250\251\257]|\342\201\237|\343\200\200)*::"
      lead = (mode != "lines")
      if (mode == "name") { spell(ENVIRON["GL_SPELL_NAME"], 1); printf "\n"; exit }
    }
    $0 !~ unsafe && !(lead && $0 ~ LEAD) { print; next }
    { spell($0, 0); printf "\n" }
  '
}

# die <msg> [code=2]: report on stderr and exit. The message may hold a name or a value somebody
# else wrote, so it is printed through path_spell.
die() {
  printf 'gauntlet: %s\n' "$(path_spell "$1")" >&2
  exit "${2:-2}"
}

# tmp_new [-d]: create a temp file, or a directory with -d, and print its path. Under
# the run root GAUNTLET_TMP when bin/gauntlet made one (its trap removes the root on
# every exit and on INT, TERM and HUP, R33); under TMPDIR when a library is used alone.
tmp_new() {
  mktemp ${1+"$1"} "${GAUNTLET_TMP:-${TMPDIR:-/tmp}}/gauntlet.XXXXXX"
}

# gauntlet_signal_traps: HUP, INT and TERM end the run with the status a shell reports for a
# signal (128 + the number), and the EXIT trap, gauntlet_cleanup, runs on the way out.
# bin/gauntlet sets them for the run; install_lock sets them back after it has held them.
gauntlet_signal_traps() {
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

# gauntlet_cleanup: remove what the run made outside its own scratch and then the run
# root, GAUNTLET_TMP. bin/gauntlet runs it from its EXIT trap. It removes the root it
# was given, the one partial file registered and the install lock this run took, nothing
# else. GAUNTLET_LOCK names a lock only once this process made it (install_lock): a run
# that waited, or gave up, never removes the lock of the run it waited for.
gauntlet_cleanup() {
  if [ -n "${GAUNTLET_PARTIAL:-}" ]; then rm -f "$GAUNTLET_PARTIAL"; fi
  if [ -n "${GAUNTLET_LOCK:-}" ]; then rmdir "$GAUNTLET_LOCK" 2> /dev/null || true; fi
  if [ -n "${GAUNTLET_TMP:-}" ]; then rm -rf "$GAUNTLET_TMP"; fi
}

# partial_begin <path> / partial_end: name the one file a command writes next to its
# destination before it renames it into place, so gauntlet_cleanup removes it when a
# signal ends the run in between.
partial_begin() {
  GAUNTLET_PARTIAL=$1
}

partial_end() {
  GAUNTLET_PARTIAL=
}

# plural <n> <singular> <plural>: print "<n> <word>", with the singular word for 1.
plural() {
  if [ "$1" = 1 ]; then printf '%s %s\n' "$1" "$2"; else printf '%s %s\n' "$1" "$3"; fi
}

# repo_root: print the absolute path of the top-level working tree. When git fails, only "not a
# git repository" means we are outside one. Any other failure is git's own (a core.hooksPath it
# cannot expand, a bare repository, a repository owned by someone else) and is named by its first
# error line. Git's messages are translated, so the second look is taken in the C locale.
repo_root() {
  local err
  git rev-parse --show-toplevel 2> /dev/null && return 0
  err=$(LC_ALL=C git rev-parse --show-toplevel 2>&1 > /dev/null) || true
  case "$err" in
    *'not a git repository'*) die "not inside a git repository" ;;
    '') die "cannot find the repository root: git failed" ;;
    *) die "cannot find the repository root: ${err%%$'\n'*}" ;;
  esac
}

# config_value <file> <key> [default]: print the last value set for key in the config
# <file> (key=value lines, # comments skipped), or the default, also when the file is
# missing. A CRLF file reads like an LF one: the carriage return ending a line is not part
# of the value. The one reader of a single key: config_get reads the working tree's file
# with it, and the loosening check reads the base's and HEAD's copies with it, so the
# gate judges the values the runner reads.
config_value() {
  local value
  if [ -f "$1" ] && value=$(awk -v k="$2" '
    { sub(/\r$/, "") }
    /^[[:space:]]*#/ { next }
    {
      eq = index($0, "=")
      if (eq == 0) { next }
      key = substr($0, 1, eq - 1)
      gsub(/^[ \t]+|[ \t]+$/, "", key)
      if (key != k) { next }
      val = substr($0, eq + 1)
      gsub(/^[ \t]+|[ \t]+$/, "", val)
      last = val
      found = 1
    }
    END { if (!found) exit 1; print last }
  ' "$1"); then
    printf '%s\n' "$value"
  else
    printf '%s\n' "${3-}"
  fi
}

# config_get <key> [default]: print the last value set for key in .gauntlet/config of the
# working tree, or the default (see config_value).
config_get() {
  local root
  root=$(repo_root) || exit 2
  config_value "$root/.gauntlet/config" "$1" "${2-}"
}

# now_ms: print the current time in milliseconds. Falls back to seconds x 1000
# where date does not support %N (macOS prints a literal N).
now_ms() {
  local t
  t=$(date +%s%N 2>/dev/null) || t=""
  case "$t" in
    ""|*N*) printf '%s000\n' "$(date +%s)" ;;
    *) printf '%s\n' "$((t / 1000000))" ;;
  esac
}
