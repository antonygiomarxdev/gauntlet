# shellcheck shell=bash
# install and install-hooks: vendor the runner into .gauntlet/ and add one line
# to each existing hook, never taking the hooks over (ADR-0006), and never editing
# a file this project does not own (R25). Sourced, never executed. Bash 3.2
# compatible; awk, git and coreutils only. Needs core.sh. bin/gauntlet sets
# GAUNTLET_BIN, the physical bin directory of the running runner, before sourcing.

# The gate lines. The plain form is appended at the end of a hook. The
# `|| exit $?` form is inserted before a trailing exit or exec, so the gate blocks
# without set -e. A hook that has either form, as a whole line, is already done.
HOOK_LINE_STAGED='.gauntlet/bin/gauntlet check --staged  # gauntlet'
HOOK_GATE_STAGED='.gauntlet/bin/gauntlet check --staged || exit $?  # gauntlet'
HOOK_LINE_CI='.gauntlet/bin/gauntlet check --ci  # gauntlet'
HOOK_GATE_CI='.gauntlet/bin/gauntlet check --ci || exit $?  # gauntlet'

# The command strings that show a config already runs the gate.
GAUNTLET_CMD_STAGED='.gauntlet/bin/gauntlet check --staged'
GAUNTLET_CMD_CI='.gauntlet/bin/gauntlet check --ci'

