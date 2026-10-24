# shellcheck shell=bash
# install and install-hooks: vendor the runner into .gauntlet/ and add the gate to
# each existing hook, never taking the hooks over (ADR-0006), and never editing a
# file this project does not own (R25, R26). Sourced, never executed. Bash 3.2
# compatible; awk, git and coreutils only. Needs core.sh. bin/gauntlet sets
# GAUNTLET_BIN, the physical bin directory of the running runner, before sourcing.

# The command strings of the two gates. A hook manager's config (lefthook, prek) runs them as
# they are, and doctor looks for them there; the pre-push one carries --pre-push, which is how the
# gate learns what git is pushing (a hook manager has to pass git's stdin on: lefthook does with
# use_stdin). A gate line of a stage is gauntlet's when it runs the NEEDLE of that stage.
GAUNTLET_CMD_STAGED='.gauntlet/bin/gauntlet check --staged'
HOOK_NEEDLE_CI='.gauntlet/bin/gauntlet check --ci'
GAUNTLET_CMD_CI="$HOOK_NEEDLE_CI --pre-push"

# The gate lines. A created hook gets the plain pinned form; an existing hook gets the `|| exit $?`
# form on the line after its shebang (see add_hook_line). A hook that has either form, as a whole
# line, is already done. A line that ends in the marker "# gauntlet" and runs the gate of its stage
# is gauntlet's (R47): when it is not the current form, install-hooks replaces it where it stands
# and doctor fails it. No list of older forms is kept.
HOOK_LINE_STAGED="$GAUNTLET_CMD_STAGED  # gauntlet"
HOOK_GATE_STAGED="$GAUNTLET_CMD_STAGED || exit \$?  # gauntlet"

# The pre-push line (R41). Git sends the ref lines once, on stdin, and the gate reads them to the
# end, so a command of the project's own after it (git lfs pre-push, a loop over the ref lines)
# would read nothing. The line copies stdin to a temp file, runs the gate on the file, and gives
# stdin back as the same file for the commands that follow; the file is removed once stdin is the
# open descriptor, and on every way out. It is one line, POSIX sh (hooks run under dash, ash, bash,
# zsh as sh, and under sh -e in husky v9), and fails closed: no temp file, no copy of stdin, or no
# way to hand it back is exit 2 (a shell may exit on its own when the hand-back fails: 2 in dash,
# 1 in the POSIX modes of bash, ash and zsh; the hook stops all the same), and a failing gate is
# its own status. A terminal on stdin (a hook run by hand) is not read and is kept for the project's
# commands; the gate then sees an empty file and judges the checked-out branch. A kill between the
# mktemp and the end can leave a file in TMPDIR. The same one line is the plain form, the gate form
# and, inside a test for the runner, the form for a shared hooks directory; the config snippets
# keep the bare command because the hook manager owns stdin.
# shellcheck disable=SC2016 # shell text for a hook: $(...) and $_gauntlet_in expand when the hook runs
HOOK_BODY_CI='_gauntlet_in=$(mktemp) || exit 2; [ -t 0 ] || cat >"$_gauntlet_in" || { rm -f "$_gauntlet_in"; exit 2; }; '"$GAUNTLET_CMD_CI"' <"$_gauntlet_in" || { _gauntlet_rc=$?; rm -f "$_gauntlet_in"; exit "$_gauntlet_rc"; }; [ -t 0 ] || exec <"$_gauntlet_in" || { rm -f "$_gauntlet_in"; exit 2; }; rm -f "$_gauntlet_in"'
HOOK_LINE_CI="$HOOK_BODY_CI  # gauntlet"
HOOK_GATE_CI=$HOOK_LINE_CI

# When pre-commit and pre-push are one file (a symlink, a hard link), that script runs for both
# hooks, so a gate line in it would run in both: the staged gate under pre-push and the push gate
# under pre-commit. The gate lines go inside these tests on the hook's name, which the user adds by
# hand (install-hooks never edits such a file). The gate lines stay whole lines of their own, so
# doctor reads them like any others; the two tests are what doctor looks for besides.
# shellcheck disable=SC2016 # shell text for a hook: ${0##*/} is expanded when the hook runs
HOOK_GUARD_STAGED='if [ "${0##*/}" = pre-commit ]; then'
# shellcheck disable=SC2016 # as above
HOOK_GUARD_CI='if [ "${0##*/}" = pre-push ]; then'

# The form for a hooks directory shared with other repositories (core.hooksPath outside this
# repo): the same gate, but only where the vendored runner exists, so a repository without
# gauntlet is not blocked by it. The gate is the first command of the body, so git's stdin
# reaches the pre-push gate. install-hooks prints it, doctor accepts it. Built from the command
# strings above, so the gate text has one source.
HOOK_SHARED_STAGED="if [ -x .gauntlet/bin/gauntlet ]; then $GAUNTLET_CMD_STAGED || exit \$?; fi"
HOOK_SHARED_CI="if [ -x .gauntlet/bin/gauntlet ]; then $HOOK_BODY_CI; fi"

# shellcheck disable=SC2016 # the awk program reads its record; it is not shell text to expand
# marked(line, needle): whether a line of a hook is gauntlet's (R47): it ends in the marker (a CR
# before the newline and blanks after the marker are ignored), it is not a comment, and it runs
# the needle, the gate command of its stage. The marker alone is not enough: the project's own
# "echo tidy  # gauntlet" is not ours. One definition for the check and the replacement.
HOOK_MARKED_AWK='
function marked(line, needle) {
  sub(/\r$/, "", line)
  return line ~ /# gauntlet[ \t]*$/ && line !~ /^[ \t]*#/ && index(line, needle) > 0
}
'

