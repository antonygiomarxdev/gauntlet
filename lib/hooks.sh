# shellcheck shell=bash
# install and install-hooks: vendor the runner into .gauntlet/ and add one line
# to each existing hook, never taking the hooks over (ADR-0006). Sourced, never
# executed. Bash 3.2 compatible; awk, git and coreutils only. Needs core.sh.

# The two lines install-hooks adds. A hook that already has one, as a whole
# line, gets nothing more.
HOOK_LINE_STAGED='.gauntlet/bin/gauntlet check --staged  # gauntlet'
HOOK_LINE_CI='.gauntlet/bin/gauntlet check --ci  # gauntlet'

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
# running script. bin/gauntlet sits one level below it.
install_source() {
  (cd "$(dirname "$0")/.." && pwd -P)
}

# vendor_runner <source>: copy bin/ and lib/ of the checkout <source> into
# .gauntlet/, from the repo root. Old files go first, so a file removed from the
# runner does not stay. When <source> is the vendored copy itself, there is
# nothing to copy.
vendor_runner() {
  if [ -d .gauntlet ] && [ "$1" = "$(cd .gauntlet && pwd -P)" ]; then
    printf 'runner already vendored in .gauntlet/\n'
    return 0
  fi
  mkdir -p .gauntlet || die "cannot create .gauntlet"
  rm -rf .gauntlet/bin .gauntlet/lib || die "cannot remove the old runner in .gauntlet/"
  cp -R "$1/bin" .gauntlet/bin || die "cannot copy bin/ into .gauntlet/"
  cp -R "$1/lib" .gauntlet/lib || die "cannot copy lib/ into .gauntlet/"
  chmod +x .gauntlet/bin/gauntlet || die "cannot make .gauntlet/bin/gauntlet executable"
  printf 'vendored runner to .gauntlet/\n'
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

# install-hooks: add the gauntlet lines to the project's hooks, from the repo
# root. husky gets them in .husky/. lefthook and prek configs are YAML, so the
# snippet is printed instead. Any other core.hooksPath and the default hooks
# directory get them there.
install_hooks() {
  local root hooks_path hooks
  root=$(repo_root)
  cd "$root" || die "cannot enter $root"
  if [ ! -f .gauntlet/bin/gauntlet ]; then
    printf 'gauntlet: warning: .gauntlet/bin/gauntlet is missing; run gauntlet install\n' >&2
  fi
  hooks_path=$(git config --get core.hooksPath) || hooks_path=
  if is_husky_path "$hooks_path"; then
    mkdir -p .husky || die "cannot create .husky"
    add_hook_line .husky/pre-commit "$HOOK_LINE_STAGED"
    add_hook_line .husky/pre-push "$HOOK_LINE_CI"
  elif [ -f lefthook.yml ] || [ -f lefthook.yaml ] || [ -f .pre-commit-config.yaml ]; then
    print_yaml_snippets
  else
    hooks=$(git rev-parse --git-path hooks) || die "cannot find the hooks directory"
    mkdir -p "$hooks" || die "cannot create $hooks"
    add_hook_line "$hooks/pre-commit" "$HOOK_LINE_STAGED"
    add_hook_line "$hooks/pre-push" "$HOOK_LINE_CI"
  fi
}

# is_husky_path <hooks-path>: true when core.hooksPath is husky's .husky or
# .husky/_, with an optional trailing slash, relative or absolute.
is_husky_path() {
  local p=${1%/}
  case "$p" in
    .husky|.husky/_|/*/.husky|/*/.husky/_) return 0 ;;
    *) return 1 ;;
  esac
}

# add_hook_line <file> <line>: make <file> run <line> once. A missing file is
# created as an sh script and made executable. An existing file keeps its mode
# and its content; <line> goes in before a last line that starts with exit, so
# the gate runs before the hook returns (HOOK-AC8).
add_hook_line() {
  local file=$1 line=$2 tmp status=0
  if [ -f "$file" ] && grep -Fxq -- "$line" "$file"; then
    printf 'already present in %s\n' "$file"
    return 0
  fi
  if [ ! -e "$file" ]; then
    printf '#!/usr/bin/env sh\n%s\n' "$line" > "$file" || die "cannot create $file"
    chmod +x "$file" || die "cannot make $file executable"
    printf 'created %s\n' "$file"
    return 0
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/gauntlet-hook.XXXXXX") || die "cannot create a temp file"
  LINE="$line" awk '
    { text[NR] = $0 }
    END {
      at = NR + 1
      for (i = NR; i >= 1; i--) {
        t = text[i]
        gsub(/^[ \t]+|[ \t]+$/, "", t)
        if (t == "") continue
        if (substr(t, 1, 4) == "exit") at = i
        break
      }
      for (i = 1; i <= NR; i++) {
        if (i == at) print ENVIRON["LINE"]
        print text[i]
      }
      if (at > NR) print ENVIRON["LINE"]
    }
  ' "$file" > "$tmp" || status=$?
  if [ "$status" -ne 0 ]; then
    rm -f "$tmp"
    die "cannot read $file"
  fi
  # Writing over the file keeps its mode; moving the temp file would not.
  cat "$tmp" > "$file" || { rm -f "$tmp"; die "cannot write $file"; }
  rm -f "$tmp"
  printf 'added gauntlet line to %s\n' "$file"
}

# print_yaml_snippets: print the lines to add to each YAML hook config in the
# repo root. Nothing is edited.
print_yaml_snippets() {
  if [ -f lefthook.yml ]; then
    printf 'ACTION NEEDED: add to lefthook.yml:\n'
    lefthook_snippet
  fi
  if [ -f lefthook.yaml ]; then
    printf 'ACTION NEEDED: add to lefthook.yaml:\n'
    lefthook_snippet
  fi
  if [ -f .pre-commit-config.yaml ]; then
    printf 'ACTION NEEDED: add to .pre-commit-config.yaml:\n'
    prek_snippet
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