# shellcheck disable=SC2016 # the awk program reads $0; it is not shell text to expand
# The edit of one hook file, run by awk over the file. Its exit status says what to
# do: 0 writes the new content; 3 prints the plain line (the file is one we must not
# edit: a non-shell interpreter, CRLF, or a nested early exit); 4 prints the gate
# form to place before the final exit (a trailing exit with an argument). Written
# content: an empty file gets the shebang and the plain line; a trailing exit or exec
# (the last line that is not blank or a comment) gets the gate form before it;
# anything else gets the plain line at the end.
#
# Known ceiling: an early exit reached through a function call as the last line
# (`main "$@"`, with `exit 0` inside main) is not seen; the closer test below looks
# only at the last code line, and `main "$@"` is not a closer.
HOOK_EDIT_AWK='
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
# strip_comment: the code before a comment. A comment starts a line, or follows a
# blank; a # inside a word is not a comment.
function strip_comment(s) {
  sub(/^#.*$/, "", s)
  sub(/[ \t]#.*$/, "", s)
  return s
}
# bare_exit: true when s holds an exit as a command word whose argument is not a
# non-zero literal: no argument, exit 0, or any argument that is not a literal.
function bare_exit(s,   delim, tail, tok) {
  s = " " s
  while (match(s, /[ \t;&|({]exit([ \t;&|)}]|$)/)) {
    delim = substr(s, RSTART + RLENGTH - 1, 1)
    tail = substr(s, RSTART + RLENGTH)
    tok = ""
    if (delim == " " || delim == "\t") {
      sub(/^[ \t]+/, "", tail)
      tok = tail
      sub(/[ \t;&|)}].*$/, "", tok)
    }
    if (tok !~ /^[1-9][0-9]*$/) return 1
    s = tail
  }
  return 0
}
{
  text[NR] = $0
  if (index($0, "\r") > 0) crlf = 1
}
END {
  if (NR == 0) {
    print "#!/usr/bin/env sh"
    print ENVIRON["LINE"]
    exit 0
  }
  if (crlf) exit 3
  if (substr(text[1], 1, 2) == "#!" && !is_shell(interpreter(text[1]))) exit 3
  last = 0
  for (i = NR; i >= 1 && last == 0; i--) {
    t = text[i]
    gsub(/^[ \t]+|[ \t]+$/, "", t)
    if (t != "" && substr(t, 1, 1) != "#") last = i
  }
  if (last > 0) {
    # A closer ends the last code line (a one-line `if ...; fi` included), with an
    # early exit anywhere: the gate written after it could never run, so the hook is
    # printed, not edited.
    t = strip_comment(text[last])
    gsub(/^[ \t]+|[ \t]+$/, "", t)
    if (t ~ /(^|[ \t;&|(])(fi|done|esac|\})[ \t;]*$/) {
      for (j = 1; j <= NR; j++) if (bare_exit(strip_comment(text[j]))) exit 3
    }
  }
  at = NR + 1
  gate = 0
  if (last > 0) {
    t = text[last]
    gsub(/^[ \t]+|[ \t]+$/, "", t)
    n = split(t, seg, /[;&|]/)
    for (k = 1; k <= n; k++) {
      s = seg[k]
      gsub(/^[ \t]+|[ \t]+$/, "", s)
      if (s !~ /^(exit|exec)([ \t;]|$)/) continue
      if (substr(s, 1, 4) == "exit") {
        rest = substr(s, 5)
        sub(/[ \t]+#.*$/, "", rest)
        gsub(/^[ \t]+|[ \t]+$/, "", rest)
        if (rest != "" && rest !~ /^[0-9]+$/) exit 4
      }
      gate = 1
    }
    if (gate) at = last
  }
  for (i = 1; i <= NR; i++) {
    if (i == at) {
      if (gate) { print ENVIRON["GATE"] } else { print ENVIRON["LINE"] }
    }
    print text[i]
  }
  if (at > NR) print ENVIRON["LINE"]
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
# .gauntlet/, from the repo root. The copy is made first, as .bin.new and .lib.new,
# and only a complete copy goes on: the old runner is moved aside, the new one moved
# in, and any failure moves the old one back (swap_runner). When <source> is the
# vendored copy itself (the same directory, through any symlink), nothing is copied.
vendor_runner() {
  local leftover
  if [ -d .gauntlet ] && [ "$1" = "$(cd .gauntlet && pwd -P)" ]; then
    printf 'runner already vendored in .gauntlet/\n'
    return 0
  fi
  mkdir -p .gauntlet || die "cannot create .gauntlet"
  for leftover in bin.new lib.new; do
    if [ -e ".gauntlet/.$leftover" ]; then
      die "an earlier install left .gauntlet/.$leftover behind; move it away and install again"
    fi
  done
  for leftover in bin lib; do
    if [ -e ".gauntlet/.$leftover.old" ]; then
      if [ ! -e ".gauntlet/$leftover" ]; then
        die "an earlier install left .gauntlet/.$leftover.old and no .gauntlet/$leftover; restore it by hand"
      fi
      discard_dirs ".gauntlet/.$leftover.old"
    fi
  done
  if ! cp -R "$1/bin" .gauntlet/.bin.new || ! cp -R "$1/lib" .gauntlet/.lib.new \
    || ! chmod -R u+w .gauntlet/.bin.new .gauntlet/.lib.new \
    || ! chmod +x .gauntlet/.bin.new/gauntlet; then
    discard_dirs .gauntlet/.bin.new .gauntlet/.lib.new
    die "cannot copy the runner into .gauntlet/"
  fi
  swap_runner
  printf 'vendored runner to .gauntlet/\n'
}

# swap_runner: move the old runner aside and the new one in, bin then lib. A failed
# move rolls back what was moved. The new copies are dropped only once the old
# runner is back; the old copies are dropped only after every move succeeded.
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

# swap_failed <bin-aside> <bin-in> <lib-aside> <lib-in> <message>: undo the moves
# that were made, in reverse, then fail. The new copies are dropped only when the
# old runner is back; otherwise they stay, with the old runner, and say so.
swap_failed() {
  local ok=0
  if [ "$4" = 1 ]; then mv .gauntlet/lib .gauntlet/.lib.new || ok=1; fi
  if [ "$3" = 1 ]; then mv .gauntlet/.lib.old .gauntlet/lib || ok=1; fi
  if [ "$2" = 1 ]; then mv .gauntlet/bin .gauntlet/.bin.new || ok=1; fi
  if [ "$1" = 1 ]; then mv .gauntlet/.bin.old .gauntlet/bin || ok=1; fi
  if [ "$ok" -ne 0 ]; then
    die "$5; the rollback failed, so .gauntlet/.bin.old and .gauntlet/.lib.old hold the old runner"
  fi
  discard_dirs .gauntlet/.bin.new .gauntlet/.lib.new
  die "$5; the old runner is back"
}

# discard_dirs <dir>...: remove directories this install made. Their modes are made
# writable first, so a read-only source copy can still be removed, and a failure
# here never aborts the caller (the message it reports comes after).
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

# install-hooks: add the gauntlet lines to the project's hooks, from the repo root.
# husky's directory gets them. A config owned by lefthook, prek or another hook
# manager is printed, not edited. Any other hooks directory gets them when it is
# inside the repo or the git dir; a shared one outside them is printed only.
install_hooks() {
  local root hooks_path husky git_hooks git_common hooks
  root=$(repo_root)
  cd "$root" || die "cannot enter $root"
  HOOKS_ROOT=$(physical_path "$root")
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
    git_hooks=$(git rev-parse --git-path hooks) || die "cannot find the hooks directory"
    hooks=$(abs_path "$git_hooks")
  fi
  git_common=$(git rev-parse --git-common-dir) || die "cannot find the git directory"
  if owned_path "$hooks" "$(abs_path "$git_common")"; then
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

# print_hook_pair <dir>: print the two lines for <dir>, which is not ours to edit.
print_hook_pair() {
  print_only "$1/pre-commit" "$HOOK_LINE_STAGED"
  print_only "$1/pre-push" "$HOOK_LINE_CI"
}

# add_hook_line <file> <line> <gate>: make <file> run the gate once. <line> is the
# plain form and <gate> the `|| exit $?` form. A file that already has either, as
# a whole line, is left alone. A file we must not edit is printed instead; see
# HOOK_EDIT_AWK and has_nul. A missing file is created executable, with the shebang.
# An existing file keeps its mode, and is warned about when it is not executable.
add_hook_line() {
  local file=$1 line=$2 gate=$3 tmp status=0
  if [ -e "$file" ] && { grep -Fxq -- "$line" "$file" 2>/dev/null || grep -Fxq -- "$gate" "$file" 2>/dev/null; }; then
    printf 'already present in %s\n' "$(display_path "$file")"
    warn_if_not_executable "$file"
    return 0
  fi
  if [ -L "$file" ] && [ ! -e "$file" ]; then
    print_only "$file" "$line"
    return 0
  fi
  if [ ! -e "$file" ]; then
    printf '#!/usr/bin/env sh\n%s\n' "$line" > "$file" || die "cannot create $file"
    chmod +x "$file" || die "cannot make $file executable"
    printf 'created %s\n' "$(display_path "$file")"
    return 0
  fi
  if [ -L "$file" ] && ! inside_root "$(resolve_link "$file")"; then
    print_only "$file" "$line"
    warn_if_not_executable "$file"
    return 0
  fi
  if has_nul "$file"; then
    print_only "$file" "$line"
    warn_if_not_executable "$file"
    return 0
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/gauntlet-hook.XXXXXX") || die "cannot create a temp file"
  LINE="$line" GATE="$gate" awk "$HOOK_EDIT_AWK" "$file" > "$tmp" || status=$?
  case "$status" in
    0) ;;
    3) rm -f "$tmp"; print_only "$file" "$line"; warn_if_not_executable "$file"; return 0 ;;
    4) rm -f "$tmp"; print_gate_only "$file" "$gate"; warn_if_not_executable "$file"; return 0 ;;
    *) rm -f "$tmp"; die "cannot read $file" ;;
  esac
  # Writing over the file keeps its mode; moving the temp file would not.
  cat "$tmp" > "$file" || { rm -f "$tmp"; die "cannot write $file"; }
  rm -f "$tmp"
  printf 'added gauntlet line to %s\n' "$(display_path "$file")"
  warn_if_not_executable "$file"
}