# shellcheck disable=SC2016 # the awk program reads its record; it is not shell text to expand
# The decision for one existing hook, run by awk over the file: exit 0 when the gate
# may go into it, 3 when the file is one we must not edit (CRLF, or a shebang whose
# interpreter is not a shell). Nothing is written by this program.
HOOK_CHECK_AWK='
function base(p) { sub(/.*\//, "", p); return p }
function interpreter(line,   s, n, w, i) {
  s = substr(line, 3)
  gsub(/^[ \t]+|[ \t]+$/, "", s)
  n = split(s, w, /[ \t]+/)
  if (n == 0) return ""
  if (base(w[1]) != "env") return base(w[1])
  i = 2
  while (i <= n && substr(w[i], 1, 1) == "-") i++
  if (i > n) return ""
  return base(w[i])
}
function is_shell(name) {
  return name == "sh" || name == "bash" || name == "dash" || name == "zsh" || name == "ksh" || name == "ash"
}
NR == 1 { first = $0 }
index($0, "\r") > 0 { crlf = 1 }
END {
  if (crlf) exit 3
  if (substr(first, 1, 2) == "#!" && !is_shell(interpreter(first))) exit 3
  exit 0
}
'

# install_lock <target> [create]: take the lock that serializes install and install-hooks, or
# wait for it. <target> is hook_target's answer, which says where the hooks go and so what the lock
# has to protect. The lock is a directory made with mkdir, which either creates it or fails.
# Monorepo `prepare` scripts run these commands at the same moment, and unserialised they lost the
# project's own hook body, doubled the gate line and left .gauntlet/lib empty. It sits under the git
# common dir when the hooks directory does (the default .git/hooks, which linked worktrees share
# and so must take turns at). For every other layout (husky, a hooks directory in the worktree, a
# hook manager's config, a shared directory that is only printed) nothing is written under the git
# dir, which may be read-only, so the lock is .gauntlet/.install.lock of the worktree. install and
# install-hooks of one layout take the same lock: one lock per run, so they cannot wait for each
# other. install makes .gauntlet/ for it ("create"); install-hooks never does, since without one
# there is no runner and it refuses or only prints. A command that finds the lock held waits for
# it (GAUNTLET_LOCK_WAIT seconds, 30 by default; one line on stderr says so) and then does its work
# on what the other left, which is where the "gate line already there" check is: it runs under the
# lock, so it sees every edit made before. Only the run that made the lock names it in
# GAUNTLET_LOCK, and only that name is removed on the way out (gauntlet_cleanup). Needs hook_paths
# first. A run that already holds the lock (install calls install_hooks) returns at once. After the
# wait a lock nobody frees, left by a killed process, is not broken on a guess: exit 2 with the
# path to remove.
install_lock() {
  local target=$1 dir lock wait=${GAUNTLET_LOCK_WAIT:-30} limit ticks=0 told=0 absent=0 sig=''
  if [ -n "${GAUNTLET_LOCK:-}" ]; then return 0; fi
  # Digits only and at most four, read as decimal: a leading zero is not octal ($((08)) is an error).
  case "$wait" in
    *[!0-9]*|?????*) die "GAUNTLET_LOCK_WAIT must be a whole number of seconds, got [$wait]" ;;
  esac
  case "${target#dir }/" in
    "$HOOKS_COMMON/"*)
      dir=$HOOKS_COMMON
      lock="$dir/gauntlet-install.lock"
      ;;
    *)
      dir="$HOOKS_ROOT/.gauntlet"
      if [ ! -d "$dir" ]; then
        if [ "${2:-}" != create ]; then return 0; fi
        mkdir -p "$dir" 2> /dev/null || die "cannot lock: $HOOKS_ROOT is not writable; fix the permissions"
      fi
      lock="$dir/.install.lock"
      ;;
  esac
  limit=$((10#$wait * 5))
  while :; do
    # A signal that lands while mkdir runs is handled once it returns, before the next
    # statement could record that the lock is ours: the lock would stay. So for these two
    # statements the signals only leave a note, and the run exits on it once the lock is named.
    trap 'sig=129' HUP
    trap 'sig=130' INT
    trap 'sig=143' TERM
    if mkdir "$lock" 2> /dev/null; then GAUNTLET_LOCK=$lock; fi
    gauntlet_signal_traps
    if [ -n "$sig" ]; then exit "$sig"; fi
    if [ -n "${GAUNTLET_LOCK:-}" ]; then return 0; fi
    if [ -d "$lock" ]; then
      absent=0
      if [ "$ticks" -ge "$limit" ]; then die "another install holds $lock; if none is running, remove it"; fi
      if [ "$told" -eq 0 ]; then
        printf 'gauntlet: waiting for another install to finish (%s)\n' "$(path_spell "$lock")" >&2
        told=1
      fi
      if sleep 0.2 2> /dev/null; then ticks=$((ticks + 1)); else sleep 1; ticks=$((ticks + 5)); fi
    else
      # mkdir failed and nothing is there: the lock was freed between the two calls, or the
      # directory cannot be written. A few more tries tell them apart.
      absent=$((absent + 1))
      if [ "$absent" -ge 3 ]; then
        if [ -w "$dir" ]; then die "cannot create $lock"; fi
        die "cannot lock: $dir is not writable; fix the permissions"
      fi
    fi
  done
}

# GAUNTLET_KEEP: the files install creates under .gauntlet/ that the runner reads from the working
# tree and that a clone and CI must therefore have: one gitignore pattern per line, relative to
# .gauntlet/ (a leading / anchors a file of its own directory). The source of truth for
# .gauntlet/.gitignore (gitignore_text) and for doctor, which tells these files from the rest. The
# project's rules and formats are in it for the same reason as its runner: a rule the working tree
# has and the commit does not is judged by the local gate and not by CI.
GAUNTLET_KEEP=$'bin/gauntlet\nlib/*.sh\nlib/formats/*.md\nrules/*.md\nformats/*.md\n/config\n/baseline.tsv\n/exceptions.tsv\n/.gitignore'

# gitignore_text: the lines of .gauntlet/.gitignore, one per line. STATUS.md is derived text and the
# lock is a directory that exists while an install runs: both stay out of git. A root .gitignore
# can hide any file here (bin/ and lib/ hide the runner, *.sh and *.md the files in it, *.tsv the
# state files), so each GAUNTLET_KEEP pattern is brought back by a line of its own, preceded by the
# directories above it (a file cannot be re-included under an ignored directory). Narrow on
# purpose: !bin/** would bring back .DS_Store and *.swp too.
gitignore_text() {
  printf 'STATUS.md\n.install.lock/\n'
  GL_KEEP=$GAUNTLET_KEEP awk 'BEGIN {
    n = split(ENVIRON["GL_KEEP"], keep, "\n")
    for (i = 1; i <= n; i++) {
      rest = keep[i]
      sub(/^\//, "", rest)
      dir = ""
      while ((k = index(rest, "/")) > 0) {
        dir = dir substr(rest, 1, k)
        rest = substr(rest, k + 1)
        if (!(dir in seen)) { seen[dir] = 1; print "!" dir }
      }
      print "!" keep[i]
    }
  }'
}

# gitignore_missing <file>: the lines of gitignore_text that <file> lacks, whole lines (a CR before
# the newline is ignored), one per line. All of them when <file> does not exist. Fails when <file>
# cannot be read.
gitignore_missing() {
  if [ ! -e "$1" ]; then
    gitignore_text
    return 0
  fi
  GL_WANT=$(gitignore_text) awk 'BEGIN { n = split(ENVIRON["GL_WANT"], want, "\n") }
    { sub(/\r$/, ""); have[$0] = 1 }
    END { for (i = 1; i <= n; i++) if (!(want[i] in have)) print want[i] }
  ' "$1"
}

# gauntlet_keeps <path>: succeed when <path>, relative to .gauntlet/, is one of GAUNTLET_KEEP.
gauntlet_keeps() {
  local pat
  while IFS= read -r pat; do
    pat=${pat#/}
    # shellcheck disable=SC2254 # the pattern is a glob on purpose
    case "$1" in $pat) return 0 ;; esac
  done <<KEEP
$GAUNTLET_KEEP
KEEP
  return 1
}

# install_gitignore: write .gauntlet/.gitignore, or add the lines of gitignore_text that an existing
# one lacks. The user's own lines stay, where they are, and what is added follows them.
install_gitignore() {
  local file=.gauntlet/.gitignore missing added
  if [ ! -e "$file" ]; then
    gitignore_text 2> /dev/null > "$file" || die "cannot create $file"
    printf 'created %s\n' "$file"
    return 0
  fi
  missing=$(gitignore_missing "$file" 2> /dev/null) || die "cannot read $file"
  if [ -z "$missing" ]; then return 0; fi
  added=$(plural "$(printf '%s\n' "$missing" | awk 'END { print NR }')" line lines)
  # A file that does not end in a newline gets one first, so the first added line is a line of its own.
  if [ -n "$(tail -c 1 "$file")" ]; then missing=$'\n'$missing; fi
  printf '%s\n' "$missing" 2> /dev/null >> "$file" || die "cannot update $file"
  printf 'updated %s: added %s\n' "$file" "$added"
}

# install: vendor the runner, create the state files that are missing, then
# install the hooks. The source is the checkout that holds the running script. The
# whole of it runs under the install lock (install_lock).
install_runner() {
  local src root target
  src=$(install_source) || die "cannot find the runner source"
  if [ ! -f "$src/bin/gauntlet" ] || [ ! -d "$src/lib" ]; then
    die "no runner at $src: expected bin/gauntlet and lib/"
  fi
  root=$(repo_root)
  cd "$root" || die "cannot enter $root"
  hook_paths || die "cannot find the git directory"
  target=$(hook_target) || exit 2
  install_lock "$target" create
  vendor_runner "$src"
  create_missing .gauntlet/baseline.tsv ''
  create_missing .gauntlet/exceptions.tsv $'type\ttarget\treason\tdate\tbranch\n'
  create_missing .gauntlet/config $'touched=off\n'
  install_gitignore
  if [ ! -d .gauntlet/rules ]; then
    mkdir -p .gauntlet/rules || die "cannot create .gauntlet/rules"
    printf 'created .gauntlet/rules/\n'
  fi
  install_hooks
}

# install_source: print the physical path of the runner checkout that holds the
# running script. bin/gauntlet sets GAUNTLET_BIN after following any symlinks.
install_source() {
  (cd "$GAUNTLET_BIN/.." && pwd -P)
}

# vendor_runner <source>: copy bin/ and lib/ of the checkout <source> into
# .gauntlet/, from the repo root. The copy is made first, as .bin.new and .lib.new;
# then the old runner is moved aside and the new one moved in (swap_runner). An
# install killed in between is put right by recover_interrupted_install. When
# <source> is the vendored copy itself (the same directory, through any symlink),
# nothing is copied.
vendor_runner() {
  if [ -d .gauntlet ] && [ "$1" = "$(cd .gauntlet && pwd -P)" ]; then
    printf 'runner already vendored in .gauntlet/\n'
    return 0
  fi
  mkdir -p .gauntlet || die "cannot create .gauntlet"
  recover_interrupted_install
  if ! cp -R "$1/bin" .gauntlet/.bin.new || ! cp -R "$1/lib" .gauntlet/.lib.new \
    || ! chmod -R u+w .gauntlet/.bin.new .gauntlet/.lib.new \
    || ! chmod +x .gauntlet/.bin.new/gauntlet; then
    discard_dirs .gauntlet/.bin.new .gauntlet/.lib.new
    die "cannot copy the runner into .gauntlet/"
  fi
  swap_runner
  printf 'vendored runner to .gauntlet/\n'
}

# recover_interrupted_install: an earlier install stopped between its moves. Each
# old runner that was moved aside goes back (its live copy, if one is there, is the
# half-swapped one). Then every copy that was never finished is removed.
recover_interrupted_install() {
  local name
  for name in bin lib; do
    if [ -e ".gauntlet/.$name.old" ]; then
      discard_dirs ".gauntlet/$name"
      mv ".gauntlet/.$name.old" ".gauntlet/$name" || die "cannot restore .gauntlet/$name from .gauntlet/.$name.old"
    fi
  done
  discard_dirs .gauntlet/.bin.new .gauntlet/.lib.new
}

# swap_runner: move the old runner aside and the new one in, bin then lib. A failed
# move rolls back what was moved. The new copies are dropped only once the old runner
# is back; the old copies are dropped only after every move succeeded.
swap_runner() {
  local bin_aside=0 bin_in=0 lib_aside=0
  if [ -e .gauntlet/bin ]; then
    if ! mv .gauntlet/bin .gauntlet/.bin.old; then
      swap_failed "$bin_aside" "$bin_in" "$lib_aside" "cannot move the old runner aside"
    fi
    bin_aside=1
  fi
  if ! mv .gauntlet/.bin.new .gauntlet/bin; then
    swap_failed "$bin_aside" "$bin_in" "$lib_aside" "cannot move the new runner into .gauntlet/bin"
  fi
  bin_in=1
  if [ -e .gauntlet/lib ]; then
    if ! mv .gauntlet/lib .gauntlet/.lib.old; then
      swap_failed "$bin_aside" "$bin_in" "$lib_aside" "cannot move the old runner aside"
    fi
    lib_aside=1
  fi
  if ! mv .gauntlet/.lib.new .gauntlet/lib; then
    swap_failed "$bin_aside" "$bin_in" "$lib_aside" "cannot move the new runner into .gauntlet/lib"
  fi
  discard_dirs .gauntlet/.bin.old .gauntlet/.lib.old
}

# swap_failed <bin-aside> <bin-in> <lib-aside> <message>: undo the moves that were
# made, in reverse, then fail. The new lib is never in place when a move fails, so
# only the old lib needs to come back. The new copies are dropped only when the old
# runner is back; otherwise they stay, and the message names the old copies that exist.
swap_failed() {
  local ok=0 old=""
  if [ "$3" = 1 ]; then mv .gauntlet/.lib.old .gauntlet/lib || ok=1; fi
  if [ "$2" = 1 ]; then mv .gauntlet/bin .gauntlet/.bin.new || ok=1; fi
  if [ "$1" = 1 ]; then mv .gauntlet/.bin.old .gauntlet/bin || ok=1; fi
  if [ "$ok" -ne 0 ]; then
    if [ "$1" = 1 ]; then old=" .gauntlet/.bin.old"; fi
    if [ "$3" = 1 ]; then old="$old .gauntlet/.lib.old"; fi
    die "$4; the rollback failed, so the old runner is in$old"
  fi
  discard_dirs .gauntlet/.bin.new .gauntlet/.lib.new
  die "$4; the old runner is back"
}

# discard_dirs <dir>...: remove directories this install made. Their modes are made
# writable first, so a read-only source copy can still be removed, and a failure
# here never aborts the caller.
discard_dirs() {
  chmod -R u+w "$@" 2>/dev/null || true
  rm -rf "$@" || true
}

# create_missing <path> <text>: write <path> with <text> when it does not exist.
# An existing file is never touched.
create_missing() {
  if [ -e "$1" ]; then
    return 0
  fi
  printf '%s' "$2" > "$1" || die "cannot create $1"
  printf 'created %s\n' "$1"
}

# install-hooks: add the gate to the project's hooks, from the repo root. husky's
# directory gets it. A config owned by lefthook, prek or another hook manager is
# printed, not edited. Any other hooks directory gets it when it is inside the repo or
# the git common dir; a shared one outside them is printed only. An empty
# core.hooksPath means unset: the default hooks directory is <common git dir>/hooks.
install_hooks() {
  local root target kind dir err
  root=$(repo_root)
  cd "$root" || die "cannot enter $root"
  hook_paths || die "cannot find the git directory"
  target=$(hook_target) || exit 2
  install_lock "$target"
  kind=${target%% *}
  dir=${target#"$kind"}
  dir=${dir# }
  HOOKS_KIND=$kind
  # The hooks call .gauntlet/bin/gauntlet from the repo root. A hook written where that is not an
  # executable fails every commit and push, so none is written: the message says what to do.
  # What is only printed is not written, so it is warned about.
  if [ ! -f .gauntlet/bin/gauntlet ] || [ ! -x .gauntlet/bin/gauntlet ]; then
    case "$kind" in
      husky|husky-v9|dir) die "no runner at $HOOKS_ROOT/.gauntlet/bin/gauntlet; run gauntlet install first" ;;
      *) printf 'gauntlet: warning: no runner at %s; run gauntlet install\n' "$(path_spell "$HOOKS_ROOT/.gauntlet/bin/gauntlet")" >&2 ;;
    esac
  fi
  case "$kind" in
    husky|husky-v9|dir)
      err=$(mkdir -p "$dir" 2>&1) || hook_cannot_write "$dir" "$(hook_reason "$err")" "$HOOK_LINE_STAGED" "$HOOK_LINE_CI"
      add_hook_pair "$dir"
      ;;
    print) print_hook_pair "$dir" ;;
    configs) print_config_snippets ;;
  esac
}

