# shellcheck shell=bash
# Path selection: which files a rule sees. Sourced, never executed.
# Bash 3.2 compatible; awk, git and coreutils only. Needs core.sh sourced first (tmp_new).

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
# measurement reads tracked_files instead. The tracked part refuses a path with a tab
# or a newline (R31); the untracked part leaves such a name out, since git does not
# track it and nothing is measured from it.
all_files() {
  tracked_list 0 || return 2
  untracked_files
}

# untracked_files: print the untracked files git does not ignore, once each, without
# the names that hold a tab or a newline.
untracked_files() {
  local tmp name rc=0
  tmp=$(tmp_new) || return 2
  git -c core.quotepath=off ls-files -o --exclude-standard -z > "$tmp" || rc=2
  if [ "$rc" -eq 0 ]; then
    while IFS= read -r -d '' name; do
      case "$name" in
        *$'\t'*|*$'\n'*) ;;
        *) printf '%s\n' "$name" ;;
      esac
    done < "$tmp"
  fi
  rm -f "$tmp"
  return "$rc"
}

# tracked_files: print every file in the index that exists in the working tree,
# once each. Untracked files are left out, so a local measurement equals what
# CI sees (decision 2, R19). A symlink whose target is missing is left out too: no
# detector can read it, and the stock rg rule exits 2 on it.
tracked_files() {
  tracked_list 1
}

# tracked_list <1|0>: the work of tracked_files; 1 leaves out the dangling symlinks.
# all_files passes 0: a case file that is a dangling link is a broken case, and test-rules
# should run it and say so.
tracked_list() {
  local list skip rc=0
  list=$(git_nul_lines -c core.quotepath=off ls-files -t -c -d -z) || return 2
  skip=$(tmp_new) || return 2
  { gitlink_paths && if [ "$1" = 1 ]; then dangling_link_paths; fi; } > "$skip" || rc=2
  if [ "$rc" -eq 0 ]; then printf '%s\n' "$list" | files_from_listing | skip_names "$skip" || rc=2; fi
  rm -f "$skip"
  return "$rc"
}

# gitlink_paths: print the paths of the gitlinks (submodules, mode 160000) in the index,
# one per line. A gitlink is a directory on disk, not a file a detector can read.
gitlink_paths() {
  local tmp rc=0
  tmp=$(tmp_new) || return 2
  git -c core.quotepath=off ls-files -s -z > "$tmp" || rc=2
  if [ "$rc" -eq 0 ]; then
    LC_ALL=C tr '\0' '\n' < "$tmp" | LC_ALL=C awk '
      substr($0, 1, 7) == "160000 " { print substr($0, index($0, "\t") + 1) }
    ' || rc=2
  fi
  rm -f "$tmp"
  return "$rc"
}

# dangling_link_paths: print the paths of the symlinks in the index (mode 120000) whose
# target does not exist in the working tree, one per line. [ -e ] follows the link: a link to
# a file or a directory that exists is not listed.
dangling_link_paths() {
  local tmp rc=0 p
  tmp=$(tmp_new) || return 2
  git -c core.quotepath=off ls-files -s -z > "$tmp" || rc=2
  if [ "$rc" -eq 0 ]; then
    LC_ALL=C tr '\0' '\n' < "$tmp" | LC_ALL=C awk '
      substr($0, 1, 7) == "120000 " { print substr($0, index($0, "\t") + 1) }
    ' | while IFS= read -r p; do
      if [ ! -e "$p" ]; then printf '%s\n' "$p"; fi
    done || rc=2
  fi
  rm -f "$tmp"
  return "$rc"
}

# skip_names <file>: read names on stdin, one per line, and print those that are not a
# line of <file>.
skip_names() {
  GL_SKIP=$1 awk '
    BEGIN { while ((getline line < ENVIRON["GL_SKIP"]) > 0) skip[line] = 1 }
    !($0 in skip)
  '
}

# git_nul_lines <git-args...>: run git, which must be given -z, and print its
# NUL-separated output one name per line. Names come out raw: git C-quotes
# names with `"`, `\` or tabs unless -z is given, and such names would never
# match a path the working tree reports. The output goes to a temp file first,
# because command substitution drops NUL bytes and a pipe would hide git's status.
# This is for listings of the tree that survives (tracked_files, staged_files, all_files):
# it is the one place that refuses a path with a tab or a newline (R31), because the
# baseline and the fingerprints are tab and line separated files, and such a name
# would corrupt them.
git_nul_lines() {
  git_nul_run refuse "$@"
}

# git_nul_diff_lines <git-args...>: git_nul_lines for a diff or a tree listing, which also
# names the paths a change removes (the old side of a rename, a deletion, the base's own
# files). Those lists only scope checks and re-key renames, and no baseline row holds an
# odd path, so an odd name is not refused: refusing it would fail the very change that
# renames or deletes the file. Its tab and newline become ?, one name still one line.
git_nul_diff_lines() {
  git_nul_run neutralise "$@"
}