# has_nul <file>: succeed when <file> holds a NUL byte, which the awk edit is not
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

# print_only <file> <line>: say what to add to a hook we will not edit.
print_only() {
  printf 'ACTION NEEDED: add to %s:\n%s\n' "$(display_path "$1")" "$2"
}

# print_gate_only <file> <gate>: a trailing exit with an argument. The gate goes
# before that exit, so it runs before the exit can end the hook.
print_gate_only() {
  printf 'ACTION NEEDED: add to %s:\n%s\n  (place it before the final exit)\n' "$(display_path "$1")" "$2"
}

# warn_if_not_executable <file>: git ignores a hook without the exec bit. Never
# changes the mode of a file that already exists.
warn_if_not_executable() {
  if [ ! -x "$1" ]; then
    printf 'warning: %s is not executable; git will ignore it\n' "$(display_path "$1")" >&2
  fi
}

# husky_dir <hooks-path>: print the husky directory a core.hooksPath names, when
# the path ends in /.husky or /.husky/_ and lies inside the repo root. The
# trailing /_ is dropped, so nothing is ever written into a _ directory. Prints
# nothing and fails otherwise.
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

# print_config_snippets: for each lefthook, prek, or TOML or JSON config in the
# repo root, print the lines to add, or say it is already configured. Succeeds
# when at least one config exists, so the hooks are left to that config.
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

# abs_path <path>: the absolute, normalised, physical form of <path>. A relative
# path is taken from the repo root. A path that does not exist keeps its
# normalised spelling.
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

# owned_path <path> <git-common-dir>: succeed when <path> is inside the repo root
# or inside the common git dir (a linked worktree or submodule keeps its hooks
# there). Anything else is someone else's directory.
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