# hook_paths: set HOOKS_ROOT, the physical repo root, and HOOKS_COMMON, the physical
# git common dir. Relative paths in the hook code are taken from the repo root, so
# the caller must be there. Returns 2 when git cannot name the common dir.
hook_paths() {
  local root git_common
  root=$(repo_root) || return 2
  HOOKS_ROOT=$(physical_path "$root")
  git_common=$(git rev-parse --git-common-dir) || return 2
  HOOKS_COMMON=$(abs_path "$git_common")
}

# hook_target: print where install-hooks puts the gate, as one of: "husky <dir>"
# (husky's directory), "husky-v9 <dir>" (the same, for a v9 layout, whose wrapper runs the
# hook without the exec bit), "configs" (a lefthook, prek or other config owns the hooks),
# "dir <dir>" (a hooks directory this project owns) or "print <dir>" (a shared hooks
# directory outside the repo and its git dir, printed only). Needs hook_paths first.
# --path expands a leading ~ (so ~/.husky is the home directory's, not ./~/.husky).
hook_target() {
  local hooks_path husky hooks err reason rc=0
  err=$(tmp_new) || die "cannot create a temp file"
  hooks_path=$(git config --path --get core.hooksPath 2> "$err") || rc=$?
  # git config --get exits 1 for a key that is not set. Any other status is git failing to read
  # or expand the value, which is not "unset": the hooks would go to the wrong directory.
  case "$rc" in
    0) ;;
    1) hooks_path= ;;
    *)
      reason=$(head -n 1 "$err")
      rm -f "$err"
      die "cannot read core.hooksPath: ${reason:-git exited with status $rc}"
      ;;
  esac
  rm -f "$err"
  if husky=$(husky_hooks_path "$hooks_path"); then
    case "$husky" in
      */_) printf 'husky-v9 %s\n' "${husky%/_}" ;;
      *) printf 'husky %s\n' "$husky" ;;
    esac
    return 0
  fi
  if [ -n "$(config_files)" ]; then
    printf 'configs\n'
    return 0
  fi
  if [ -n "$hooks_path" ]; then
    hooks=$(abs_path "$hooks_path")
  else
    hooks=$(abs_path "$HOOKS_COMMON/hooks")
  fi
  if owned_path "$hooks" "$HOOKS_COMMON"; then
    printf 'dir %s\n' "$hooks"
  else
    printf 'print %s\n' "$hooks"
  fi
}

