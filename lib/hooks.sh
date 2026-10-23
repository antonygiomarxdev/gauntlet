# shellcheck shell=bash
# install and install-hooks: vendor the runner into .gauntlet/ and add the gate to
# each existing hook, never taking the hooks over (ADR-0006), and never editing a
# file this project does not own (R25, R26). Sourced, never executed. Bash 3.2
# compatible; awk, git and coreutils only. Needs core.sh. bin/gauntlet sets
# GAUNTLET_BIN, the physical bin directory of the running runner, before sourcing.

# The gate lines. A created hook gets the plain pinned form. An existing hook gets
# the `|| exit $?` form on the line after its shebang (see add_hook_line). A hook
# that has either form, as a whole line, is already done.
HOOK_LINE_STAGED='.gauntlet/bin/gauntlet check --staged  # gauntlet'
HOOK_GATE_STAGED='.gauntlet/bin/gauntlet check --staged || exit $?  # gauntlet'
HOOK_LINE_CI='.gauntlet/bin/gauntlet check --ci  # gauntlet'
HOOK_GATE_CI='.gauntlet/bin/gauntlet check --ci || exit $?  # gauntlet'

# The command strings that show a config already runs the gate.
GAUNTLET_CMD_STAGED='.gauntlet/bin/gauntlet check --staged'
GAUNTLET_CMD_CI='.gauntlet/bin/gauntlet check --ci'

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

# install: vendor the runner, create the state files that are missing, then
# install the hooks. The source is the checkout that holds the running script.
install_runner() {
  local src root
  src=$(install_source) || die "cannot find the runner source"
  if [ ! -f "$src/bin/gauntlet" ] || [ ! -d "$src/lib" ]; then
    die "no runner at $src: expected bin/gauntlet and lib/"
  fi
  root=$(repo_root)
  cd "$root" || die "cannot enter $root"
  vendor_runner "$src"
  create_missing .gauntlet/baseline.tsv ''
  create_missing .gauntlet/exceptions.tsv $'type\ttarget\treason\tdate\tbranch\n'
  create_missing .gauntlet/config $'touched=off\n'
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
  discard_dirs .gauntlet/.bin.new .gauntlet/.lib.new .gauntlet/.bin.old .gauntlet/.lib.old
}

# swap_runner: move the old runner aside and the new one in, bin then lib. A failed
# move rolls back what was moved. The new copies are dropped only once the old runner
# is back; the old copies are dropped only after every move succeeded.
swap_runner() {
  local bin_aside=0 bin_in=0 lib_aside=0 lib_in=0
  if [ -e .gauntlet/bin ]; then
    if ! mv .gauntlet/bin .gauntlet/.bin.old; then
      swap_failed "$bin_aside" "$bin_in" "$lib_aside" "$lib_in" "cannot move the old runner aside"
    fi
    bin_aside=1
  fi
  if ! mv .gauntlet/.bin.new .gauntlet/bin; then
    swap_failed "$bin_aside" "$bin_in" "$lib_aside" "$lib_in" "cannot move the new runner into .gauntlet/bin"
  fi
  bin_in=1
  if [ -e .gauntlet/lib ]; then
    if ! mv .gauntlet/lib .gauntlet/.lib.old; then
      swap_failed "$bin_aside" "$bin_in" "$lib_aside" "$lib_in" "cannot move the old runner aside"
    fi
    lib_aside=1
  fi
  if ! mv .gauntlet/.lib.new .gauntlet/lib; then
    swap_failed "$bin_aside" "$bin_in" "$lib_aside" "$lib_in" "cannot move the new runner into .gauntlet/lib"
  fi
  lib_in=1
  discard_dirs .gauntlet/.bin.old .gauntlet/.lib.old
}

