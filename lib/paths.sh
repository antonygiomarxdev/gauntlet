# shellcheck shell=bash
# Path selection: which files a rule sees. Sourced, never executed.
# Bash 3.2 compatible; awk, git and coreutils only.

# select_files <paths> <exclude>: read paths on stdin, print those matching any
# glob in <paths> (space-separated; empty means **) and no glob in <exclude>.
# Patterns travel in the environment so awk does not expand backslashes.
select_files() {
  local paths=$1 exclude=$2
  [ -n "$paths" ] || paths='**'
  GL_PATHS=$paths GL_EXCLUDE=$exclude awk '
    # glob2re: one left-to-right scan, so escaping never touches the
    # brackets this function produces.
    function glob2re(g,   out, i, n, c) {
      out = ""
      n = length(g)
      for (i = 1; i <= n; i++) {
        c = substr(g, i, 1)
        if (c == "*" && substr(g, i, 3) == "**/") { out = out "(.*/)?"; i += 2 }
        else if (c == "*" && substr(g, i, 2) == "**") { out = out ".*"; i += 1 }
        else if (c == "*") out = out "[^/]*"
        else if (c == "?") out = out "[^/]"
        else if (index(".+()[]{}^$|\\", c)) out = out "\\" c
        else out = out c
      }
      return "^" out "$"
    }
    BEGIN {
      np = split(ENVIRON["GL_PATHS"], inc, " ")
      # A blank paths value must not select nothing: fall back to **.
      if (np == 0) { np = 1; inc[1] = "**" }
      ne = split(ENVIRON["GL_EXCLUDE"], exc, " ")
      for (i = 1; i <= np; i++) inc_re[i] = glob2re(inc[i])
      for (j = 1; j <= ne; j++) exc_re[j] = glob2re(exc[j])
    }
    {
      hit = 0
      for (i = 1; i <= np; i++) if ($0 ~ inc_re[i]) { hit = 1; break }
      if (!hit) next
      for (j = 1; j <= ne; j++) if ($0 ~ exc_re[j]) next
      print
    }
  '
}

# all_files: print every tracked or untracked-but-not-ignored file that exists
# in the working tree, once each. Used by test-rules case discovery; the
# measurement reads tracked_files instead.
all_files() {
  local list
  list=$(git_nul_lines -c core.quotepath=off ls-files -t -c -d -o --exclude-standard -z) || return 2
  printf '%s\n' "$list" | files_from_listing
}

# tracked_files: print every file in the index that exists in the working tree,
# once each. Untracked files are left out, so a local measurement equals what
# CI sees (decision 2, R19).
tracked_files() {
  local list
  list=$(git_nul_lines -c core.quotepath=off ls-files -t -c -d -z) || return 2
  printf '%s\n' "$list" | files_from_listing
}

# git_nul_lines <git-args...>: run git, which must be given -z, and print its
# NUL-separated output one name per line. Names come out raw: git C-quotes
# names with `"`, `\` or tabs unless -z is given, and such names would never
# match a path the working tree reports. The output goes to a temp file first,
# because command substitution drops NUL bytes and a pipe would hide git's status.
# Every listing of paths passes through here, so this is the one place that refuses
# a path with a tab or a newline (R31): the baseline and the fingerprints are tab
# and line separated files, and such a name would corrupt them.
git_nul_lines() {
  local tmp rc=0 tagged=0 arg
  # ls-files -t puts "<tag> " in front of each name; the message leaves it out.
  for arg in "$@"; do
    if [ "$arg" = -t ]; then tagged=1; fi
  done
  tmp=$(mktemp) || return 2
  git "$@" > "$tmp" || rc=2
  if [ "$rc" -eq 0 ]; then odd_paths_refuse "$tmp" "$tagged" || rc=2; fi
  if [ "$rc" -eq 0 ]; then tr '\0' '\n' < "$tmp" || rc=2; fi
  rm -f "$tmp"
  return "$rc"
}

# odd_paths_refuse <nul-file> <tagged>: return 0 when no name in the NUL-separated listing holds
# a tab or a newline. Otherwise print, for the first five such names, "gauntlet: path
# with a tab or newline: <name>; rename the file" with the tab written \t and the
# newline \n, a line for the rest, and return 2. git -z puts neither byte anywhere but
# in a name, so counting them in the whole listing is the test; the names are only
# worked out when there is one. <tagged> is 1 when each name has a two-character tag
# in front (ls-files -t).
odd_paths_refuse() {
  local odd
  odd=$(tr -cd '\t\n' < "$1" | wc -c) || return 2
  if [ "$((odd + 0))" -eq 0 ]; then return 0; fi
  # A newline in a name would split it, so it becomes \002 for the awk, which spells it out.
  tr '\n' '\002' < "$1" | tr '\0' '\n' | LC_ALL=C awk -v tagged="$2" '
    BEGIN { mark = sprintf("%c", 2) }
    index($0, mark) || index($0, "\t") {
      n++
      if (n > 5) next
      out = ""
      for (i = (tagged == 1 ? 3 : 1); i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c == "\t") out = out "\\t"
        else if (c == mark) out = out "\\n"
        else out = out c
      }
      print "gauntlet: path with a tab or newline: " out "; rename the file"
    }
    END { if (n > 5) print "gauntlet: and " n - 5 " more; rename the files" }
  ' >&2
  return 2
}

# files_from_listing: read `git ls-files -t` output on stdin. One tag marks each
# line: "R name" marks a tracked file deleted from disk (it also appears as
# tracked), any other tag is a live path. An unmerged path appears once per
# stage, so names are de-duplicated. No file is opened.
files_from_listing() {
  awk '
    $0 == "" { next }
    {
      name = substr($0, 3)
      if (substr($0, 1, 1) == "R") gone[name] = 1
      else order[++n] = name
    }
    END {
      for (i = 1; i <= n; i++) {
        name = order[i]
        if (name in gone || name in seen) continue
        seen[name] = 1
        print name
      }
    }
  '
}

# staged_files: print staged paths that are added, copied, modified or renamed.
staged_files() {
  git_nul_lines -c core.quotepath=off diff --cached --name-only --diff-filter=ACMR -z
}
