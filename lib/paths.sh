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
git_nul_lines() {
  local tmp rc=0
  tmp=$(mktemp) || return 2
  git "$@" > "$tmp" || rc=2
  if [ "$rc" -eq 0 ]; then tr '\0' '\n' < "$tmp" || rc=2; fi
  rm -f "$tmp"
  return "$rc"
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