# swap_failed <bin-aside> <bin-in> <lib-aside> <lib-in> <message>: undo the moves that
# were made, in reverse, then fail. The new copies are dropped only when the old
# runner is back; otherwise they stay, and the message names the old copies that exist.
swap_failed() {
  local ok=0 old=""
  if [ "$4" = 1 ]; then mv .gauntlet/lib .gauntlet/.lib.new || ok=1; fi
  if [ "$3" = 1 ]; then mv .gauntlet/.lib.old .gauntlet/lib || ok=1; fi
  if [ "$2" = 1 ]; then mv .gauntlet/bin .gauntlet/.bin.new || ok=1; fi
  if [ "$1" = 1 ]; then mv .gauntlet/.bin.old .gauntlet/bin || ok=1; fi
  if [ "$ok" -ne 0 ]; then
    if [ "$1" = 1 ]; then old=" .gauntlet/.bin.old"; fi
    if [ "$3" = 1 ]; then old="$old .gauntlet/.lib.old"; fi
    die "$5; the rollback failed, so the old runner is in$old"
  fi
  discard_dirs .gauntlet/.bin.new .gauntlet/.lib.new
  die "$5; the old runner is back"
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
  local root hooks_path husky git_common hooks
  root=$(repo_root)
  cd "$root" || die "cannot enter $root"
  HOOKS_ROOT=$(physical_path "$root")
  git_common=$(git rev-parse --git-common-dir) || die "cannot find the git directory"
  HOOKS_COMMON=$(abs_path "$git_common")
  if [ ! -f .gauntlet/bin/gauntlet ]; then
    printf 'gauntlet: warning: .gauntlet/bin/gauntlet is missing; run gauntlet install\n' >&2
  fi
  # --path expands a leading ~ (so ~/.husky is the home directory's, not ./~/.husky).
  hooks_path=$(git config --path --get core.hooksPath) || hooks_path=
  if husky=$(husky_dir "$hooks_path"); then
    mkdir -p "$husky" || die "cannot create $husky"
    add_hook_pair "$husky"
    return 0
  fi
  if print_config_snippets; then
    return 0
  fi
  if [ -n "$hooks_path" ]; then
    hooks=$(abs_path "$hooks_path")
  else
    hooks=$(abs_path "$HOOKS_COMMON/hooks")
  fi
  if owned_path "$hooks" "$HOOKS_COMMON"; then
    mkdir -p "$hooks" || die "cannot create $hooks"
    add_hook_pair "$hooks"
  else
    print_hook_pair "$hooks"
  fi
}

# add_hook_pair <dir>: add the pre-commit and pre-push gate lines to <dir>.
add_hook_pair() {
  add_hook_line "$1/pre-commit" "$HOOK_LINE_STAGED" "$HOOK_GATE_STAGED"
  add_hook_line "$1/pre-push" "$HOOK_LINE_CI" "$HOOK_GATE_CI"
}

# print_hook_pair <dir>: print the two gate lines for <dir>, which is not ours to edit.
print_hook_pair() {
  print_only "$1/pre-commit" "$HOOK_GATE_STAGED"
  print_only "$1/pre-push" "$HOOK_GATE_CI"
}

# add_hook_line <file> <plain> <gate>: the gate runs first in a hook we may edit. The
# gate form goes on the line right after the shebang (line 1 when there is none), so
# it runs before anything the project's own hook does, and an early exit, a trailing
# exit, exec, a line continuation or a failing last command cannot get past it. The
# project's hook then runs unchanged and keeps its own exit status. A hook we must not
# edit is printed instead. A missing file, or an empty one, gets the plain pinned form.
# An existing file keeps its mode and every byte except the inserted line.
add_hook_line() {
  local file=$1 line=$2 gate=$3 tmp status=0
  if [ -e "$file" ] && { grep -Fxq -- "$line" "$file" 2>/dev/null || grep -Fxq -- "$gate" "$file" 2>/dev/null; }; then
    printf 'already present in %s\n' "$(display_path "$file")"
    warn_if_not_executable "$file"
    return 0
  fi
  if [ -L "$file" ] && [ ! -e "$file" ]; then
    print_only "$file" "$gate"
    return 0
  fi
  if [ ! -e "$file" ]; then
    printf '#!/usr/bin/env sh\n%s\n' "$line" > "$file" || die "cannot create $file"
    chmod +x "$file" || die "cannot make $file executable"
    printf 'created %s\n' "$(display_path "$file")"
    return 0
  fi
  if [ -L "$file" ] && ! owned_path "$(resolve_link "$file")" "$HOOKS_COMMON"; then
    print_only "$file" "$gate"
    return 0
  fi
  if [ ! -f "$file" ]; then
    print_only "$file" "$gate"
    return 0
  fi
  if [ ! -s "$file" ]; then
    printf '#!/usr/bin/env sh\n%s\n' "$line" > "$file" || die "cannot write $file"
    printf 'added gauntlet line to %s\n' "$(display_path "$file")"
    warn_if_not_executable "$file"
    return 0
  fi
  if has_nul "$file"; then
    print_only "$file" "$gate"
    return 0
  fi
  awk "$HOOK_CHECK_AWK" "$file" || status=$?
  case "$status" in
    0) ;;
    3) print_only "$file" "$gate"; return 0 ;;
    *) die "cannot read $file" ;;
  esac
  tmp=$(mktemp "${TMPDIR:-/tmp}/gauntlet-hook.XXXXXX") || die "cannot create a temp file"
  if ! insert_gate_first "$file" "$gate" > "$tmp"; then
    rm -f "$tmp"
    die "cannot read $file"
  fi
  # Writing over the file keeps its mode; moving the temp file would not.
  cat "$tmp" > "$file" || { rm -f "$tmp"; die "cannot write $file"; }
  rm -f "$tmp"
  printf 'added gauntlet line to %s\n' "$(display_path "$file")"
  warn_if_not_executable "$file"
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
  if tr -d '\000' < "$1" | cmp -s - "$1"; then
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