# git_nul_run <refuse|neutralise> <git-args...>: the work of the two above.
git_nul_run() {
  local mode=$1 tmp rc=0 tagged=0 arg
  shift
  # ls-files -t puts "<tag> " in front of each name; the message leaves it out.
  for arg in "$@"; do
    if [ "$arg" = -t ]; then tagged=1; fi
  done
  tmp=$(tmp_new) || return 2
  git "$@" > "$tmp" || rc=2
  if [ "$rc" -eq 0 ] && [ "$mode" = refuse ]; then odd_paths_refuse "$tmp" "$tagged" || rc=2; fi
  if [ "$rc" -eq 0 ]; then
    # One pass: NUL ends a name (becomes a newline); in neutralise mode a tab or newline
    # inside a name becomes ?. In refuse mode there is none left to touch.
    LC_ALL=C tr '\t\n\0' '??\n' < "$tmp" || rc=2
  fi
  rm -f "$tmp"
  return "$rc"
}

# odd_paths_refuse <nul-file> <tagged>: return 0 when no name in the NUL-separated listing holds
# a tab or a newline. Otherwise print, for the first five such names, "gauntlet: path
# with a tab or newline: <name>; rename the file", a line for the rest, and return 2. git -z
# puts neither byte anywhere but in a name, so counting them in the whole listing is the
# test; the names are only worked out when there is one. <tagged> is 1 when each name has a
# two-character tag in front (ls-files -t). The name is somebody else's text: see
# path_spell, which keeps control bytes off the terminal.
odd_paths_refuse() (
  local odd name n=0
  odd=$(LC_ALL=C tr -cd '\t\n' < "$1" | wc -c) || return 2
  if [ "$((odd + 0))" -eq 0 ]; then return 0; fi
  # The C locale: one byte is one character, so no name is invalid in it and none is split.
  LC_ALL=C
  while IFS= read -r -d '' name; do
    case "$name" in
      *$'\t'*|*$'\n'*) ;;
      *) continue ;;
    esac
    n=$((n + 1))
    if [ "$n" -le 5 ]; then
      if [ "$2" = 1 ]; then name=${name#??}; fi
      printf 'gauntlet: path with a tab or newline: %s; rename the file\n' "$(path_spell "$name")" >&2
    fi
  done < "$1"
  if [ "$n" -gt 5 ]; then printf 'gauntlet: and %s more; rename the files\n' "$((n - 5))" >&2; fi
  return 2
)

# path_spell <name>: print the name with the tab written \t, the newline \n and every other byte
# below 0x20, and 0x7f, written \xNN, so printing a file name cannot move the cursor, clear the
# screen or set the terminal title. Everything else, non-ASCII included, is printed as it is.
# Run in the C locale (odd_paths_refuse does): a character is a byte there.
path_spell() {
  local name=$1 i=0 c hx out=
  while [ "$i" -lt "${#name}" ]; do
    c=${name:$i:1}
    case "$c" in
      $'\t') out=$out'\t' ;;
      $'\n') out=$out'\n' ;;
      [[:cntrl:]])
        printf -v hx '%02x' "'$c"
        out=$out'\x'$hx
        ;;
      *) out=$out$c ;;
    esac
    i=$((i + 1))
  done
  printf '%s\n' "$out"
}

# files_from_listing: read `git ls-files -t` output on stdin. One tag marks each
# line: "R name" marks a tracked file deleted from disk (it also appears as
# tracked), "S name" an entry with the skip-worktree bit (a sparse checkout: git lists
# it, the disk does not have it), any other tag is a live path. An unmerged path
# appears once per stage, so names are de-duplicated. No file is opened.
files_from_listing() {
  awk '
    $0 == "" { next }
    {
      name = substr($0, 3)
      if (substr($0, 1, 1) == "R") gone[name] = 1
      else if (substr($0, 1, 1) == "S") next
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

# staged_files: print staged paths that are added, copied, modified, renamed or changed
# in type (a symlink that became a file, or the reverse), leaving out the gitlinks and the
# symlinks whose target is missing.
staged_files() {
  local list skip rc=0
  list=$(git_nul_lines -c core.quotepath=off diff --cached --name-only --diff-filter=ACMRT -z) || return 2
  skip=$(tmp_new) || return 2
  { gitlink_paths && dangling_link_paths; } > "$skip" || rc=2
  if [ "$rc" -eq 0 ] && [ -n "$list" ]; then printf '%s\n' "$list" | skip_names "$skip" || rc=2; fi
  rm -f "$skip"
  return "$rc"
}