# add_hook_pair <dir>: add the pre-commit and pre-push gate lines to <dir>. One script that
# serves both hooks is not edited (hooks_one_script).
add_hook_pair() {
  if [ "$1/pre-commit" -ef "$1/pre-push" ]; then
    hooks_one_script "$1/pre-commit" "$1/pre-push"
    return 0
  fi
  add_hook_line "$1/pre-commit" "$HOOK_LINE_STAGED" "$HOOK_GATE_STAGED" "$GAUNTLET_CMD_STAGED"
  add_hook_line "$1/pre-push" "$HOOK_LINE_CI" "$HOOK_GATE_CI" "$HOOK_NEEDLE_CI"
}

# hooks_one_script_done <file>: succeed when <file>, which serves both hooks, holds both gate
# lines and both tests on the hook's name (HOOK_GUARD_*), as whole lines. Presence, not meaning:
# like every check of a hook, it cannot tell what the lines around them do.
hooks_one_script_done() {
  hook_has_gate "$1" "$GAUNTLET_CMD_STAGED" "$HOOK_LINE_STAGED" "$HOOK_GATE_STAGED" "$HOOK_SHARED_STAGED" \
    && hook_has_gate "$1" "$HOOK_NEEDLE_CI" "$HOOK_LINE_CI" "$HOOK_GATE_CI" "$HOOK_SHARED_CI" \
    && grep -Fxq -- "$HOOK_GUARD_STAGED" "$1" 2> /dev/null \
    && grep -Fxq -- "$HOOK_GUARD_CI" "$1" 2> /dev/null
}

