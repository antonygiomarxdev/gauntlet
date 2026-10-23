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

# all_files: print every tracked or untracked-but-not-ignored file, minus the
# tracked files deleted from the working tree. The deleted list comes from git,
# so no file is opened: symlinks, unreadable files and huge files cost nothing.
all_files() {
  local dir status=0
  dir=$(mktemp -d) || return 2
  git -c core.quotepath=off ls-files --deleted > "$dir/gone" || status=2
  if [ "$status" -eq 0 ]; then
    git -c core.quotepath=off ls-files -co --exclude-standard > "$dir/all" || status=2
  fi
  if [ "$status" -eq 0 ]; then
    GL_GONE="$dir/gone" awk '
      BEGIN { while ((getline line < ENVIRON["GL_GONE"]) > 0) gone[line] = 1 }
      !($0 in gone)
    ' "$dir/all" || status=2
  fi
  rm -rf "$dir"
  return "$status"
}

# staged_files: print staged paths that are added, copied, modified or renamed.
staged_files() {
  git -c core.quotepath=off diff --cached --name-only --diff-filter=ACMR
}
