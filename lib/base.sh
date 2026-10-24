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
    # The tracked config is somebody else's text. A name that holds a control byte is no ref
    # (git forbids them, and U+0080 to U+009F in UTF-8 form are terminal controls too), and
    # it must never reach a terminal as it is: refuse it here, escaped.
    [ "$(path_spell "$ref")" = "$ref" ] || die "bad base= in .gauntlet/config: $ref"
    printf '%s\n' "$ref"
  elif ref=$(git symbolic-ref -q --short refs/remotes/origin/HEAD) && [ -n "$ref" ]; then
    printf '%s\n' "$ref"
  else
    printf 'main\n'
  fi
}

# BASE_HINT: what to do when the base does not resolve. The default branch of a repo is not
# always main, and a repo without origin/HEAD falls back to it. The gates and doctor say the same.
BASE_HINT='run gauntlet base <ref> or set base= in .gauntlet/config'

# fetch_base_ref <ref>: bring an origin/ ref up to date, as the gates do before they use it;
# a ref of another kind is left alone. Returns git's status. An explicit refspec stores the ref
# even in a single-branch clone. The prompt is off so a credential request cannot stall a hook
# or CI.
fetch_base_ref() {
  case "$1" in
    origin/*) GIT_TERMINAL_PROMPT=0 git fetch --quiet origin "+refs/heads/${1#origin/}:refs/remotes/$1" ;;
  esac
}

# base_resolves <ref>: succeed when <ref> names a commit once the gates' own fetch has run (a
# failed fetch is not an error here: a ref that is already local still resolves). doctor asks this
# with the ref resolve_base gives, so it judges the base the way merge_base does.
base_resolves() {
  fetch_base_ref "$1" > /dev/null 2>&1 || true
  git rev-parse --verify -q "$1^{commit}" > /dev/null
}

# merge_base <ref>: print the sha where HEAD forked from ref. An origin/ ref is
# fetched first; a failed fetch warns and uses the local ref. Exits 2 when ref
# does not exist or no merge-base is found. A shallow clone is named as the
# cause; the merge-base is never guessed. Exits via die on every failure. Callers
# must use a plain x=$(...) or || exit; never local x=$(...), if x=$(...) or a
# bare "$(...)", which mask the exit.
merge_base() {
  local ref=$1 sha err rc=0
  # git echoes the ref it was given in its own errors, so its lines go through path_spell too.
  err=$(tmp_new) || die "cannot create a temp file"
  fetch_base_ref "$ref" 2> "$err" || rc=$?
  path_spell < "$err" >&2
  rm -f "$err"
  if [ "$rc" -ne 0 ]; then
    printf 'gauntlet: fetch of %s failed; using the local ref\n' "$(path_spell "$ref")" >&2
  fi
  git rev-parse --verify -q "$ref^{commit}" >/dev/null || die "unknown ref: $ref; $BASE_HINT"
  if sha=$(git merge-base HEAD "$ref") && [ -n "$sha" ]; then
    printf '%s\n' "$sha"
    return 0
  fi
  if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
    die "shallow clone: fetch full history"
  fi
  die "no merge-base between HEAD and $ref"
}

# git_read <what> <out> <git args...>: run git with its standard output in the file <out>, and
# tell "there" from "not there" from "cannot tell". Returns 0 when git printed something, 1
# when it succeeds and prints nothing, and 2 when git fails, after printing "gauntlet: cannot
# read <what>: <git's first error line>" once. The caller says what to list, so a failure to
# read (a damaged object, a bad sha, a corrupt index) is never taken for an absent path. The one
# place that message is made and its text escaped.
git_read() {
  local what=$1 out=$2 err rc=0
  shift 2
  err=$(tmp_new) || return 2
  git "$@" > "$out" 2> "$err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'gauntlet: cannot read %s: %s\n' "$(path_spell "$what")" "$(path_spell "$(head -n 1 "$err")")" >&2
    rc=2
  elif [ -s "$out" ]; then
    rc=0
  else
    rc=1
  fi
  rm -f "$err"
  return "$rc"
}

# git_has <what> <git args...>: git_read for a caller that wants only the answer, not the
# output.
git_has() {
  local what=$1 out rc=0
  shift
  out=$(tmp_new) || return 2
  git_read "$what" "$out" "$@" || rc=$?
  rm -f "$out"
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
        printf 'gauntlet: cannot read %s at %s\n' "$(path_spell "$2")" "$1" >&2
        return 2
      }
      ;;
    1) ;;
    *) return 2 ;;
  esac
}