# hooks_one_script <commit-hook> <push-hook> [shared]: the two paths are one file (same device and
# inode, which covers both a symlink and a hard link). Edit nothing: one gate line cannot be right
# for both hooks. Say why and print the lines to add by hand; or say they are there. With "shared"
# the lines are the guarded forms, for a hooks directory other repositories use.
hooks_one_script() {
  local shown a b staged=$HOOK_GATE_STAGED ci=$HOOK_GATE_CI
  if [ "${3:-}" = shared ]; then
    staged=$HOOK_SHARED_STAGED
    ci=$HOOK_SHARED_CI
  fi
  shown=$(path_spell "$(display_path "$1")")
  if hooks_one_script_done "$1"; then
    printf 'already present in %s\n' "$shown"
    warn_if_not_executable "$1"
    return 0
  fi
  a=$shown
  b=$(path_spell "$(display_path "$2")")
  if [ "$(hook_gate_state "$1" "$HOOK_NEEDLE_CI" "$HOOK_GATE_CI" "$HOOK_SHARED_CI")" = old ]; then
    printf 'ACTION NEEDED: %s and %s are the same file, so a gate line in it would run in both hooks. It is not edited. Its pre-push line is an older one: %s:\n%s\n' "$a" "$b" "$(hook_replace_words "$shown" 'check --ci')" "$ci"
    warn_if_not_executable "$1"
    return 0
  fi
  printf 'ACTION NEEDED: %s and %s are the same file, so a gate line in it would run in both hooks (the staged gate on push, the push gate on commit). It is not edited. Add to %s, as the first commands, after the shebang line if there is one:\n' "$a" "$b" "$shown"
  printf '%s\n%s\nfi\n%s\n%s\nfi\n' "$HOOK_GUARD_STAGED" "$staged" "$HOOK_GUARD_CI" "$ci"
  warn_if_not_executable "$1"
}

# print_hook_pair <dir>: print the two gate lines for <dir>, a hooks directory shared with other
# repositories (core.hooksPath outside this repo), which is not ours to edit. A plain gate line
# would fail in every repository that has no .gauntlet/, so the lines are the guarded forms.
print_hook_pair() {
  printf '%s is a hooks directory shared with other repositories (core.hooksPath), so the lines below are guarded: they do nothing where .gauntlet/bin/gauntlet is absent.\n' "$(path_spell "$1")"
  if [ "$1/pre-commit" -ef "$1/pre-push" ]; then
    hooks_one_script "$1/pre-commit" "$1/pre-push" shared
    return 0
  fi
  print_only "$1/pre-commit" "$HOOK_SHARED_STAGED" "$(hook_gate_state "$1/pre-commit" "$GAUNTLET_CMD_STAGED" "$HOOK_GATE_STAGED" "$HOOK_SHARED_STAGED")"
  print_only "$1/pre-push" "$HOOK_SHARED_CI" "$(hook_gate_state "$1/pre-push" "$HOOK_NEEDLE_CI" "$HOOK_GATE_CI" "$HOOK_SHARED_CI")"
}