# print_only <file> <gate>: a hook we will not edit. Say what to add, and where it goes.
print_only() {
  printf 'ACTION NEEDED: add to %s:\n%s\n  (place it as the first command, after the shebang line if there is one)\n' "$(display_path "$1")" "$2"
  if [ -e "$1" ]; then
    warn_if_not_executable "$1"
  fi
}

# warn_if_not_executable <file>: git ignores a hook without the exec bit. Never
# changes the mode of a file that already exists.
warn_if_not_executable() {
  if [ ! -x "$1" ]; then
    printf 'warning: %s is not executable; git will ignore it\n' "$(display_path "$1")" >&2
  fi
}

# husky_dir <hooks-path>: print the husky directory a core.hooksPath names, when the
# path ends in /.husky or /.husky/_ and lies inside the repo root. The trailing /_ is
# dropped, so nothing is ever written into a _ directory. Prints nothing and fails
# otherwise.
husky_dir() {
  local p=$1
  if [ -z "$p" ]; then
    return 1
  fi
  p=$(abs_path "$p")
  case "$p" in
    */.husky/_) p=${p%/_} ;;
  esac
  case "$p" in
    */.husky) ;;
    *) return 1 ;;
  esac
  if inside_root "$p"; then
    printf '%s\n' "$p"
  else
    return 1
  fi
}

# print_config_snippets: for each lefthook, prek, or TOML or JSON config in the repo
# root, print the lines to add, or say it is already configured. Succeeds when at
# least one config exists, so the hooks are left to that config.
print_config_snippets() {
  local f found=1
  for f in lefthook.* .lefthook.* .config/lefthook.* .pre-commit-config.yaml prek.toml; do
    if [ ! -f "$f" ]; then
      continue
    fi
    case "$f" in
      *.yml|*.yaml|*.json|*.toml) ;;
      *) continue ;;
    esac
    found=0
    if config_has_gate "$f"; then
      printf 'already configured in %s\n' "$f"
      continue
    fi
    printf 'ACTION NEEDED: add to %s:\n' "$f"
    case "$f" in
      .pre-commit-config.*) prek_snippet ;;
      *.yml|*.yaml) lefthook_snippet ;;
      *) generic_snippet ;;
    esac
  done
  return "$found"
}

# config_has_gate <file>: succeed when <file> contains both gate command strings.
# doctor reuses this to tell a configured hook manager from an unconfigured one.
config_has_gate() {
  grep -Fq -- "$GAUNTLET_CMD_STAGED" "$1" 2>/dev/null && grep -Fq -- "$GAUNTLET_CMD_CI" "$1" 2>/dev/null
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
      run: .gauntlet/bin/gauntlet check --ci
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
      entry: .gauntlet/bin/gauntlet check --ci
      language: system
      pass_filenames: false
      always_run: true
      stages: [pre-push]
EOF
}

# generic_snippet: the two commands, with the hook each one belongs to.
generic_snippet() {
  printf '  pre-commit: %s\n  pre-push: %s\n' "$GAUNTLET_CMD_STAGED" "$GAUNTLET_CMD_CI"
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

# display_path <path>: <path> relative to the repo root when it is inside it.
display_path() {
  case "$1" in
    "$HOOKS_ROOT"/*) printf '%s\n' "${1#"$HOOKS_ROOT"/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}
