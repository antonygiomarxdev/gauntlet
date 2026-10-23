# shellcheck shell=bash
# Base resolution: the ref a branch is measured against, and its merge-base.
# Sourced, never executed. Bash 3.2 compatible; git and coreutils only. Needs core.sh
# sourced first (tmp_new).

# current_branch: print the branch being checked. CI sets GITHUB_HEAD_REF; a
# detached HEAD outside CI prints HEAD.
current_branch() {
  local branch
  if [ -n "${GITHUB_HEAD_REF:-}" ]; then
    printf '%s\n' "$GITHUB_HEAD_REF"
  elif branch=$(git symbolic-ref -q --short HEAD) && [ -n "$branch" ]; then
    printf '%s\n' "$branch"
  else
    printf 'HEAD\n'
  fi
}

# resolve_base [ref]: print the base ref. The first of these that is set wins:
# the explicit ref, branch.<cur>.gauntletBase, config base, origin/HEAD, main.
# Exits via die when outside a repo. Callers must use a plain x=$(...) or
# || exit; never local x=$(...), if x=$(...) or a bare "$(...)", which mask it.
resolve_base() {
  local branch ref
  if [ -n "${1:-}" ]; then
    printf '%s\n' "$1"
    return 0
  fi
  branch=$(current_branch)
  if ref=$(git config --get "branch.$branch.gauntletBase") && [ -n "$ref" ]; then
    printf '%s\n' "$ref"
  elif ref=$(config_get base "") && [ -n "$ref" ]; then
    printf '%s\n' "$ref"
  elif ref=$(git symbolic-ref -q --short refs/remotes/origin/HEAD) && [ -n "$ref" ]; then
    printf '%s\n' "$ref"
  else
    printf 'main\n'
  fi
}

# merge_base <ref>: print the sha where HEAD forked from ref. An origin/ ref is
# fetched first; a failed fetch warns and uses the local ref. Exits 2 when ref
# does not exist or no merge-base is found. A shallow clone is named as the
# cause; the merge-base is never guessed. Exits via die on every failure. Callers
# must use a plain x=$(...) or || exit; never local x=$(...), if x=$(...) or a
# bare "$(...)", which mask the exit.
merge_base() {
  local ref=$1 sha
  case "$ref" in
    origin/*)
      # An explicit refspec stores the ref even in a single-branch clone. The
      # prompt is off so a credential request cannot stall a hook or CI.
      if ! GIT_TERMINAL_PROMPT=0 git fetch --quiet origin "+refs/heads/${ref#origin/}:refs/remotes/$ref"; then
        printf 'gauntlet: fetch of %s failed; using the local ref\n' "$ref" >&2
      fi
      ;;
  esac
  git rev-parse --verify -q "$ref^{commit}" >/dev/null || die "unknown ref: $ref"
  if sha=$(git merge-base HEAD "$ref") && [ -n "$sha" ]; then
    printf '%s\n' "$sha"
    return 0
  fi
  if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
    die "shallow clone: fetch full history"
  fi
  die "no merge-base between HEAD and $ref"
}

# git_has <what> <git args...>: run git and tell "there" from "not there" from "cannot
# tell". Returns 0 when git prints something, 1 when it succeeds and prints nothing,
# and 2 when git fails, after printing "gauntlet: cannot read <what>: <git's first
# error line>" once. The caller says what to list, so a failure to read (a damaged
# object, a bad sha, a corrupt index) is never taken for an absent path.
git_has() {
  local what=$1 out err rc=0
  shift
  out=$(tmp_new) || return 2
  err=$(tmp_new) || { rm -f "$out"; return 2; }
  git "$@" > "$out" 2> "$err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'gauntlet: cannot read %s: %s\n' "$what" "$(head -n 1 "$err")" >&2
    rc=2
  elif [ -s "$out" ]; then
    rc=0
  else
    rc=1
  fi
  rm -f "$out" "$err"
  return "$rc"
}

# base_has <sha> <path>: succeed (0) when <path> exists at <sha>, return 1 when it does
# not and 2 when git cannot tell (R32). The path is root-relative, whatever the working
# directory. ls-tree reads trees only, so a damaged blob still lists as present: the
# read that follows (at_base) is where a blob that cannot be read fails.
base_has() {
  git_has "$2 at $1" ls-tree --full-tree --name-only -z "$1" -- "$2"
}

# index_has <path>: base_has for the index, with the same 0, 1 and 2. The pathspec
# magic makes the path root-relative and literal for this one path, wherever the
# working directory is and whatever the environment says.
index_has() {
  git_has "$1 in the index" ls-files -z -- ":(top,literal)$1"
}

# at_base <sha> <path>: print the file as it was at sha; nothing when the path is
# absent. An sha that is not a commit dies with exit 2, and so does a path that is
# listed but cannot be read (the message names the path and the sha): only an absent
# path is silent.
at_base() {
  local rc=0
  git cat-file -e "$1^{commit}" 2>/dev/null || die "bad sha: $1"
  base_has "$1" "$2" || rc=$?
  case "$rc" in
    0)
      git show "$1:$2" 2>/dev/null || {
        printf 'gauntlet: cannot read %s at %s\n' "$2" "$1" >&2
        return 2
      }
      ;;
    1) ;;
    *) return 2 ;;
  esac
}