# hook_reason <text>: the cause in the last line of a tool's or the shell's error, which reads
# "<program>: <path>: <cause>": what follows the last ": ".
hook_reason() {
  local text=${1##*$'\n'}
  printf '%s\n' "${text##*: }"
}

# hook_cannot_write <path> <reason> <line>...: a hook, or the directory for it, cannot be written.
# Say which path and why, what to do, and give the exact line to add by hand; exit 2. Nothing
# else is written: the first failure ends the command, like every other refusal.
hook_cannot_write() {
  local path=$1 reason=$2
  shift 2
  printf 'gauntlet: cannot write %s: %s; fix the permissions or add the line by hand\n' "$(path_spell "$(display_path "$path")")" "$(path_spell "$reason")" >&2
  printf '%s\n' "$@" >&2
  exit 2
}

# hook_overwrite <new-content-file> <hook> <line>: write the content over <hook> (which keeps its
# mode when it exists; a move of the temp file would not). The shell's own redirect error is
# captured, not printed raw: hook_cannot_write names the cause and the line to add by hand.
hook_overwrite() {
  local err
  err=$({ cat "$1" > "$2"; } 2>&1) || hook_cannot_write "$2" "$(hook_reason "$err")" "$3"
}

# add_hook_line <file> <plain> <gate> [<old-plain> <old-gate>]: the gate runs first in a hook
# we may edit. The gate form goes on the line right after the shebang (line 1 when there is
# none), so it runs before anything the project's own hook does, and an early exit, a trailing
# exit, exec, a line continuation or a failing last command cannot get past it. First also
# keeps git's stdin whole: the pre-push gate reads the ref lines git sends there
# (check --ci --pre-push), and any command before it that reads stdin would take them. The
# project's hook then runs unchanged and keeps its own exit status. A hook we must not edit is
# printed instead. A missing file, or an empty one, gets the plain pinned form. An existing
# file keeps its mode and every byte except the inserted line. A line that is gauntlet's (it
# ends in the marker and runs the <needle> gate) but not the current form is replaced where it
# stands (upgrade_gate_line, R47) instead of getting a second gate.
add_hook_line() {
  local file=$1 line=$2 gate=$3 needle=$4 state tmp rc=0
  state=$(hook_gate_state "$file" "$needle" "$line" "$gate")
  if [ "$state" = present ]; then
    printf 'already present in %s\n' "$(hook_shown "$file")"
    warn_if_not_executable "$file"
    return 0
  fi
  hook_editable "$file" || rc=$?
  case "$rc" in
    0) ;;
    1) print_only "$file" "$gate" "$state"; return 0 ;;
    *) die "cannot read $file" ;;
  esac
  if [ "$state" = old ]; then
    upgrade_gate_line "$file" "$gate" "$needle"
    printf 'updated gauntlet line in %s\n' "$(hook_shown "$file")"
    warn_if_not_executable "$file"
    return 0
  fi
  if [ ! -e "$file" ]; then
    tmp=$(tmp_new) || die "cannot create a temp file"
    printf '#!/usr/bin/env sh\n%s\n' "$line" > "$tmp" || die "cannot create a temp file"
    hook_overwrite "$tmp" "$file" "$line"
    rm -f "$tmp"
    chmod +x "$file" || die "cannot make $file executable"
    printf 'created %s\n' "$(hook_shown "$file")"
    return 0
  fi
  if [ ! -s "$file" ]; then
    tmp=$(tmp_new) || die "cannot create a temp file"
    printf '#!/usr/bin/env sh\n%s\n' "$line" > "$tmp" || die "cannot create a temp file"
    hook_overwrite "$tmp" "$file" "$line"
    rm -f "$tmp"
    printf 'added gauntlet line to %s\n' "$(hook_shown "$file")"
    warn_if_not_executable "$file"
    return 0
  fi
  tmp=$(tmp_new) || die "cannot create a temp file"
  if ! insert_gate_first "$file" "$gate" > "$tmp"; then
    rm -f "$tmp"
    die "cannot read $file"
  fi
  hook_overwrite "$tmp" "$file" "$gate"
  rm -f "$tmp"
  printf 'added gauntlet line to %s\n' "$(hook_shown "$file")"
  warn_if_not_executable "$file"
}

# upgrade_gate_line <file> <gate> <needle>: replace each line of <file> that is gauntlet's for
# the <needle> gate (marked, HOOK_MARKED_AWK) by <gate>, where it stands. Every other byte stays,
# a missing final newline included.
upgrade_gate_line() {
  local file=$1 tmp size
  tmp=$(tmp_new) || die "cannot create a temp file"
  GL_GATE=$2 GL_NEEDLE=$3 LC_ALL=C awk "$HOOK_MARKED_AWK"'
    BEGIN { gate = ENVIRON["GL_GATE"]; needle = ENVIRON["GL_NEEDLE"] }
    marked($0, needle) { print gate; next }
    { print }
  ' "$file" > "$tmp" || { rm -f "$tmp"; die "cannot read $file"; }
  if [ -n "$(tail -c 1 "$file")" ]; then
    # The file had no final newline and awk added one: take it off again.
    size=$(wc -c < "$tmp")
    head -c "$((size - 1))" "$tmp" > "$tmp.cut" || { rm -f "$tmp" "$tmp.cut"; die "cannot read $file"; }
    mv "$tmp.cut" "$tmp" || { rm -f "$tmp" "$tmp.cut"; die "cannot read $file"; }
  fi
  hook_overwrite "$tmp" "$file" "$2"
  rm -f "$tmp"
}

# hook_gate_state <file> <needle> <form>...: how <file> stands with the gate line of one stage,
# on stdout: "present" when a line of it is one of the <form>s (whole line, a CR before the
# newline ignored), else "old" when a line of it is gauntlet's for the <needle> gate (marked) but
# is none of them, else "none". A file that is missing or cannot be read is "none". doctor and
# install-hooks both ask this, so a hook is done, old or missing by one rule.
hook_gate_state() {
  local file=$1 needle=$2 forms='' form
  shift 2
  for form in "$@"; do forms="$forms$form"$'\n'; done
  if [ ! -f "$file" ]; then
    printf 'none\n'
    return 0
  fi
  GL_FORMS=$forms GL_NEEDLE=$needle LC_ALL=C awk "$HOOK_MARKED_AWK"'
    BEGIN { n = split(ENVIRON["GL_FORMS"], form, "\n"); needle = ENVIRON["GL_NEEDLE"] }
    {
      line = $0
      sub(/\r$/, "", line)
      for (i = 1; i <= n; i++) if (form[i] != "" && line == form[i]) present = 1
      if (marked($0, needle)) old = 1
    }
    END { print (present ? "present" : (old ? "old" : "none")) }
  ' "$file" 2> /dev/null || printf 'none\n'
}

# hook_has_gate <file> <needle> <form>...: succeed when hook_gate_state says "present".
hook_has_gate() {
  [ "$(hook_gate_state "$@")" = present ]
}

