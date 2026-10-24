# shellcheck shell=bash
# Core helpers shared by every gauntlet command. Sourced, never executed.
# Bash 3.2 compatible. Uses only bash, awk, git and coreutils.

# shellcheck disable=SC2034 # read by bin/gauntlet
GAUNTLET_VERSION=0.1.0-dev

# path_spell [<name>]: print text that somebody else wrote so that it cannot move the cursor,
# clear the screen, hide text with a carriage return or set the terminal title. Every byte below
# 0x20 and 0x7f is written \xNN, and so is each C1 control (U+0080 to U+009F) in its UTF-8 form,
# the two bytes C2 80 to C2 9F: xterm reads C2 9B as CSI. Everything else is printed as it is,
# non-ASCII included, a lone byte 0x80 to 0x9f too (it is the continuation byte of valid text:
# the euro sign is E2 82 AC). This is the one escape for printed text, applied where the text is
# printed and never to the rows gauntlet stores.
#   with an argument: a name. The tab is written \t, the newline \n, and the result is one line.
#   without one: filter standard input line by line; a line's own newline and its tabs, which
#   the diff of the baseline and tool messages print, stay.
# The bytes are read in the C locale, where a character is a byte. The two-byte C1 form is not
# found by an awk that decodes UTF-8 whatever the locale.
path_spell() {
  if [ "$#" -gt 0 ]; then
    GL_SPELL_NAME=$1 spell_awk name
  else
    spell_awk lines
  fi
}

# spell_awk <name|lines>: the awk program of path_spell.
spell_awk() {
  LC_ALL=C awk -v mode="$1" '
    function spell(s, name,   i, n, c, k, out) {
      n = length(s)
      out = ""
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c in code) {
          if (c == "\t" && name) out = out "\\t"
          else if (c == "\n" && name) out = out "\\n"
          else if (c == "\t") out = out c
          else out = out sprintf("\\x%02x", code[c])
        } else if (c == "\302" && i < n && (k = index(C1, substr(s, i + 1, 1))) > 0) {
          out = out sprintf("\\xc2\\x%02x", 127 + k)
          i++
        } else out = out c
      }
      return out
    }
    BEGIN {
      for (i = 1; i < 32; i++) code[sprintf("%c", i)] = i
      code[sprintf("%c", 127)] = 127
      C1 = "\200\201\202\203\204\205\206\207\210\211\212\213\214\215\216\217\220\221\222\223\224\225\226\227\230\231\232\233\234\235\236\237"
      # Tab and newline are no reason to look at a line closely: only the rest are.
      unsafe = "[\001-\010\013-\037\177]"
      if (mode == "name") { print spell(ENVIRON["GL_SPELL_NAME"], 1); exit }
    }
    $0 !~ unsafe && index($0, "\302") == 0 { print; next }
    { print spell($0, 0) }
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