# hook_editable <file>: say whether install-hooks may edit <file> itself. Returns 0
# when it may, 1 when the gate is only printed for it (a dangling symlink, a symlink
# to a file this project does not own, a non-file, a NUL byte, a shebang or CRLF that
# is not a shell's), and 2 when the file cannot be read. A missing file is editable:
# install-hooks creates it.
hook_editable() {
  local file=$1 status=0
  if [ -L "$file" ] && [ ! -e "$file" ]; then return 1; fi
  if [ ! -e "$file" ]; then return 0; fi
  if [ -L "$file" ] && ! owned_path "$(resolve_link "$file")" "$HOOKS_COMMON"; then return 1; fi
  if [ ! -f "$file" ]; then return 1; fi
  if [ ! -s "$file" ]; then return 0; fi
  if has_nul "$file"; then return 1; fi
  awk "$HOOK_CHECK_AWK" "$file" || status=$?
  case "$status" in
    0) return 0 ;;
    3) return 1 ;;
    *) return 2 ;;
  esac
}

# insert_gate_first <file> <gate>: print <file> with <gate> on the line after its
# shebang, or as line 1 when there is no shebang. Every other byte is copied as it is.
insert_gate_first() {
  local first
  first=$(head -n 1 "$1") || return 1
  case "$first" in
    '#!'*)
      printf '%s\n' "$first"
      printf '%s\n' "$2"
      tail -n +2 "$1"
      ;;
    *)
      printf '%s\n' "$2"
      cat "$1"
      ;;
  esac
}

# has_nul <file>: succeed when <file> holds a NUL byte, which the line edit is not
# trusted with. An unreadable file is left to awk, which reports the read error.
has_nul() {
  if [ ! -r "$1" ]; then
    return 1
  fi
  # shellcheck disable=SC2094 # both sides only read the file; nothing is written
  if LC_ALL=C tr -d '\000' < "$1" | cmp -s - "$1"; then
    return 1
  fi
  return 0
}

# resolve_link <path>: print the physical path of the file <path> names, following
# symlinks. <path> must exist.
resolve_link() {
  local p=$1 hops=0 target
  while [ -L "$p" ] && [ "$hops" -lt 40 ]; do
    hops=$((hops + 1))
    target=$(readlink "$p")
    case "$target" in
      /*) p=$target ;;
      *) p="$(dirname "$p")/$target" ;;
    esac
  done
  printf '%s/%s\n' "$(cd "$(dirname "$p")" && pwd -P)" "$(basename "$p")"
}

# hook_replace_words <file> [<command>]: the words of the fix for a line of ours that is not the
# current form, in a hook that install-hooks does not edit. install-hooks prints them above the
# current line and doctor puts them before it, so both say the same. <file> is already spelled.
# With <command> the line is named by what it runs, for a script that holds the lines of both hooks.
hook_replace_words() {
  printf 'replace the line ending in "# gauntlet"%s in %s with' "${2:+ that runs $2}" "$1"
}

# print_only <file> <gate> [<state>]: a hook we will not edit. Say what to add, and where it goes;
# when it already holds a line of ours that is not the current form (state old), say to replace
# that line, because adding the gate beside it would leave both.
print_only() {
  local shown
  shown=$(hook_shown "$1")
  if [ "${3:-}" = old ]; then
    printf 'ACTION NEEDED: %s:\n%s\n' "$(hook_replace_words "$shown")" "$2"
  else
    printf 'ACTION NEEDED: add to %s:\n%s\n  (place it as the first command, after the shebang line if there is one)\n' "$shown" "$2"
  fi
  if [ -e "$1" ]; then
    warn_if_not_executable "$1"
  fi
}

# hook_needs_exec <kind>: whether a hook of this hook_target kind must have the exec bit. git
# ignores a hook file without it, except in a husky v9 layout, whose wrapper runs the user's file
# through sh. install-hooks warns (warn_if_not_executable) and doctor fails by this one predicate.
hook_needs_exec() {
  [ "$1" != husky-v9 ]
}

# warn_if_not_executable <file>: git ignores a hook without the exec bit, where hook_needs_exec
# says it matters (HOOKS_KIND is the kind install_hooks found). Never changes the mode of a file
# that already exists.
warn_if_not_executable() {
  if hook_needs_exec "${HOOKS_KIND:-}" && [ ! -x "$1" ]; then
    printf 'warning: %s is not executable; git will ignore it\n' "$(path_spell "$(display_path "$1")")" >&2
  fi
}

# husky_hooks_path <hooks-path>: print the normalised absolute core.hooksPath when it names
# a husky layout inside the repo root: .../.husky, or .../.husky/_ (husky v9, whose wrapper
# sources the .husky files). Prints nothing and fails otherwise. This is the one husky
# matcher: install-hooks and doctor both decide the layout from it.
husky_hooks_path() {
  local p=$1
  if [ -z "$p" ]; then
    return 1
  fi
  p=$(abs_path "$p")
  case "$p" in
    */.husky|*/.husky/_) ;;
    *) return 1 ;;
  esac
  if inside_root "$p"; then
    printf '%s\n' "$p"
  else
    return 1
  fi
}

# config_files: print each lefthook, prek or other hook-manager config in the repo
# root that install-hooks reads: YAML, TOML or JSON. Prints nothing when there is none.
config_files() {
  local f
  for f in lefthook.* .lefthook.* .config/lefthook.* .pre-commit-config.yaml prek.toml; do
    if [ ! -f "$f" ]; then
      continue
    fi
    case "$f" in
      *.yml|*.yaml|*.json|*.toml) printf '%s\n' "$f" ;;
    esac
  done
}

# print_config_snippets: for each config_files entry, print the lines to add, or say
# it is already configured. What it says follows config_state, which doctor reads too.
print_config_snippets() {
  local f
  config_files | while IFS= read -r f; do
    case "$(config_state "$f")" in
      ok)
        printf 'already configured in %s\n' "$(path_spell "$f")"
        continue
        ;;
      old)
        printf 'ACTION NEEDED: %s: %s\n' "$(config_replace_words "$(path_spell "$f")")" "$GAUNTLET_CMD_CI"
        if config_is_lefthook "$f"; then
          printf '  and set use_stdin: true on it, so that git'"'"'s ref lines reach it\n'
        fi
        continue
        ;;
      stdin)
        printf 'ACTION NEEDED: add use_stdin: true to the pre-push gauntlet command in %s, so that git'"'"'s ref lines reach it\n' "$(path_spell "$f")"
        continue
        ;;
    esac
    printf 'ACTION NEEDED: add to %s:\n' "$(path_spell "$f")"
    case "$f" in
      .pre-commit-config.*) prek_snippet ;;
      *.yml|*.yaml) lefthook_snippet ;;
      *) generic_snippet "$f" ;;
    esac
  done
}

# config_is_lefthook <file>: whether <file> is a lefthook config (lefthook.*, .lefthook.*,
# .config/lefthook.*), the one hook manager that passes git's stdin to a command only when it is
# told to (use_stdin).
config_is_lefthook() {
  case "${1##*/}" in
    lefthook.*|.lefthook.*) return 0 ;;
  esac
  return 1
}

# config_replace_words <file>: the words of the fix for a config that runs an older gauntlet
# pre-push command. install-hooks prints them before the current command and doctor does too.
config_replace_words() {
  printf 'replace the gauntlet command in %s with' "$1"
}

# config_state <file>: how a hook-manager config stands with the gate, on stdout: "ok" when it has
# both gate command strings (and, for lefthook, use_stdin set to true, in the way YAML, TOML or
# JSON spell it), "stdin" when it has both but lefthook's pre-push command would get no stdin, so
# the gate would judge the checked-out branch whatever git pushes, "old" when it runs an older
# pre-push command (the gate without --pre-push), which is replaced, not added to, else
# "missing". The check is on the file, not on the command: a use_stdin on another command
# satisfies it (a ceiling). doctor and install-hooks both ask this, so a config is done or not by
# one rule.
config_state() {
  local staged=0 ci=0 needle=0
  if grep -Fq -- "$GAUNTLET_CMD_STAGED" "$1" 2> /dev/null; then staged=1; fi
  if grep -Fq -- "$GAUNTLET_CMD_CI" "$1" 2> /dev/null; then ci=1; fi
  if grep -Fq -- "$HOOK_NEEDLE_CI" "$1" 2> /dev/null; then needle=1; fi
  if [ "$ci" -eq 0 ] && [ "$needle" -eq 1 ]; then
    printf 'old\n'
  elif [ "$ci" -eq 1 ] && [ "$staged" -eq 1 ]; then
    if config_is_lefthook "$1" && ! grep -Eq 'use_stdin"?[[:space:]]*[:=][[:space:]]*true' "$1" 2> /dev/null; then
      printf 'stdin\n'
    else
      printf 'ok\n'
    fi
  else
    printf 'missing\n'
  fi
}

# lefthook_snippet: the lefthook lines for both hooks.
lefthook_snippet() {
  cat <<'EOF'
pre-commit:
  commands:
    gauntlet:
      run: .gauntlet/bin/gauntlet check --staged
pre-push:
  commands:
    gauntlet:
      run: .gauntlet/bin/gauntlet check --ci --pre-push
      use_stdin: true
EOF
}

# prek_snippet: the pre-commit framework (prek) lines for both hooks.
prek_snippet() {
  cat <<'EOF'
- repo: local
  hooks:
    - id: gauntlet
      name: gauntlet
      entry: .gauntlet/bin/gauntlet check --staged
      language: system
      pass_filenames: false
      always_run: true
    - id: gauntlet-ci
      name: gauntlet (push)
      entry: .gauntlet/bin/gauntlet check --ci --pre-push
      language: system
      pass_filenames: false
      always_run: true
      stages: [pre-push]
EOF
}

# generic_snippet <file>: the two commands, with the hook each one belongs to; for a lefthook
# config, the switch that makes git's stdin reach the pre-push command.
generic_snippet() {
  printf '  pre-commit: %s\n  pre-push: %s\n' "$GAUNTLET_CMD_STAGED" "$GAUNTLET_CMD_CI"
  if config_is_lefthook "$1"; then
    printf '  lefthook: also set use_stdin to true on the pre-push command, so that git'"'"'s ref lines reach it\n'
  fi
}

# abs_path <path>: the absolute, normalised, physical form of <path>. A relative path
# is taken from the repo root. A path that does not exist keeps its normalised spelling.
abs_path() {
  local p=$1
  case "$p" in
    /*) ;;
    *) p="$HOOKS_ROOT/$p" ;;
  esac
  p=$(normalise_path "$p")
  physical_path "$p"
}

# normalise_path <absolute-path>: collapse repeated slashes, drop "." and trailing
# slashes, and resolve ".." lexically.
normalise_path() {
  P=$1 awk 'BEGIN {
    n = split(ENVIRON["P"], a, "/")
    k = 0
    for (i = 1; i <= n; i++) {
      if (a[i] == "" || a[i] == ".") continue
      if (a[i] == "..") { if (k > 0) k--; continue }
      k++
      b[k] = a[i]
    }
    out = ""
    for (i = 1; i <= k; i++) out = out "/" b[i]
    if (out == "") out = "/"
    print out
  }'
}

# physical_path <path>: print <path> with symlinks resolved when it is an existing
# directory; otherwise print <path> unchanged.
physical_path() {
  if [ -d "$1" ] && (cd "$1" && pwd -P); then
    return 0
  fi
  printf '%s\n' "$1"
}

# inside_root <path>: succeed when <path> is inside the repo root.
inside_root() {
  case "$1/" in
    "$HOOKS_ROOT/"*) return 0 ;;
    *) return 1 ;;
  esac
}

# owned_path <path> <git-common-dir>: succeed when <path> is inside the repo root or
# inside the common git dir (a linked worktree or submodule keeps its hooks there).
# Anything else is someone else's file or directory.
owned_path() {
  if inside_root "$1"; then
    return 0
  fi
  case "$1/" in
    "$2/"*) return 0 ;;
    *) return 1 ;;
  esac
}

# hook_shown <path>: <path> as a message prints it: relative to the repo root when it is inside it,
# and spelled (path_spell), because a hook path is the project's text.
hook_shown() {
  path_spell "$(display_path "$1")"
}

# display_path <path>: <path> relative to the repo root when it is inside it.
display_path() {
  case "$1" in
    "$HOOKS_ROOT"/*) printf '%s\n' "${1#"$HOOKS_ROOT"/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}
