# shellcheck shell=bash
# shellcheck disable=SC2153 # ROOT, G and STATUS are set by test/lib.sh
# Tests for install and install-hooks. The runner is vendored without ever
# leaving .gauntlet/ half-written. An editable hook gets the gate on the line after its
# shebang (R26); otherwise the gate line is printed. Husky, the
# YAML and TOML/JSON configs, custom hooks paths and linked worktrees are each
# handled, and nothing outside the hooks and the state files is ever changed.
# Each test runs in a fresh repo under $TMP.

HOOK_TEST_STAGED='.gauntlet/bin/gauntlet check --staged  # gauntlet'
HOOK_TEST_CI='.gauntlet/bin/gauntlet check --ci --pre-push  # gauntlet'
HOOK_TEST_GATE_STAGED='.gauntlet/bin/gauntlet check --staged || exit $?  # gauntlet'
HOOK_TEST_GATE_CI='.gauntlet/bin/gauntlet check --ci --pre-push || exit $?  # gauntlet'

# hooks_repo <dir>: a git repo at <dir> on main with one commit and no gauntlet
# state, then cd into it. <dir> may contain spaces.
hooks_repo() {
  must mkdir -p "$1"
  must cd "$1"
  must git init -q .
  must git symbolic-ref HEAD refs/heads/main
  must git config user.name "Test User"
  must git config user.email "test@example.com"
  must git config commit.gpgsign false
  printf 'hello\n' > README.md
  must git add README.md
  must git commit -q -m init
}

# hooks_sum <path>...: one cksum line per file under the paths, sorted. Equal
# output means the same files with the same bytes.
hooks_sum() {
  find "$@" -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
    cksum "$f"
  done
}

# hooks_expect <file> <content>: fail unless <file> is exactly <content>, byte for byte.
hooks_expect() {
  printf '%s' "$2" > "$TMP/expect" || fail "cannot write the expectation"
  cmp -s "$TMP/expect" "$1" || fail "$1 differs from the expected bytes; it holds: $(cat "$1")"
}

# hooks_lines <line> <file>: how many lines of <file> are exactly <line>.
hooks_lines() {
  grep -Fxc -- "$1" "$2" || true
}

# hooks_as_root: root reads files it has no read bit for, so the permission tests
# cannot fail there and are skipped.
hooks_as_root() {
  [ "$(id -u)" -eq 0 ]
}

# hooks_vendor: put the runner in .gauntlet/ the way install does, without touching a hook.
hooks_vendor() {
  must mkdir -p .gauntlet
  must cp -R "$ROOT/bin" "$ROOT/lib" .gauntlet/
}

# hooks_parallel <n> <cmd...>: start <n> copies of the command at the same moment and wait
# for all of them; fail unless each exits 0. The copies spin on a flag file so that they leave
# the gate together (a plain loop of & starts them far enough apart to hide a race). Each
# one's output is in $TMP/par.<i>.
hooks_parallel() {
  local n=$1 i pids='' p failed='' k=0
  shift
  rm -f "$TMP/go"
  for i in $(seq 1 "$n"); do
    (
      while [ ! -e "$TMP/go" ]; do :; done
      exec "$@"
    ) > "$TMP/par.$i" 2>&1 &
    pids="$pids $!"
  done
  : > "$TMP/go"
  for p in $pids; do
    k=$((k + 1))
    wait "$p" || failed="$failed $k"
  done
  [ -z "$failed" ] || fail "runs that failed:$failed: $(cat "$TMP"/par.*)"
}

# hooks_wait_for <file> <text>: wait until <file> holds <text>, up to ten seconds. The poll
# is a short sleep where sleep takes a fraction and a second where it does not; the
# test's result never depends on how long it ran.
hooks_wait_for() {
  local i
  for i in $(seq 1 100); do
    if grep -Fq -- "$2" "$1" 2> /dev/null; then return 0; fi
    sleep 0.1 2> /dev/null || sleep 1
  done
  fail "$1 never held [$2]: $(cat "$1" 2> /dev/null)"
}

test_plain_repo_gets_hooks() {
  hooks_repo "$TMP/repo"
  run "$G" install
  assert_eq 0 "$STATUS" "install"
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_STAGED" .git/hooks/pre-commit)" "pre-commit line"
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_CI" .git/hooks/pre-push)" "pre-push line"
}

test_existing_hook_keeps_content() {
  hooks_repo "$TMP/repo"
  printf '#!/bin/sh\necho one\necho two\n' > .git/hooks/pre-commit
  local want=$'#!/bin/sh\n'"$HOOK_TEST_GATE_STAGED"$'\necho one\necho two\n'
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "first install-hooks"
  hooks_expect .git/hooks/pre-commit "$want"
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "second install-hooks"
  assert_contains "$OUT" "already present in .git/hooks/pre-commit"
  hooks_expect .git/hooks/pre-commit "$want"
}

# A line that merely ends in "# gauntlet" is not the gauntlet line: the gate
# line is still added, and the other line stays once.
test_presence_is_the_whole_line() {
  hooks_repo "$TMP/repo"
  printf '#!/bin/sh\necho tidy  # gauntlet\n' > .git/hooks/pre-commit
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks"
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_GATE_STAGED" .git/hooks/pre-commit)" "the gate line was added"
  assert_eq 1 "$(hooks_lines "echo tidy  # gauntlet" .git/hooks/pre-commit)" "the other line is kept once"
}

# Either form of the line counts as present, per hook.
test_presence_accepts_either_form() {
  hooks_repo "$TMP/repo"
  printf '#!/bin/sh\necho one\n%s\nexit 0\n' "$HOOK_TEST_GATE_STAGED" > .git/hooks/pre-commit
  printf '#!/bin/sh\necho two\n%s\n' "$HOOK_TEST_CI" > .git/hooks/pre-push
  chmod 755 .git/hooks/pre-commit .git/hooks/pre-push
  local before
  before=$(hooks_sum .git/hooks/pre-commit .git/hooks/pre-push)
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks"
  assert_contains "$OUT" "already present in .git/hooks/pre-commit"
  assert_contains "$OUT" "already present in .git/hooks/pre-push"
  assert_eq "$before" "$(hooks_sum .git/hooks/pre-commit .git/hooks/pre-push)" "neither hook changed"
}

# The gate goes first: on the line after the shebang, and the hook's own lines follow
# unchanged, including a trailing exit.
test_insert_before_exit() {
  hooks_repo "$TMP/repo"
  printf '#!/bin/sh\necho one\n  exit 0   \n\n' > .git/hooks/pre-commit
  chmod 755 .git/hooks/pre-commit
  local want=$'#!/bin/sh\n'"$HOOK_TEST_GATE_STAGED"$'\necho one\n  exit 0   \n\n'
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "first install-hooks"
  hooks_expect .git/hooks/pre-commit "$want"
  if [ ! -x .git/hooks/pre-commit ]; then fail "the hook lost its exec bit"; fi
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "second install-hooks"
  assert_contains "$OUT" "already present in .git/hooks/pre-commit"
  hooks_expect .git/hooks/pre-commit "$want"
}

test_insert_before_exit_without_newline() {
  hooks_repo "$TMP/repo"
  printf '#!/bin/sh\necho two\nexit 0' > .git/hooks/pre-push
  chmod 644 .git/hooks/pre-push
  local want=$'#!/bin/sh\n'"$HOOK_TEST_GATE_CI"$'\necho two\nexit 0'
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "first install-hooks"
  hooks_expect .git/hooks/pre-push "$want"
  if [ -x .git/hooks/pre-push ]; then fail "an existing hook gained the exec bit"; fi
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "second install-hooks"
  hooks_expect .git/hooks/pre-push "$want"
}







# Non-shell interpreters are never edited; only the line is printed.
test_nonshell_shebang_is_print_only() {
  hooks_repo "$TMP/repo"
  local shebang before
  for shebang in '#!/usr/bin/env python3' '#!/usr/bin/env -S node --no-warnings' '#!/usr/bin/perl'; do
    printf '%s\nprint "hi";\n' "$shebang" > .git/hooks/pre-commit
    rm -f .git/hooks/pre-push
    before=$(hooks_sum .git/hooks/pre-commit)
    run "$G" install-hooks
    assert_eq 0 "$STATUS" "install-hooks with [$shebang]"
    assert_eq "$before" "$(hooks_sum .git/hooks/pre-commit)" "[$shebang] is not edited"
    assert_contains "$OUT" "ACTION NEEDED: add to .git/hooks/pre-commit:"
    assert_contains "$OUT" "$HOOK_TEST_GATE_STAGED"
    assert_contains "$OUT" "as the first command, after the shebang"
  done
}

# sh, bash, dash, zsh, ksh and ash are shell, after env and -S; no shebang is sh.
test_shell_shebangs_are_edited() {
  hooks_repo "$TMP/repo"
  local sh
  for sh in sh bash dash zsh ksh ash; do
    printf '#!/usr/bin/env %s\necho x\n' "$sh" > .git/hooks/pre-commit
    rm -f .git/hooks/pre-push
    run "$G" install-hooks
    assert_eq 1 "$(hooks_lines "$HOOK_TEST_GATE_STAGED" .git/hooks/pre-commit)" "[$sh] is edited"
  done
  printf '#!/usr/bin/env -S bash -e\necho x\n' > .git/hooks/pre-commit
  rm -f .git/hooks/pre-push
  run "$G" install-hooks
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_GATE_STAGED" .git/hooks/pre-commit)" "env -S bash is edited"
  printf 'echo x\n' > .git/hooks/pre-commit
  rm -f .git/hooks/pre-push
  run "$G" install-hooks
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_GATE_STAGED" .git/hooks/pre-commit)" "no shebang is edited"
}

# A CRLF hook is not edited: the line would not match and the file would be mixed.
test_crlf_hook_is_print_only() {
  hooks_repo "$TMP/repo"
  local body before
  # A CRLF shebang and a CRLF body; then an LF shebang with a CRLF body only, which
  # the shebang rule alone would not catch.
  for body in '#!/bin/sh\r\necho x\r\n' '#!/bin/sh\necho x\r\n'; do
    printf '%b' "$body" > .git/hooks/pre-commit
    chmod 755 .git/hooks/pre-commit
    before=$(hooks_sum .git/hooks/pre-commit)
    run "$G" install-hooks
    assert_eq 0 "$STATUS" "install-hooks"
    assert_eq "$before" "$(hooks_sum .git/hooks/pre-commit)" "the CRLF hook is not edited"
    assert_contains "$OUT" "ACTION NEEDED: add to .git/hooks/pre-commit:"
  done
}

# A dangling symlink is printed, and its target is not created.
test_dangling_symlink_is_print_only() {
  hooks_repo "$TMP/repo"
  must ln -s "$TMP/nowhere" .git/hooks/pre-commit
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks"
  if [ -e "$TMP/nowhere" ]; then fail "the dangling link's target was created"; fi
  if [ ! -L .git/hooks/pre-commit ]; then fail "the dangling link was replaced"; fi
  assert_contains "$OUT" "ACTION NEEDED: add to .git/hooks/pre-commit:"
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_CI" .git/hooks/pre-push)" "pre-push is still created"
}

# An existing hook that is empty gets the shebang and the line; its mode is kept.
test_empty_existing_hook_gets_shebang_and_line() {
  hooks_repo "$TMP/repo"
  : > .git/hooks/pre-commit
  chmod 644 .git/hooks/pre-commit
  "$G" install-hooks > "$TMP/out" 2> "$TMP/err" || fail "install-hooks failed"
  hooks_expect .git/hooks/pre-commit $'#!/usr/bin/env sh\n'"$HOOK_TEST_STAGED"$'\n'
  if [ -x .git/hooks/pre-commit ]; then fail "the mode of an existing hook was changed"; fi
  assert_contains "$(cat "$TMP/err")" "warning: .git/hooks/pre-commit is not executable; git will ignore it"
}

# An existing hook that is not executable is never chmod-ed; a warning says so,
# after the added and the already-present branches alike.
test_warns_when_hook_not_executable() {
  hooks_repo "$TMP/repo"
  printf '#!/bin/sh\necho x\n' > .git/hooks/pre-push
  chmod 644 .git/hooks/pre-push
  "$G" install-hooks > "$TMP/out" 2> "$TMP/err" || fail "first install-hooks failed"
  assert_contains "$(cat "$TMP/err")" "warning: .git/hooks/pre-push is not executable; git will ignore it"
  if [ -x .git/hooks/pre-push ]; then fail "install-hooks changed the mode of an existing hook"; fi
  "$G" install-hooks > "$TMP/out" 2> "$TMP/err" || fail "second install-hooks failed"
  assert_contains "$(cat "$TMP/out")" "already present in .git/hooks/pre-push"
  assert_contains "$(cat "$TMP/err")" "warning: .git/hooks/pre-push is not executable; git will ignore it"
}

test_husky_v9_layout() {
  hooks_repo "$TMP/repo"
  must mkdir -p .husky/_
  printf 'husky stub\n' > .husky/_/husky.sh
  # shellcheck disable=SC2016 # the hook is shell text; its $0 is not ours to expand
  printf '#!/usr/bin/env sh\n. "$(dirname -- "$0")/_/husky.sh"\n' > .husky/pre-commit
  must git config core.hooksPath .husky/_
  local shim
  shim=$(hooks_sum .husky/_)
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks"
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_GATE_STAGED" .husky/pre-commit)" "pre-commit line"
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_CI" .husky/pre-push)" "pre-push line"
  assert_eq "$shim" "$(hooks_sum .husky/_)" "husky's own directory is untouched"
  assert_eq ".husky/_" "$(git config --get core.hooksPath)" "hooksPath"
  if [ -e .git/hooks/pre-commit ]; then fail "the hooks went to .git/hooks"; fi
}

test_husky_v8_layout() {
  hooks_repo "$TMP/repo"
  must mkdir -p .husky
  printf '#!/bin/sh\nnpm test\n' > .husky/pre-commit
  must git config core.hooksPath .husky
  local want=$'#!/bin/sh\n'"$HOOK_TEST_GATE_STAGED"$'\nnpm test\n'
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks"
  hooks_expect .husky/pre-commit "$want"
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_CI" .husky/pre-push)" "pre-push line"
  if [ -e .husky/_ ]; then fail "the v8 layout got a .husky/_ directory"; fi
  # The same directory spelled with a trailing slash and as an absolute path.
  must git config core.hooksPath "$TMP/repo/.husky/"
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks with an absolute hooksPath"
  assert_contains "$OUT" "already present in .husky/pre-commit"
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_GATE_STAGED" .husky/pre-commit)" "one pre-commit line"
}

test_husky_creates_missing_directory() {
  hooks_repo "$TMP/repo"
  must git config core.hooksPath .husky
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks"
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_STAGED" .husky/pre-commit)" "pre-commit line"
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_CI" .husky/pre-push)" "pre-push line"
  assert_eq "#!/usr/bin/env sh" "$(head -n 1 .husky/pre-push)" "created hook starts with the shebang"
}

# Other spellings of the husky path resolve to the same directory, and nothing is
# written into a _ directory.
test_husky_path_forms() {
  local pair dir n=0
  for pair in './.husky/_:.husky' '.husky//:.husky' 'packages/app/.husky/_:packages/app/.husky'; do
    n=$((n + 1))
    hooks_repo "$TMP/repo $n"
    must git config core.hooksPath "${pair%%:*}"
    dir=${pair#*:}
    must mkdir -p "$dir/_"
    run "$G" install-hooks
    assert_eq 0 "$STATUS" "install-hooks with [${pair%%:*}]"
    assert_eq 1 "$(hooks_lines "$HOOK_TEST_STAGED" "$dir/pre-commit")" "[${pair%%:*}] pre-commit line"
    assert_eq 1 "$(hooks_lines "$HOOK_TEST_CI" "$dir/pre-push")" "[${pair%%:*}] pre-push line"
    if [ -e "$dir/_/pre-commit" ] || [ -e "$dir/_/pre-push" ]; then
      fail "[${pair%%:*}] wrote into the _ directory"
    fi
    if [ -e .git/hooks/pre-commit ]; then fail "[${pair%%:*}] wrote to .git/hooks"; fi
  done
}

# An absolute husky path inside the root resolves to the same directory.
test_husky_absolute_path_inside_root() {
  hooks_repo "$TMP/repo"
  must mkdir -p .husky/_
  printf 'husky stub\n' > .husky/_/husky.sh
  local shim
  shim=$(hooks_sum .husky/_)
  must git config core.hooksPath "$TMP/repo/.husky/_"
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks"
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_STAGED" .husky/pre-commit)" "pre-commit line"
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_CI" .husky/pre-push)" "pre-push line"
  assert_eq "$shim" "$(hooks_sum .husky/_)" "the _ directory is untouched"
  if [ -e .git/hooks/pre-commit ]; then fail "the hooks went to .git/hooks"; fi
}

test_lefthook_prints_snippet_no_edit() {
  hooks_repo "$TMP/repo"
  printf 'pre-commit:\n  parallel: true\n' > lefthook.yml
  local config hooks
  config=$(hooks_sum lefthook.yml)
  hooks=$(hooks_sum .git/hooks)
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks"
  assert_contains "$OUT" "ACTION NEEDED: add to lefthook.yml:"
  assert_contains "$OUT" "run: .gauntlet/bin/gauntlet check --staged"
  assert_contains "$OUT" "run: .gauntlet/bin/gauntlet check --ci --pre-push"
  assert_contains "$OUT" "use_stdin: true"
  assert_eq "$config" "$(hooks_sum lefthook.yml)" "lefthook.yml is unchanged"
  assert_eq "$hooks" "$(hooks_sum .git/hooks)" "no hook was written"
}

test_lefthook_beats_plain_hooks_dir() {
  hooks_repo "$TMP/repo"
  printf 'pre-commit:\n  parallel: true\n' > lefthook.yaml
  printf '#!/bin/sh\necho plain\n' > .git/hooks/pre-commit
  local config hooks
  config=$(hooks_sum lefthook.yaml)
  hooks=$(hooks_sum .git/hooks)
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks"
  assert_contains "$OUT" "ACTION NEEDED: add to lefthook.yaml:"
  assert_eq "$hooks" "$(hooks_sum .git/hooks)" ".git/hooks stays untouched"
  assert_eq "$config" "$(hooks_sum lefthook.yaml)" "lefthook.yaml is unchanged"
}

test_prek_prints_snippet_no_edit() {
  hooks_repo "$TMP/repo"
  printf 'repos: []\n' > .pre-commit-config.yaml
  local config hooks
  config=$(hooks_sum .pre-commit-config.yaml)
  hooks=$(hooks_sum .git/hooks)
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks"
  assert_contains "$OUT" "ACTION NEEDED: add to .pre-commit-config.yaml:"
  assert_contains "$OUT" "entry: .gauntlet/bin/gauntlet check --staged"
  assert_contains "$OUT" "entry: .gauntlet/bin/gauntlet check --ci --pre-push"
  assert_eq "$config" "$(hooks_sum .pre-commit-config.yaml)" "the config is unchanged"
  assert_eq "$hooks" "$(hooks_sum .git/hooks)" "no hook was written"
}

# Once the snippet is in the config, a second install says so and changes nothing.
test_already_configured_on_second_install() {
  hooks_repo "$TMP/repo"
  printf 'pre-commit:\n  parallel: true\n' > lefthook.yml
  printf 'repos: []\n' > .pre-commit-config.yaml
  run "$G" install-hooks
  assert_contains "$OUT" "ACTION NEEDED: add to lefthook.yml:"
  assert_contains "$OUT" "ACTION NEEDED: add to .pre-commit-config.yaml:"
  cat > lefthook.yml <<'YAML'
pre-commit:
  commands:
    gauntlet:
      run: .gauntlet/bin/gauntlet check --staged
pre-push:
  commands:
    gauntlet:
      run: .gauntlet/bin/gauntlet check --ci --pre-push
      use_stdin: true
YAML
  cat > .pre-commit-config.yaml <<'YAML'
- repo: local
  hooks:
    - id: gauntlet
      entry: .gauntlet/bin/gauntlet check --staged
    - id: gauntlet-ci
      entry: .gauntlet/bin/gauntlet check --ci --pre-push
YAML
  local config
  config=$(hooks_sum lefthook.yml .pre-commit-config.yaml)
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "second install-hooks"
  assert_contains "$OUT" "already configured in lefthook.yml"
  assert_contains "$OUT" "already configured in .pre-commit-config.yaml"
  assert_not_contains "$OUT" "ACTION NEEDED"
  assert_eq "$config" "$(hooks_sum lefthook.yml .pre-commit-config.yaml)" "the configs are unchanged"
}

# TOML and JSON configs get the generic two-line snippet, with the hook names.
test_json_and_toml_configs_get_generic_snippet() {
  hooks_repo "$TMP/repo"
  printf '{}\n' > lefthook.json
  printf 'skip = []\n' > lefthook.toml
  printf 'x = 1\n' > prek.toml
  local before
  before=$(hooks_sum lefthook.json lefthook.toml prek.toml)
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks"
  assert_contains "$OUT" "ACTION NEEDED: add to lefthook.json:"
  assert_contains "$OUT" "ACTION NEEDED: add to lefthook.toml:"
  assert_contains "$OUT" "ACTION NEEDED: add to prek.toml:"
  assert_contains "$OUT" "pre-commit: .gauntlet/bin/gauntlet check --staged"
  assert_contains "$OUT" "pre-push: .gauntlet/bin/gauntlet check --ci --pre-push"
  assert_eq "$before" "$(hooks_sum lefthook.json lefthook.toml prek.toml)" "the configs are unchanged"
  if [ -e .git/hooks/pre-commit ]; then fail "hooks were written although a config owns them"; fi
}

test_hookspath_never_set() {
  hooks_repo "$TMP/plain"
  local config
  config=$(hooks_sum .git/config)
  run "$G" install
  assert_eq 0 "$STATUS" "install in a plain repo"
  if git config --get core.hooksPath > /dev/null; then fail "install set core.hooksPath"; fi
  assert_eq "$config" "$(hooks_sum .git/config)" "git config is unchanged"
  hooks_repo "$TMP/custom"
  must mkdir -p tools/hooks
  must git config core.hooksPath tools/hooks
  config=$(hooks_sum .git/config)
  run "$G" install
  assert_eq 0 "$STATUS" "install with a custom hooksPath"
  assert_eq "tools/hooks" "$(git config --get core.hooksPath)" "custom hooksPath is kept"
  assert_eq "$config" "$(hooks_sum .git/config)" "git config is unchanged"
}

test_install_vendors_runner() {
  hooks_repo "$TMP/repo"
  must mkdir -p .gauntlet/bin .gauntlet/lib
  must touch .gauntlet/bin/old-runner .gauntlet/lib/stale.sh
  run "$G" install
  assert_eq 0 "$STATUS" "install"
  if [ -e .gauntlet/lib/stale.sh ] || [ -e .gauntlet/bin/old-runner ]; then
    fail "files from an older runner were kept"
  fi
  must cmp "$ROOT/bin/gauntlet" .gauntlet/bin/gauntlet
  must diff -r "$ROOT/lib" .gauntlet/lib
  if [ ! -x .gauntlet/bin/gauntlet ]; then fail "the vendored runner is not executable"; fi
  run .gauntlet/bin/gauntlet --version
  assert_eq 0 "$STATUS" "vendored --version"
  assert_contains "$OUT" "gauntlet "
}

test_install_twice_leaves_tree_identical() {
  hooks_repo "$TMP/repo"
  printf '#!/bin/sh\necho plain\n' > .git/hooks/pre-commit
  run "$G" install
  assert_eq 0 "$STATUS" "first install"
  local tree
  tree=$(hooks_sum .gauntlet .git/hooks)
  run "$G" install
  assert_eq 0 "$STATUS" "second install"
  assert_eq "$tree" "$(hooks_sum .gauntlet .git/hooks)" "tree after the second install"
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_GATE_STAGED" .git/hooks/pre-commit)" "one pre-commit line"
  assert_contains "$OUT" "already present in .git/hooks/pre-push"
}

test_install_keeps_user_state() {
  hooks_repo "$TMP/repo"
  must mkdir -p .gauntlet/rules
  printf 'custom rule\n' > .gauntlet/rules/mine.md
  printf 'touched=on\nbase=main\n' > .gauntlet/config
  printf 'todo\ta.txt\tabc\n' > .gauntlet/baseline.tsv
  printf 'type\ttarget\treason\tdate\tbranch\nwaive\ttodo\tlegacy\t2026-10-01\tmain\n' > .gauntlet/exceptions.tsv
  local state
  state=$(hooks_sum .gauntlet/rules .gauntlet/config .gauntlet/baseline.tsv .gauntlet/exceptions.tsv)
  run "$G" install
  assert_eq 0 "$STATUS" "install"
  assert_eq "$state" "$(hooks_sum .gauntlet/rules .gauntlet/config .gauntlet/baseline.tsv .gauntlet/exceptions.tsv)" "state files"
}

test_install_creates_missing_state() {
  hooks_repo "$TMP/repo"
  run "$G" install
  assert_eq 0 "$STATUS" "install"
  if [ ! -d .gauntlet/rules ]; then fail "rules/ was not created"; fi
  if [ ! -f .gauntlet/baseline.tsv ] || [ -s .gauntlet/baseline.tsv ]; then
    fail "baseline.tsv is not an empty file"
  fi
  hooks_expect .gauntlet/exceptions.tsv $'type\ttarget\treason\tdate\tbranch\n'
  hooks_expect .gauntlet/config $'touched=off\n'
}

test_reinstall_from_vendored_runner() {
  hooks_repo "$TMP/repo"
  run "$G" install
  assert_eq 0 "$STATUS" "install"
  local tree
  tree=$(hooks_sum .gauntlet .git/hooks)
  run .gauntlet/bin/gauntlet install
  assert_eq 0 "$STATUS" "re-install from the vendored runner"
  assert_contains "$OUT" "runner already vendored in .gauntlet/"
  assert_eq "$tree" "$(hooks_sum .gauntlet .git/hooks)" "tree after the re-install"
}

# A re-install through a .gauntlet that is a symlink to the same runner is the
# same directory: nothing is copied over the runner it is running from.
test_reinstall_through_symlinked_gauntlet_dir() {
  hooks_repo "$TMP/repo"
  must mkdir -p "$TMP/shared runner"
  must cp -R "$ROOT/bin" "$ROOT/lib" "$TMP/shared runner/"
  must ln -s "$TMP/shared runner" .gauntlet
  local runner
  runner=$(hooks_sum "$TMP/shared runner/bin" "$TMP/shared runner/lib")
  run .gauntlet/bin/gauntlet install
  assert_eq 0 "$STATUS" "re-install through the symlink"
  assert_contains "$OUT" "runner already vendored in .gauntlet/"
  assert_eq "$runner" "$(hooks_sum "$TMP/shared runner/bin" "$TMP/shared runner/lib")" "the shared runner is untouched"
  run .gauntlet/bin/gauntlet --version
  assert_eq 0 "$STATUS" "vendored --version"
}

test_custom_hookspath_relative() {
  hooks_repo "$TMP/repo"
  must mkdir -p tools/hooks
  printf '#!/bin/sh\necho custom\n' > tools/hooks/pre-commit
  must git config core.hooksPath tools/hooks
  local plain
  plain=$(hooks_sum .git/hooks)
  run "$G" install
  assert_eq 0 "$STATUS" "install"
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_GATE_STAGED" tools/hooks/pre-commit)" "pre-commit line"
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_CI" tools/hooks/pre-push)" "pre-push line"
  assert_eq "$plain" "$(hooks_sum .git/hooks)" ".git/hooks is untouched"
}

test_custom_hookspath_absolute() {
  hooks_repo "$TMP/repo"
  # Absolute, inside the repo, and not there yet: install creates it. (Outside the
  # repo it is someone else's directory; see test_hooks_dir_outside_repo_is_print_only.)
  local dir="$TMP/repo/hook dir"
  must git config core.hooksPath "$dir"
  run "$G" install
  assert_eq 0 "$STATUS" "install"
  if [ ! -d "$dir" ]; then fail "the hooksPath directory was not created"; fi
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_STAGED" "$dir/pre-commit")" "pre-commit line"
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_CI" "$dir/pre-push")" "pre-push line"
  assert_eq "$dir" "$(git config --get core.hooksPath)" "absolute hooksPath is kept"
  if [ -e .git/hooks/pre-commit ]; then fail "the hooks went to .git/hooks"; fi
}

# A hooks directory outside the repo is someone else's: printed, never edited.
test_hooks_dir_outside_repo_is_print_only() {
  hooks_repo "$TMP/repo"
  must mkdir -p "$TMP/shared hooks"
  printf '#!/bin/sh\necho shared\n' > "$TMP/shared hooks/pre-commit"
  must git config core.hooksPath "$TMP/shared hooks"
  local before
  before=$(hooks_sum "$TMP/shared hooks")
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks"
  assert_eq "$before" "$(hooks_sum "$TMP/shared hooks")" "the shared hooks directory is untouched"
  assert_contains "$OUT" "ACTION NEEDED: add to $TMP/shared hooks/pre-commit:"
  assert_contains "$OUT" "ACTION NEEDED: add to $TMP/shared hooks/pre-push:"
  assert_contains "$OUT" "$HOOK_TEST_GATE_STAGED"
}

# A global core.hooksPath shared by every repo is printed, and nothing is written.
test_global_hooks_path_outside_repo_is_print_only() {
  hooks_repo "$TMP/repo"
  must mkdir -p "$TMP/global hooks"
  printf '#!/bin/sh\necho global\n' > "$TMP/global hooks/pre-commit"
  printf '[core]\n\thooksPath = %s\n' "$TMP/global hooks" > "$TMP/gitconfig"
  export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
  local before
  before=$(hooks_sum "$TMP/global hooks")
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks"
  assert_eq "$before" "$(hooks_sum "$TMP/global hooks")" "the global hooks directory is untouched"
  if [ -e "$TMP/global hooks/pre-push" ]; then fail "a hook was created in the global hooks directory"; fi
  assert_contains "$OUT" "ACTION NEEDED: add to $TMP/global hooks/pre-commit:"
  if git config --local --get core.hooksPath > /dev/null; then fail "install wrote core.hooksPath"; fi
}

# A linked worktree's hooks live under the common git dir: they stay editable.
test_linked_worktree_hooks_stay_editable() {
  hooks_repo "$TMP/repo"
  must git worktree add -q "$TMP/wt dir" -b wt
  must cd "$TMP/wt dir"
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks in the worktree"
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_STAGED" "$TMP/repo/.git/hooks/pre-commit")" "pre-commit line in the common hooks dir"
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_CI" "$TMP/repo/.git/hooks/pre-push")" "pre-push line in the common hooks dir"
}

test_created_hooks_are_executable() {
  hooks_repo "$TMP/repo"
  run "$G" install
  assert_eq 0 "$STATUS" "install"
  local f
  for f in .git/hooks/pre-commit .git/hooks/pre-push; do
    if [ ! -x "$f" ]; then fail "$f is not executable"; fi
    assert_eq "#!/usr/bin/env sh" "$(head -n 1 "$f")" "shebang of $f"
  done
}

# A created hook ends with a final newline.
test_created_hooks_end_with_newline() {
  hooks_repo "$TMP/repo"
  run "$G" install
  assert_eq 0 "$STATUS" "install"
  local f
  for f in .git/hooks/pre-commit .git/hooks/pre-push; do
    assert_eq "0a" "$(tail -c 1 "$f" | od -An -tx1 | tr -d ' ')" "$f ends with a newline"
  done
}

test_install_from_subdirectory_acts_on_root() {
  hooks_repo "$TMP/repo"
  must mkdir -p sub/deeper
  must cd sub/deeper
  run "$G" install
  assert_eq 0 "$STATUS" "install from a subdirectory"
  if [ ! -d "$TMP/repo/.gauntlet" ]; then fail "the runner was not vendored at the root"; fi
  if [ -e "$TMP/repo/sub/.gauntlet" ] || [ -e .gauntlet ]; then
    fail "state was created below the root"
  fi
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_STAGED" "$TMP/repo/.git/hooks/pre-commit")" "hook at the root"
}

# install-hooks from a subdirectory acts on the root, for the default hooks dir and
# for husky (a husky dir created under the subdirectory would show the bug).
test_install_hooks_from_subdirectory_uses_root() {
  hooks_repo "$TMP/repo"
  must mkdir -p sub/deeper
  must cd sub/deeper
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks from a subdirectory"
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_STAGED" "$TMP/repo/.git/hooks/pre-commit")" "default hooks dir at the root"
  if [ -e "$TMP/repo/sub/deeper/.git" ] || [ -e .git/hooks ]; then fail "hooks were written below the root"; fi
  hooks_repo "$TMP/husky repo"
  must mkdir -p .husky sub/deeper
  must git config core.hooksPath .husky
  must cd sub/deeper
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks from a subdirectory with husky"
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_STAGED" "$TMP/husky repo/.husky/pre-commit")" "husky dir at the root"
  if [ -e .husky ]; then fail "a husky dir was created below the root"; fi
}

test_outside_git_repo_exits_2() {
  must mkdir -p "$TMP/not a repo"
  must cd "$TMP/not a repo"
  run "$G" install
  assert_eq 2 "$STATUS" "install outside a repo"
  assert_contains "$OUT" "not inside a git repository"
  if [ -e .gauntlet ]; then fail "install created .gauntlet outside a repo"; fi
  run "$G" install-hooks
  assert_eq 2 "$STATUS" "install-hooks outside a repo"
}

test_repo_path_with_space() {
  must mkdir -p "$TMP/runner checkout"
  must cp -R "$ROOT/bin" "$ROOT/lib" "$TMP/runner checkout/"
  hooks_repo "$TMP/my repo"
  run "$TMP/runner checkout/bin/gauntlet" install
  assert_eq 0 "$STATUS" "install from a checkout whose path has a space"
  run .gauntlet/bin/gauntlet --version
  assert_eq 0 "$STATUS" "vendored --version"
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_STAGED" .git/hooks/pre-commit)" "pre-commit line"
}

# The runner is copied with its exec bit even when the source copy has lost it.
test_vendored_runner_is_executable_from_nonexec_source() {
  hooks_repo "$TMP/repo"
  must mkdir -p "$TMP/nonexec"
  must cp -R "$ROOT/bin" "$ROOT/lib" "$TMP/nonexec/"
  must chmod 644 "$TMP/nonexec/bin/gauntlet"
  run bash "$TMP/nonexec/bin/gauntlet" install
  assert_eq 0 "$STATUS" "install from a source without the exec bit"
  if [ ! -x .gauntlet/bin/gauntlet ]; then fail "the vendored runner is not executable"; fi
  run .gauntlet/bin/gauntlet --version
  assert_eq 0 "$STATUS" "vendored --version"
}

# The runner runs and installs through a symlink, a relative link and a chain.
test_runs_through_symlinks() {
  must mkdir -p "$TMP/checkout" "$TMP/links/bin" "$TMP/elsewhere"
  must cp -R "$ROOT/bin" "$ROOT/lib" "$TMP/checkout/"
  must ln -s "$TMP/checkout/bin/gauntlet" "$TMP/links/bin/abs"
  must ln -s ../../checkout/bin/gauntlet "$TMP/links/bin/rel"
  must ln -s rel "$TMP/links/bin/chain"
  must cd "$TMP/elsewhere"
  local name
  for name in abs rel chain; do
    run "$TMP/links/bin/$name" --version
    assert_eq 0 "$STATUS" "$name: --version"
    assert_contains "$OUT" "gauntlet "
  done
  hooks_repo "$TMP/repo"
  run "$TMP/links/bin/chain" install
  assert_eq 0 "$STATUS" "install through a symlink chain"
  if ! cmp -s "$TMP/checkout/bin/gauntlet" .gauntlet/bin/gauntlet; then
    fail "the vendored runner is not the checkout's runner"
  fi
  run .gauntlet/bin/gauntlet --version
  assert_eq 0 "$STATUS" "vendored --version"
}

# A failed copy leaves the old runner exactly as it was and no temp copy behind.
test_failed_copy_keeps_old_runner() {
  hooks_repo "$TMP/repo"
  if hooks_as_root; then
    skip "running as root: unreadable and read-only files are still readable here"
    return 77
  fi
  run "$G" install
  assert_eq 0 "$STATUS" "install"
  local runner status=0
  runner=$(hooks_sum .gauntlet/bin .gauntlet/lib)
  must mkdir -p "$TMP/broken"
  must cp -R "$ROOT/bin" "$ROOT/lib" "$TMP/broken/"
  # A format is read only by checks, so the broken runner still starts and reaches
  # the copy; lib/*.sh is sourced at startup and would stop it before that.
  must chmod 000 "$TMP/broken/lib/formats/github.md"
  bash "$TMP/broken/bin/gauntlet" install > "$TMP/out" 2>&1 || status=$?
  assert_eq 2 "$status" "install fails on an unreadable source file"
  assert_eq "$runner" "$(hooks_sum .gauntlet/bin .gauntlet/lib)" "the old runner is intact"
  if [ -e .gauntlet/.bin.new ] || [ -e .gauntlet/.lib.new ]; then
    fail "a temp copy was left behind"
  fi
}

# A read-only .gauntlet fails the copy and leaves the old runner intact.
test_read_only_gauntlet_keeps_old_runner() {
  hooks_repo "$TMP/repo"
  if hooks_as_root; then
    skip "running as root: unreadable and read-only files are still readable here"
    return 77
  fi
  run "$G" install
  assert_eq 0 "$STATUS" "install"
  local runner status=0
  runner=$(hooks_sum .gauntlet/bin .gauntlet/lib)
  must chmod 555 .gauntlet
  "$G" install > "$TMP/out" 2>&1 || status=$?
  must chmod 755 .gauntlet
  assert_eq 2 "$status" "install fails in a read-only .gauntlet"
  assert_eq "$runner" "$(hooks_sum .gauntlet/bin .gauntlet/lib)" "the old runner is intact"
  if [ -e .gauntlet/.bin.new ] || [ -e .gauntlet/.lib.new ]; then
    fail "a temp copy was left behind"
  fi
}

# A failed read of a hook leaves no temp file behind, and neither does an edit.
test_no_temp_file_left_behind() {
  hooks_repo "$TMP/repo"
  if hooks_as_root; then
    skip "running as root: unreadable and read-only files are still readable here"
    return 77
  fi
  must mkdir -p "$TMP/tmpdir"
  printf '#!/bin/sh\necho x\n' > .git/hooks/pre-commit
  must chmod 000 .git/hooks/pre-commit
  local status=0
  TMPDIR="$TMP/tmpdir" "$G" install-hooks > "$TMP/out" 2>&1 || status=$?
  assert_eq 2 "$status" "install-hooks cannot read the hook"
  assert_eq "" "$(ls -A "$TMP/tmpdir")" "no temp file after the failed read"
  must chmod 644 .git/hooks/pre-commit
  printf '#!/bin/sh\necho y\n' > .git/hooks/pre-push
  TMPDIR="$TMP/tmpdir" "$G" install-hooks > "$TMP/out" 2>&1 || fail "install-hooks failed"
  assert_eq "" "$(ls -A "$TMP/tmpdir")" "no temp file after a successful edit"
}

test_install_hooks_warns_without_runner() {
  hooks_repo "$TMP/repo"
  local status=0
  "$G" install-hooks > "$TMP/out" 2> "$TMP/err" || status=$?
  assert_eq 0 "$status" "install-hooks without a vendored runner"
  assert_contains "$(cat "$TMP/err")" "warning: .gauntlet/bin/gauntlet is missing"
  assert_not_contains "$(cat "$TMP/out")" "warning"
  if [ ! -f .git/hooks/pre-commit ]; then fail "the hooks were not installed"; fi
  run "$G" install
  assert_eq 0 "$STATUS" "install"
  "$G" install-hooks > "$TMP/out" 2> "$TMP/err" || status=$?
  assert_eq "" "$(cat "$TMP/err")" "no warning once the runner is vendored"
}

# A commit made through a real hook: the rule is committed first, because a rule
# new in the commit that carries its violation is exempt from the new check.
test_commit_blocked_then_passes_through_vendored_runner() {
  hooks_repo "$TMP/my repo"
  run "$G" install
  assert_eq 0 "$STATUS" "install"
  rule todo format=path-line
  must git add -A
  run git commit -q -m "add the todo rule"
  assert_eq 0 "$STATUS" "commit of the rule alone: $OUT"
  printf 'TODO fix me\n' > a.txt
  must git add a.txt
  local before
  before=$(git rev-parse HEAD)
  run git commit -q -m "add a violation"
  if [ "$STATUS" -eq 0 ]; then fail "the commit with a new violation was not blocked: $OUT"; fi
  assert_contains "$OUT" "a.txt"
  assert_contains "$OUT" "todo"
  assert_not_contains "$OUT" "unknown format"
  assert_eq "$before" "$(git rev-parse HEAD)" "HEAD is unchanged after the blocked commit"
  printf 'done\n' > a.txt
  must git add a.txt
  run git commit -q -m "fix the violation"
  assert_eq 0 "$STATUS" "commit after the fix: $OUT"
  assert_eq "" "$(git status --short)" "tree is clean after the fixed commit"
}









test_nul_byte_hook_is_print_only() {
  hooks_repo "$TMP/repo"
  printf '#!/bin/sh\necho \000x\n' > .git/hooks/pre-commit
  chmod 755 .git/hooks/pre-commit
  local before
  before=$(hooks_sum .git/hooks/pre-commit)
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks"
  assert_eq "$before" "$(hooks_sum .git/hooks/pre-commit)" "the binary hook is not edited"
  assert_contains "$OUT" "ACTION NEEDED: add to .git/hooks/pre-commit:"
}

test_symlink_to_file_outside_root_is_print_only() {
  hooks_repo "$TMP/repo"
  must mkdir -p "$TMP/outside"
  printf '#!/bin/sh\necho outside\n' > "$TMP/outside/hook"
  chmod 755 "$TMP/outside/hook"
  must ln -s "$TMP/outside/hook" .git/hooks/pre-commit
  local before
  before=$(hooks_sum "$TMP/outside/hook")
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks"
  assert_eq "$before" "$(hooks_sum "$TMP/outside/hook")" "the file outside the repo is not edited"
  if [ ! -L .git/hooks/pre-commit ]; then fail "the link was replaced"; fi
  assert_contains "$OUT" "ACTION NEEDED: add to .git/hooks/pre-commit:"
}

test_symlink_to_file_inside_root_is_edited() {
  hooks_repo "$TMP/repo"
  must mkdir -p shared
  printf '#!/bin/sh\necho shared\n' > shared/hook
  chmod 755 shared/hook
  must ln -s ../../shared/hook .git/hooks/pre-commit
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks"
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_GATE_STAGED" shared/hook)" "the target inside the repo is edited"
  if [ ! -L .git/hooks/pre-commit ]; then fail "the link was replaced"; fi
}

# ~ in core.hooksPath expands to the home directory: never a literal ~ in the repo.
test_hookspath_tilde_expands_to_home() {
  hooks_repo "$TMP/repo"
  mkdir -p "$TMP/home"
  # shellcheck disable=SC2088 # the literal ~ is the point: git must expand it
  must git config core.hooksPath '~/shared-hooks'
  HOME="$TMP/home"
  export HOME
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks with ~ outside the repo"
  if [ -e "$TMP/repo/~" ]; then fail "a literal ~ directory was created in the repo"; fi
  if [ -e "$TMP/home/shared-hooks" ]; then fail "hooks were written to the home directory"; fi
  assert_contains "$OUT" "ACTION NEEDED: add to $TMP/home/shared-hooks/pre-commit:"
  hooks_repo "$TMP/home-repo"
  # shellcheck disable=SC2088 # the literal ~ is the point: git must expand it
  must git config core.hooksPath '~/.husky'
  HOME="$TMP/home-repo"
  export HOME
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks with ~ inside the repo"
  if [ -e "$TMP/home-repo/~" ]; then fail "a literal ~ directory was created in the repo"; fi
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_STAGED" "$TMP/home-repo/.husky/pre-commit")" "the expanded ~/.husky is the repo's husky dir"
}

# fake_mv_setup: put a mv on PATH that fails at the moves numbered FAKE_MV_FAIL_AT
# and FAKE_MV_FAIL2_AT (counted from zero per run, by FAKE_MV_COUNT) and is the real
# mv for every other call.
fake_mv_setup() {
  must mkdir -p "$TMP/fakebin"
  cat > "$TMP/fakebin/mv" <<'SH'
#!/bin/sh
n=$(cat "$FAKE_MV_COUNT" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$FAKE_MV_COUNT"
if [ "$n" = "$FAKE_MV_FAIL_AT" ] || [ "$n" = "$FAKE_MV_FAIL2_AT" ]; then
  echo "mv: injected failure at move $n" >&2
  exit 1
fi
exec "$FAKE_MV_REAL" "$@"
SH
  must chmod +x "$TMP/fakebin/mv"
  FAKE_MV_REAL=$(command -v mv)
  FAKE_MV_COUNT="$TMP/mv-count"
  export FAKE_MV_REAL FAKE_MV_COUNT
}

# A failed rollback keeps the old runner's copy and the complete new copy: nothing
# is deleted until the old runner is back.
test_failed_rollback_keeps_both_copies() {
  hooks_repo "$TMP/repo"
  run "$G" install
  assert_eq 0 "$STATUS" "install"
  fake_mv_setup
  rm -f "$FAKE_MV_COUNT"
  local status=0
  FAKE_MV_FAIL_AT=2 FAKE_MV_FAIL2_AT=3 PATH="$TMP/fakebin:$PATH" "$G" install > "$TMP/out" 2>&1 || status=$?
  assert_eq 2 "$status" "install with the new runner's move and its rollback failing"
  assert_contains "$(cat "$TMP/out")" "the rollback failed"
  assert_not_contains "$(cat "$TMP/out")" "lib.old"
  if [ ! -d .gauntlet/.bin.old ]; then fail "the old runner is not kept in .gauntlet/.bin.old"; fi
  if [ ! -d .gauntlet/.bin.new ]; then fail "the complete new copy was deleted"; fi
  if [ -e .gauntlet/bin ]; then fail "bin is in place though the rollback failed"; fi
}

# Each move of the vendoring swap fails in turn: the old runner keeps working,
# nothing is left behind, and a second install without the fault recovers.
test_swap_failure_keeps_old_runner() {
  hooks_repo "$TMP/repo"
  run "$G" install
  assert_eq 0 "$STATUS" "install"
  local runner n status
  runner=$(hooks_sum .gauntlet/bin .gauntlet/lib)
  fake_mv_setup
  for n in 1 2 3 4; do
    rm -f "$FAKE_MV_COUNT"
    status=0
    FAKE_MV_FAIL_AT=$n PATH="$TMP/fakebin:$PATH" "$G" install > "$TMP/out" 2>&1 || status=$?
    assert_eq 2 "$status" "install with move $n failing"
    assert_eq "$runner" "$(hooks_sum .gauntlet/bin .gauntlet/lib)" "the old runner is intact after move $n fails"
    run .gauntlet/bin/gauntlet --version
    assert_eq 0 "$STATUS" "the old runner still runs after move $n fails"
    if [ -e .gauntlet/.bin.new ] || [ -e .gauntlet/.lib.new ] || [ -e .gauntlet/.bin.old ] || [ -e .gauntlet/.lib.old ]; then
      fail "move $n left a copy or an old runner behind"
    fi
  done
  run "$G" install
  assert_eq 0 "$STATUS" "a second install recovers"
  assert_eq "$runner" "$(hooks_sum .gauntlet/bin .gauntlet/lib)" "the runner is the same after recovery"
}

# A read-only source tree (as a Nix store gives): install twice, quietly.
test_read_only_source_installs_twice() {
  if hooks_as_root; then
    skip "running as root: a read-only tree is writable here"
    return 77
  fi
  hooks_repo "$TMP/repo"
  must mkdir -p "$TMP/ro-src"
  must cp -R "$ROOT/bin" "$ROOT/lib" "$TMP/ro-src/"
  must chmod -R a-w "$TMP/ro-src"
  run bash "$TMP/ro-src/bin/gauntlet" install
  assert_eq 0 "$STATUS" "first install from a read-only source: $OUT"
  assert_not_contains "$OUT" "Permission denied"
  run bash "$TMP/ro-src/bin/gauntlet" install
  assert_eq 0 "$STATUS" "second install from a read-only source: $OUT"
  assert_not_contains "$OUT" "Permission denied"
  if [ -e .gauntlet/.bin.new ] || [ -e .gauntlet/.lib.new ] || [ -e .gauntlet/.bin.old ] || [ -e .gauntlet/.lib.old ]; then
    fail "a copy or an old runner was left behind"
  fi
  # The owner can still remove the installed runner: its directories are writable.
  if [ ! -w .gauntlet/bin ] || [ ! -w .gauntlet/lib ]; then
    fail "the installed runner's directories are not writable by the owner"
  fi
  must chmod -R u+w "$TMP/ro-src"
  run .gauntlet/bin/gauntlet --version
  assert_eq 0 "$STATUS" "vendored --version"
}

# Presence is a whole-line match: an indented marker and a marker inside a comment
# do not count, so the gate line is added.
test_presence_is_whole_line_not_indented_or_comment() {
  hooks_repo "$TMP/repo"
  printf '#!/bin/sh\n  %s\n# %s\necho x\n' "$HOOK_TEST_STAGED" "$HOOK_TEST_STAGED" > .git/hooks/pre-commit
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks"
  assert_not_contains "$OUT" "already present in .git/hooks/pre-commit"
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_GATE_STAGED" .git/hooks/pre-commit)" "the whole-line gate was added"
}

# A husky path outside the repo root is not husky's: printed, and nothing created.
test_husky_outside_root_is_print_only() {
  hooks_repo "$TMP/repo"
  must git config core.hooksPath '../.husky/_'
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks"
  if [ -e "$TMP/.husky" ]; then fail "a husky directory was created outside the repo"; fi
  assert_contains "$OUT" "ACTION NEEDED: add to $TMP/.husky/_/pre-commit:"
}

# packages/../.husky/_ normalises to <root>/.husky/_: the edit lands in <root>/.husky.
test_husky_dotdot_inside_root_normalises() {
  hooks_repo "$TMP/repo"
  must git config core.hooksPath 'packages/../.husky/_'
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks"
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_STAGED" .husky/pre-commit)" "pre-commit in <root>/.husky"
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_CI" .husky/pre-push)" "pre-push in <root>/.husky"
  if [ -e packages ]; then fail "packages/ was created by an unresolved .."; fi
}



# A config with only one of the two gate commands is not already configured.
test_partial_config_is_not_already_configured() {
  hooks_repo "$TMP/repo"
  printf 'pre-commit:\n  commands:\n    gauntlet:\n      run: .gauntlet/bin/gauntlet check --staged\n' > lefthook.yml
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks"
  assert_not_contains "$OUT" "already configured"
  assert_contains "$OUT" "ACTION NEEDED: add to lefthook.yml:"
}

# A symlinked bin directory: the checkout is reached through the link. Its lexical
# parent has no lib/, so a logical pwd would look in the wrong place.
test_install_through_symlinked_bin_dir() {
  must mkdir -p "$TMP/checkout" "$TMP/co"
  must cp -R "$ROOT/bin" "$ROOT/lib" "$TMP/checkout/"
  must ln -s "$TMP/checkout/bin" "$TMP/co/bin"
  hooks_repo "$TMP/repo"
  run "$TMP/co/bin/gauntlet" install
  assert_eq 0 "$STATUS" "install through a symlinked bin dir: $OUT"
  if ! cmp -s "$TMP/checkout/bin/gauntlet" .gauntlet/bin/gauntlet; then
    fail "the vendored runner is not the checkout's runner"
  fi
}

# A print-only hook that is not executable gets the warning too.
test_print_only_hook_warns_when_not_executable() {
  hooks_repo "$TMP/repo"
  printf '#!/bin/sh\r\necho x\r\n' > .git/hooks/pre-commit
  chmod 644 .git/hooks/pre-commit
  local before
  before=$(hooks_sum .git/hooks/pre-commit)
  "$G" install-hooks > "$TMP/out" 2> "$TMP/err" || fail "install-hooks failed"
  assert_eq "$before" "$(hooks_sum .git/hooks/pre-commit)" "the CRLF hook is not edited"
  assert_contains "$(cat "$TMP/err")" "warning: .git/hooks/pre-commit is not executable; git will ignore it"
}

# The gate goes first in an editable hook: on the line after the shebang, before
# anything the project's own hook does. An early exit, exec, a continuation or a
# failing tail cannot get past it. The helper commits a violation after install.
# top_gate_case <hook> [line]: the gate is on <line> (2 after a shebang, 1 without one).
top_gate_case() {
  local line=${2:-2}
  hooks_repo "$TMP/my repo"
  printf '%s' "$1" > .git/hooks/pre-commit
  chmod 755 .git/hooks/pre-commit
  run "$G" install
  assert_eq 0 "$STATUS" "install"
  assert_eq "$HOOK_TEST_GATE_STAGED" "$(sed -n "${line}p" .git/hooks/pre-commit)" "the gate is line $line"
  run sh -n .git/hooks/pre-commit
  assert_eq 0 "$STATUS" "the edited hook still parses"
  rule todo format=path-line
  must git add -A
  run git commit -q -m "add the todo rule"
  assert_eq 0 "$STATUS" "commit of the rule alone: $OUT"
  printf 'TODO fix me\n' > a.txt
  must git add a.txt
  local before
  before=$(git rev-parse HEAD)
  run git commit -q -m "add a violation"
  if [ "$STATUS" -eq 0 ]; then fail "the gate did not block a violation: $OUT"; fi
  assert_eq "$before" "$(git rev-parse HEAD)" "HEAD is unchanged after the blocked commit"
}

test_gate_first_blocks_echo_then_exit_on_one_line() {
  top_gate_case $'#!/bin/sh\necho start; exit 0\n'
}

test_gate_first_blocks_trailing_exec() {
  top_gate_case $'#!/bin/sh\necho lint\nexec echo done\n'
}

test_gate_first_blocks_exit_then_more_code() {
  top_gate_case $'#!/bin/sh\nif true; then exit 0; fi\necho more\n'
}

test_gate_first_blocks_early_opt_out() {
  top_gate_case $'#!/bin/sh\nfiles=$(echo x)\nif [ -z "$files" ]; then exit 0; fi\necho linting\n'
}

test_gate_first_blocks_function_then_call() {
  top_gate_case $'#!/bin/sh\nmain() {\n  echo lint\n  exit 0\n}\nmain "$@"\n'
}

test_gate_first_blocks_exit_with_argument() {
  top_gate_case $'#!/bin/sh\nrc=0\necho lint\nexit "$rc"\n'
}

test_gate_first_blocks_line_continuation() {
  top_gate_case $'#!/bin/sh\necho lint \\\n  || exit 1\n'
}

# The project's own result is kept: a commit made through the hook has the same exit
# status before and after install, and the hook's own output still shows.
status_case() {
  hooks_repo "$TMP/$1"
  printf '%s' "$2" > .git/hooks/pre-commit
  chmod 755 .git/hooks/pre-commit
  printf 'ok\n' > a.txt
  must git add a.txt
  run git commit -q -m "before install"
  local before=$STATUS
  run "$G" install
  assert_eq 0 "$STATUS" "install"
  printf 'ok again\n' > b.txt
  must git add b.txt
  run git commit -q -m "after install"
  assert_eq "$before" "$STATUS" "the exit status is the same before and after install: $OUT"
  assert_contains "$OUT" "$3"
}

test_clean_commit_keeps_failing_tail_echo_false() {
  status_case status-echo-false $'#!/bin/sh\necho lint; false\n' lint
}

test_clean_commit_keeps_failing_tail_with_exit() {
  status_case status-false-exit $'#!/bin/sh\necho check; false; exit $?\n' check
}

test_clean_commit_keeps_passing_hook() {
  status_case status-pass $'#!/bin/sh\necho lint\n' lint
}

# A project's own trailing exit stays below the gate, byte for byte.
test_trailing_exit_stays_below_the_gate() {
  hooks_repo "$TMP/repo"
  printf '#!/bin/sh\necho x\nexit 0\n' > .git/hooks/pre-commit
  chmod 755 .git/hooks/pre-commit
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks"
  hooks_expect .git/hooks/pre-commit $'#!/bin/sh\n'"$HOOK_TEST_GATE_STAGED"$'\necho x\nexit 0\n'
}

# A hook that is a symlink to a directory is printed quietly, with no read errors.
test_symlink_to_directory_is_print_only_quietly() {
  hooks_repo "$TMP/repo"
  must mkdir -p somedir
  must ln -s "$TMP/repo/somedir" .git/hooks/pre-commit
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks"
  assert_contains "$OUT" "ACTION NEEDED: add to .git/hooks/pre-commit:"
  assert_not_contains "$OUT" "read error"
  assert_not_contains "$OUT" "Is a directory"
}

# A shared hooks directory outside the repo: an existing hook there that is not
# executable is warned about, and its mode is left alone.
test_shared_hooks_dir_warns_when_hook_not_executable() {
  hooks_repo "$TMP/repo"
  must mkdir -p "$TMP/shared hooks"
  printf '#!/bin/sh\necho shared\n' > "$TMP/shared hooks/pre-commit"
  chmod 644 "$TMP/shared hooks/pre-commit"
  must git config core.hooksPath "$TMP/shared hooks"
  "$G" install-hooks > "$TMP/out" 2> "$TMP/err" || fail "install-hooks failed"
  assert_contains "$(cat "$TMP/err")" "warning: $TMP/shared hooks/pre-commit is not executable; git will ignore it"
  if [ -x "$TMP/shared hooks/pre-commit" ]; then fail "the shared hook's mode was changed"; fi
}

# core.hooksPath set to the empty value means unset: the default hooks directory.
test_empty_hookspath_means_the_default_hooks_dir() {
  hooks_repo "$TMP/repo"
  must git config core.hooksPath ""
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks"
  assert_eq "#!/usr/bin/env sh" "$(head -n 1 .git/hooks/pre-commit)" "the default hooks dir got the hook"
  if [ -e pre-commit ]; then fail "a hook was written into the repo root"; fi
}

# In a linked worktree, a hook symlinked to a file inside the common git dir is ours.
test_linked_worktree_symlinked_hook_into_common_git_is_edited() {
  hooks_repo "$TMP/repo"
  printf '#!/bin/sh\necho shared\n' > .git/shared-hook
  chmod 755 .git/shared-hook
  must ln -s ../shared-hook .git/hooks/pre-commit
  must git worktree add -q "$TMP/wt dir" -b wt
  must cd "$TMP/wt dir"
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks in the worktree"
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_GATE_STAGED" "$TMP/repo/.git/shared-hook")" "the target in the common git dir is edited"
  if [ ! -L "$TMP/repo/.git/hooks/pre-commit" ]; then fail "the link was replaced"; fi
}

# An install killed after each of the four moves of the vendoring swap leaves a state
# the next install must recover from: a working runner, and no copies left behind.
interrupted_install_case() {
  local point=$1 runner
  hooks_repo "$TMP/repo $point"
  run "$G" install
  assert_eq 0 "$STATUS" "install"
  runner=$(hooks_sum .gauntlet/bin .gauntlet/lib)
  must mv .gauntlet/bin .gauntlet/.bin.old
  if [ "$point" -eq 1 ]; then
    must cp -R "$ROOT/bin" .gauntlet/.bin.new
  else
    must cp -R "$ROOT/bin" .gauntlet/bin
  fi
  if [ "$point" -ge 3 ]; then
    must mv .gauntlet/lib .gauntlet/.lib.old
    if [ "$point" -eq 3 ]; then
      must cp -R "$ROOT/lib" .gauntlet/.lib.new
    else
      must cp -R "$ROOT/lib" .gauntlet/lib
    fi
  fi
  run "$G" install
  assert_eq 0 "$STATUS" "re-install after a kill at move $point: $OUT"
  assert_eq "$runner" "$(hooks_sum .gauntlet/bin .gauntlet/lib)" "the runner is the checkout's runner"
  run .gauntlet/bin/gauntlet --version
  assert_eq 0 "$STATUS" "the runner works after a kill at move $point"
  if [ -e .gauntlet/.bin.new ] || [ -e .gauntlet/.lib.new ] || [ -e .gauntlet/.bin.old ] || [ -e .gauntlet/.lib.old ]; then
    fail "copies were left behind after a kill at move $point"
  fi
}

test_interrupted_install_recovers_after_move_1() {
  interrupted_install_case 1
}

test_interrupted_install_recovers_after_move_2() {
  interrupted_install_case 2
}

test_interrupted_install_recovers_after_move_3() {
  interrupted_install_case 3
}

test_interrupted_install_recovers_after_move_4() {
  interrupted_install_case 4
}

# A real push: the pre-push gate, placed first in an existing hook that ends in
# exit 0, refuses a branch whose commit brings a new violation. The commit is made
# with --no-verify so the violation reaches push, as it would from a machine
# without the commit gate.
test_push_blocked_by_gate_first_in_existing_pre_push() {
  hooks_repo "$TMP/push repo"
  must git init -q --bare "$TMP/remote.git"
  must git remote add origin "$TMP/remote.git"
  printf '#!/bin/sh\necho push\nexit 0\n' > .git/hooks/pre-push
  chmod 755 .git/hooks/pre-push
  run "$G" install
  assert_eq 0 "$STATUS" "install"
  rule todo format=path-line
  must git add -A
  run git commit -q -m "add the gate and the rule"
  assert_eq 0 "$STATUS" "commit on main: $OUT"
  run git push -q origin main
  assert_eq 0 "$STATUS" "push of main, which has no violation: $OUT"
  must git checkout -q -b feat
  printf 'TODO fix me\n' > a.txt
  must git add a.txt
  run git commit -q --no-verify -m "add a violation"
  assert_eq 0 "$STATUS" "commit that skipped the commit gate: $OUT"
  run git push -q origin feat
  if [ "$STATUS" -eq 0 ]; then fail "the push with a new violation was not refused: $OUT"; fi
  assert_contains "$OUT" "a.txt"
  if git -C "$TMP/remote.git" rev-parse -q --verify refs/heads/feat > /dev/null; then
    fail "the refused branch reached the remote"
  fi
}

# The gate follows the shebang whatever shell it names, not only #!/bin/sh.
gate_after_shebang_case() {
  hooks_repo "$TMP/$1"
  printf '%s\necho x\n' "$2" > .git/hooks/pre-commit
  chmod 755 .git/hooks/pre-commit
  run "$G" install
  assert_eq 0 "$STATUS" "install: $OUT"
  assert_eq "$2" "$(sed -n 1p .git/hooks/pre-commit)" "the shebang stays on line 1"
  assert_eq "$HOOK_TEST_GATE_STAGED" "$(sed -n 2p .git/hooks/pre-commit)" "the gate is the second line"
}

test_gate_after_bash_env_shebang_is_second_line() {
  gate_after_shebang_case bash-env '#!/usr/bin/env bash'
}

test_gate_after_zsh_shebang_is_second_line() {
  gate_after_shebang_case zsh-path '#!/bin/zsh'
}

# A hook with no shebang is sh: its first line runs first, so the gate is line 1 and
# gets to block before a leading exit 0 can end the hook.
test_gate_without_shebang_is_first_line_and_blocks() {
  top_gate_case $'exit 0\n' 1
}

# The state a swap killed after moving the old lib aside leaves: the live lib is
# .lib.old and a new copy waits in .lib.new. A later install whose copy fails must put
# the old lib back, not drop it.
test_failed_copy_after_kill_restores_the_live_lib() {
  hooks_repo "$TMP/repo"
  if hooks_as_root; then
    skip "running as root: unreadable and read-only files are still readable here"
    return 77
  fi
  run "$G" install
  assert_eq 0 "$STATUS" "install"
  local lib status=0
  lib=$(hooks_sum .gauntlet/lib)
  must mv .gauntlet/lib .gauntlet/.lib.old
  must cp -R "$ROOT/lib" .gauntlet/.lib.new
  must mkdir -p "$TMP/broken"
  must cp -R "$ROOT/bin" "$ROOT/lib" "$TMP/broken/"
  must chmod 000 "$TMP/broken/lib/formats/github.md"
  bash "$TMP/broken/bin/gauntlet" install > "$TMP/out" 2>&1 || status=$?
  assert_eq 2 "$status" "install fails on an unreadable source file"
  assert_eq "$lib" "$(hooks_sum .gauntlet/lib)" "the live lib is the old one, restored"
}

# FRD-03 section 4.11: the pre-push line is `check --ci --pre-push`. A hook written by an earlier
# version has the line without the flag, which silently judges whatever is checked out, so
# install-hooks puts the new line where the old one was instead of adding a second gate.
HOOK_TEST_OLD_CI='.gauntlet/bin/gauntlet check --ci  # gauntlet'
HOOK_TEST_OLD_GATE_CI='.gauntlet/bin/gauntlet check --ci || exit $?  # gauntlet'

test_install_hooks_replaces_the_old_gate_line_in_place() {
  hooks_repo "$TMP/repo"
  printf '#!/bin/sh\necho one\n%s\necho two\n' "$HOOK_TEST_OLD_GATE_CI" > .git/hooks/pre-push
  chmod 755 .git/hooks/pre-push
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks: $OUT"
  assert_contains "$OUT" "updated gauntlet line in .git/hooks/pre-push"
  hooks_expect .git/hooks/pre-push $'#!/bin/sh\necho one\n'"$HOOK_TEST_GATE_CI"$'\necho two\n'
  if [ ! -x .git/hooks/pre-push ]; then fail "the hook lost its exec bit"; fi
  run "$G" install-hooks
  assert_contains "$OUT" "already present in .git/hooks/pre-push"
}

test_install_hooks_replaces_the_old_plain_line_in_place() {
  hooks_repo "$TMP/repo"
  printf '#!/usr/bin/env sh\n%s\n' "$HOOK_TEST_OLD_CI" > .git/hooks/pre-push
  chmod 755 .git/hooks/pre-push
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks: $OUT"
  hooks_expect .git/hooks/pre-push $'#!/usr/bin/env sh\n'"$HOOK_TEST_CI"$'\n'
}

# The pre-commit line is not the pre-push line: it keeps its text.
test_install_hooks_leaves_the_pre_commit_line_alone() {
  hooks_repo "$TMP/repo"
  printf '#!/bin/sh\n%s\n' "$HOOK_TEST_GATE_STAGED" > .git/hooks/pre-commit
  printf '#!/bin/sh\n%s\n' "$HOOK_TEST_OLD_GATE_CI" > .git/hooks/pre-push
  chmod 755 .git/hooks/pre-commit .git/hooks/pre-push
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks: $OUT"
  hooks_expect .git/hooks/pre-commit $'#!/bin/sh\n'"$HOOK_TEST_GATE_STAGED"$'\n'
}

# A hook we may not edit keeps its old line and is told the new one.
test_an_old_gate_line_in_an_uneditable_hook_is_print_only() {
  hooks_repo "$TMP/repo"
  printf '#!/usr/bin/env python3\n# %s\nprint("x")\n' "$HOOK_TEST_OLD_GATE_CI" > .git/hooks/pre-push
  local before
  before=$(hooks_sum .git/hooks/pre-push)
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks: $OUT"
  assert_contains "$OUT" "ACTION NEEDED: add to .git/hooks/pre-push:"
  assert_contains "$OUT" "$HOOK_TEST_GATE_CI"
  assert_eq "$before" "$(hooks_sum .git/hooks/pre-push)" "the hook is unchanged"
}

# The old line later in the hook, after the project's own commands, is replaced where it stands.
test_a_moved_old_gate_line_is_replaced_where_it_stands() {
  hooks_repo "$TMP/repo"
  printf '#!/bin/sh\necho one\n%s\n' "$HOOK_TEST_OLD_GATE_CI" > .git/hooks/pre-push
  chmod 755 .git/hooks/pre-push
  run "$G" install-hooks
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_GATE_CI" .git/hooks/pre-push)" "new line"
  assert_eq 0 "$(hooks_lines "$HOOK_TEST_OLD_GATE_CI" .git/hooks/pre-push)" "old line"
}

# A missing final newline stays missing, whether the old line is the last one or not.
test_replacing_the_old_line_keeps_a_missing_final_newline() {
  hooks_repo "$TMP/repo"
  printf '#!/bin/sh\n%s\necho two' "$HOOK_TEST_OLD_GATE_CI" > .git/hooks/pre-push
  chmod 755 .git/hooks/pre-push
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks: $OUT"
  hooks_expect .git/hooks/pre-push $'#!/bin/sh\n'"$HOOK_TEST_GATE_CI"$'\necho two'
  printf '#!/bin/sh\necho one\n%s' "$HOOK_TEST_OLD_GATE_CI" > .git/hooks/pre-push
  run "$G" install-hooks
  hooks_expect .git/hooks/pre-push $'#!/bin/sh\necho one\n'"$HOOK_TEST_GATE_CI"
}

# C4 (final review B): monorepo `prepare` scripts run install and install-hooks at the same
# time. Unserialised, the runs overwrote each other's edit of a hook: the project's own body
# was lost in 6 of 30 runs and the gate line doubled in 6 of 30. A mkdir lock under the git
# common dir makes the runs take turns; the loser waits and then finds the work done.
# shellcheck disable=SC2016 # the hook text holds $(...) that must not expand here
test_parallel_install_hooks_keep_every_hook_body_and_add_one_gate_line() {
  hooks_repo "$TMP/repo"
  must git config core.hooksPath .husky
  must mkdir .husky
  printf '#!/bin/sh\n. "$(dirname "$0")/_/husky.sh"\nnpx lint-staged\n' > .husky/pre-commit
  printf '#!/bin/sh\n. "$(dirname "$0")/_/husky.sh"\nnpm test\n' > .husky/pre-push
  chmod 755 .husky/pre-commit .husky/pre-push
  hooks_vendor
  hooks_parallel 8 "$G" install-hooks
  hooks_expect .husky/pre-commit $'#!/bin/sh\n'"$HOOK_TEST_GATE_STAGED"$'\n. "$(dirname "$0")/_/husky.sh"\nnpx lint-staged\n'
  hooks_expect .husky/pre-push $'#!/bin/sh\n'"$HOOK_TEST_GATE_CI"$'\n. "$(dirname "$0")/_/husky.sh"\nnpm test\n'
  [ ! -e .git/gauntlet-install.lock ] || fail "the lock is still there after every run ended"
}

# The same race for install: .gauntlet/lib came out empty, .gauntlet/bin held a bin, the hooks
# had two gate lines. The result must be what one install gives.
test_parallel_install_leaves_one_complete_runner() {
  hooks_repo "$TMP/repo"
  hooks_parallel 8 "$G" install
  [ ! -e .gauntlet/bin/bin ] || fail "install nested .gauntlet/bin/bin"
  diff -r "$ROOT/bin" .gauntlet/bin || fail ".gauntlet/bin differs from the checkout's bin"
  diff -r "$ROOT/lib" .gauntlet/lib || fail ".gauntlet/lib differs from the checkout's lib"
  assert_eq "" "$(find .gauntlet -name '.*.new' -o -name '.*.old' | tr '\n' ' ')" "copies left behind"
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_STAGED" .git/hooks/pre-commit)" "pre-commit gate lines"
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_CI" .git/hooks/pre-push)" "pre-push gate lines"
  [ ! -e .git/gauntlet-install.lock ] || fail "the lock is still there after every run ended"
}

# A command that finds the lock held waits, says so, and carries on once it is free: a
# parallel `prepare` script must not fail `npm install`.
test_a_held_lock_makes_install_hooks_wait_and_then_succeed() {
  hooks_repo "$TMP/repo"
  hooks_vendor
  must mkdir .git/gauntlet-install.lock
  "$G" install-hooks > "$TMP/out" 2> "$TMP/err" &
  local pid=$!
  hooks_wait_for "$TMP/err" "waiting for another install"
  assert_contains "$(cat "$TMP/err")" ".git/gauntlet-install.lock"
  [ ! -e .git/hooks/pre-commit ] || fail "a hook was written while the lock was held"
  must rmdir .git/gauntlet-install.lock
  local status=0
  wait "$pid" || status=$?
  assert_eq 0 "$status" "install-hooks after the lock was freed: $(cat "$TMP/out" "$TMP/err")"
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_STAGED" .git/hooks/pre-commit)" "the hook was written once the lock was free"
  [ ! -e .git/gauntlet-install.lock ] || fail "the lock is still there after the run ended"
}

# A lock nobody owns (its owner was killed hard) is not broken by a guess: after the bound the
# command exits 2 and names the path. The bound is GAUNTLET_LOCK_WAIT seconds, 30 by default.
# The lock is not ours, so it stays.
test_a_stale_lock_ends_in_exit_2_naming_the_lock_and_stays() {
  hooks_repo "$TMP/repo"
  hooks_vendor
  must mkdir .git/gauntlet-install.lock
  run env GAUNTLET_LOCK_WAIT=1 "$G" install-hooks
  assert_eq 2 "$STATUS" "install-hooks with a stale lock: $OUT"
  assert_contains "$OUT" "gauntlet: another install holds $TMP/repo/.git/gauntlet-install.lock; if none is running, remove it"
  [ -d .git/gauntlet-install.lock ] || fail "a process that did not own the lock removed it"
  [ ! -e .git/hooks/pre-commit ] || fail "a hook was written without the lock"
  run env GAUNTLET_LOCK_WAIT=1 "$G" install
  assert_eq 2 "$STATUS" "install with a stale lock: $OUT"
  assert_contains "$OUT" "another install holds"
  [ -d .git/gauntlet-install.lock ] || fail "install removed a lock it did not own"
}

test_the_lock_wait_must_be_a_whole_number_of_seconds() {
  hooks_repo "$TMP/repo"
  hooks_vendor
  run env GAUNTLET_LOCK_WAIT=soon "$G" install-hooks
  assert_eq 2 "$STATUS" "install-hooks: $OUT"
  assert_contains "$OUT" "gauntlet: GAUNTLET_LOCK_WAIT must be a whole number of seconds, got [soon]"
}

# A linked worktree shares the common git dir, so the lock must be there and not in the
# worktree's own git dir: two worktrees edit the same hooks.
test_the_lock_is_in_the_common_git_dir_of_a_linked_worktree() {
  hooks_repo "$TMP/repo"
  must git worktree add -q "$TMP/wt" -b side
  must mkdir "$TMP/repo/.git/gauntlet-install.lock"
  must cd "$TMP/wt"
  hooks_vendor
  run env GAUNTLET_LOCK_WAIT=0 "$G" install-hooks
  assert_eq 2 "$STATUS" "install-hooks in the worktree: $OUT"
  assert_contains "$OUT" "$TMP/repo/.git/gauntlet-install.lock"
}

# A git dir that cannot be written is not a lock to wait for: the command says it could not make
# the lock, at once. The permission is restored before anything is asserted.
test_an_unwritable_git_dir_is_an_error_not_a_wait() {
  hooks_repo "$TMP/repo"
  if hooks_as_root; then
    skip "running as root: a directory is writable here whatever its mode"
    return 77
  fi
  hooks_vendor
  must chmod 555 .git
  run env GAUNTLET_LOCK_WAIT=30 "$G" install-hooks
  chmod 755 .git
  assert_eq 2 "$STATUS" "install-hooks: $OUT"
  assert_contains "$OUT" "gauntlet: cannot create $TMP/repo/.git/gauntlet-install.lock"
  assert_not_contains "$OUT" "waiting"
}

# I1 (final review B): a root .gitignore with bin/ or lib/ hid the vendored runner, so a clone
# had hooks that called a runner it did not have. install writes .gauntlet/.gitignore: STATUS.md
# (the derived file) is ignored, and bin/ and lib/ are brought back whatever a shallower
# ignore says, down to the files in them (a root *.sh would otherwise still hide lib/*.sh).
HOOK_TEST_GITIGNORE=$'STATUS.md\n!bin/\n!lib/\n!bin/**\n!lib/**\n'

test_install_writes_the_gauntlet_gitignore_and_keeps_an_existing_one() {
  hooks_repo "$TMP/repo"
  run "$G" install
  assert_eq 0 "$STATUS" "install: $OUT"
  assert_contains "$OUT" "created .gauntlet/.gitignore"
  hooks_expect .gauntlet/.gitignore "$HOOK_TEST_GITIGNORE"
  printf 'STATUS.md\nmine\n' > .gauntlet/.gitignore
  run "$G" install
  assert_eq 0 "$STATUS" "second install: $OUT"
  assert_not_contains "$OUT" ".gauntlet/.gitignore"
  hooks_expect .gauntlet/.gitignore $'STATUS.md\nmine\n'
}

test_a_root_ignore_of_bin_lib_and_shell_files_does_not_hide_the_runner() {
  hooks_repo "$TMP/repo"
  printf 'bin/\nlib/\n*.sh\n*.md\n' > .gitignore
  run "$G" install
  assert_eq 0 "$STATUS" "install: $OUT"
  run git status --porcelain --untracked-files=all
  assert_contains "$OUT" "?? .gauntlet/bin/gauntlet"
  assert_contains "$OUT" "?? .gauntlet/lib/core.sh"
  assert_contains "$OUT" "?? .gauntlet/lib/formats/path-line.md"
  printf 'x\n' > .gauntlet/STATUS.md
  run git check-ignore -q .gauntlet/STATUS.md
  assert_eq 0 "$STATUS" "STATUS.md is ignored by .gauntlet/.gitignore"
}

# R36: one script that serves both hooks (a symlink, a hard link) would get two gate lines, or the
# wrong command in one of the two hooks. install-hooks leaves it alone, says why, and prints the
# lines to add: each gate inside a test on the hook's name.
# shellcheck disable=SC2016 # shell text for a hook: ${0##*/} is expanded when the hook runs
HOOK_TEST_GUARD_STAGED='if [ "${0##*/}" = pre-commit ]; then'
# shellcheck disable=SC2016 # as above
HOOK_TEST_GUARD_CI='if [ "${0##*/}" = pre-push ]; then'

# one_script_repo <symlink|hardlink>: .git/hooks/pre-push is the same file as pre-commit.
one_script_repo() {
  hooks_repo "$TMP/repo"
  hooks_vendor
  printf '#!/bin/sh\necho shared\n' > .git/hooks/pre-commit
  chmod 755 .git/hooks/pre-commit
  case "$1" in
    symlink) must ln -s pre-commit .git/hooks/pre-push ;;
    hardlink)
      ln .git/hooks/pre-commit .git/hooks/pre-push 2> /dev/null || return 77
      ;;
  esac
}

one_script_case() {
  local before
  one_script_repo "$1" || { skip "this filesystem refuses a $1"; return 77; }
  before=$(hooks_sum .git/hooks/pre-commit)
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks: $OUT"
  assert_contains "$OUT" "ACTION NEEDED: .git/hooks/pre-commit and .git/hooks/pre-push are the same file"
  assert_contains "$OUT" "would run in both hooks"
  assert_contains "$OUT" "Add to .git/hooks/pre-commit, as the first commands"
  assert_contains "$OUT" "$HOOK_TEST_GUARD_STAGED"$'\n'"$HOOK_TEST_GATE_STAGED"$'\nfi\n'"$HOOK_TEST_GUARD_CI"$'\n'"$HOOK_TEST_GATE_CI"$'\nfi'
  assert_eq "$before" "$(hooks_sum .git/hooks/pre-commit)" "the shared script is not edited"
  [ .git/hooks/pre-commit -ef .git/hooks/pre-push ] || fail "the two hooks are no longer one file"
}

test_a_symlinked_hook_pair_is_print_only() {
  one_script_case symlink
  [ -L .git/hooks/pre-push ] || fail "the link was replaced"
}

test_a_hard_linked_hook_pair_is_print_only() {
  one_script_case hardlink
}

test_install_prints_for_a_shared_script_and_edits_nothing_else() {
  hooks_repo "$TMP/repo"
  printf '#!/bin/sh\necho shared\n' > .git/hooks/pre-commit
  chmod 755 .git/hooks/pre-commit
  must ln -s pre-commit .git/hooks/pre-push
  run "$G" install
  assert_eq 0 "$STATUS" "install: $OUT"
  assert_contains "$OUT" "are the same file"
  hooks_expect .git/hooks/pre-commit $'#!/bin/sh\necho shared\n'
  [ -f .gauntlet/bin/gauntlet ] || fail "the runner was not vendored"
}

test_a_shared_script_with_both_guarded_gates_is_already_present() {
  one_script_repo symlink
  printf '#!/bin/sh\n%s\n%s\nfi\n%s\n%s\nfi\necho shared\n' "$HOOK_TEST_GUARD_STAGED" "$HOOK_TEST_GATE_STAGED" "$HOOK_TEST_GUARD_CI" "$HOOK_TEST_GATE_CI" > .git/hooks/pre-commit
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks: $OUT"
  assert_contains "$OUT" "already present in .git/hooks/pre-commit"
  assert_not_contains "$OUT" "ACTION NEEDED"
}

# The state an older install-hooks made of such a pair: both gates, unguarded, in both hooks.
test_a_shared_script_with_unguarded_gates_still_gets_the_advice() {
  one_script_repo symlink
  printf '#!/bin/sh\n%s\n%s\n' "$HOOK_TEST_GATE_CI" "$HOOK_TEST_GATE_STAGED" > .git/hooks/pre-commit
  run "$G" install-hooks
  assert_contains "$OUT" "ACTION NEEDED"
}

test_a_symlinked_pair_in_a_husky_directory_is_print_only() {
  hooks_repo "$TMP/repo"
  hooks_vendor
  must git config core.hooksPath .husky
  must mkdir .husky
  printf '#!/bin/sh\nnpx lint-staged\n' > .husky/pre-commit
  chmod 755 .husky/pre-commit
  must ln -s pre-commit .husky/pre-push
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks: $OUT"
  assert_contains "$OUT" "ACTION NEEDED: .husky/pre-commit and .husky/pre-push are the same file"
  hooks_expect .husky/pre-commit $'#!/bin/sh\nnpx lint-staged\n'
}

# A hook that is only a link to another hook file is not one script serving both.
test_two_different_files_are_edited_as_before() {
  hooks_repo "$TMP/repo"
  hooks_vendor
  printf '#!/bin/sh\necho a\n' > .git/hooks/pre-commit
  printf '#!/bin/sh\necho b\n' > .git/hooks/real-pre-push
  chmod 755 .git/hooks/pre-commit .git/hooks/real-pre-push
  must ln -s real-pre-push .git/hooks/pre-push
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks: $OUT"
  assert_not_contains "$OUT" "same file"
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_GATE_STAGED" .git/hooks/pre-commit)" "pre-commit gate"
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_GATE_CI" .git/hooks/real-pre-push)" "pre-push gate in the link's target"
}

# The lines install-hooks prints work: pasted into the shared script, they gate a commit through
# pre-commit and a push through pre-push, each with its own command.
test_the_lines_printed_for_a_shared_script_gate_both_hooks() {
  hooks_repo "$TMP/repo"
  must git init -q --bare "$TMP/remote.git"
  must git remote add origin "$TMP/remote.git"
  run "$G" install
  assert_eq 0 "$STATUS" "install: $OUT"
  rule todo format=path-line
  must git add -A
  run git commit -q -m "add the rule"
  assert_eq 0 "$STATUS" "commit of the rule: $OUT"
  must rm .git/hooks/pre-commit .git/hooks/pre-push
  printf '#!/bin/sh\necho shared\n' > .git/hooks/pre-commit
  chmod 755 .git/hooks/pre-commit
  must ln -s pre-commit .git/hooks/pre-push
  run "$G" install-hooks
  assert_contains "$OUT" "ACTION NEEDED"
  printf '#!/bin/sh\n%s\necho shared\n' "$(printf '%s\n' "$OUT" | sed -n '/^if \[ /,$p')" > .git/hooks/pre-commit
  run "$G" install-hooks
  assert_contains "$OUT" "already present in .git/hooks/pre-commit"
  run git push -q origin main
  assert_eq 0 "$STATUS" "push of main through the shared script: $OUT"
  must git checkout -q -b feat
  printf 'TODO fix me\n' > a.txt
  must git add a.txt
  run git commit -q -m "add a violation"
  if [ "$STATUS" -eq 0 ]; then fail "the shared script did not block the commit: $OUT"; fi
  run git commit -q --no-verify -m "add a violation"
  assert_eq 0 "$STATUS" "commit with --no-verify: $OUT"
  run git push -q origin feat
  if [ "$STATUS" -eq 0 ]; then fail "the shared script did not block the push: $OUT"; fi
}

# A shared hooks directory (outside the repo) is printed for, never edited; a symlinked pair in it
# gets the same one-script advice, not two lines that each run in both hooks.
test_a_symlinked_pair_in_a_shared_hooks_dir_gets_the_one_script_advice() {
  hooks_repo "$TMP/repo"
  hooks_vendor
  must mkdir "$TMP/shared"
  printf '#!/bin/sh\necho shared\n' > "$TMP/shared/pre-commit"
  chmod 755 "$TMP/shared/pre-commit"
  must ln -s pre-commit "$TMP/shared/pre-push"
  must git config core.hooksPath "$TMP/shared"
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks: $OUT"
  assert_contains "$OUT" "ACTION NEEDED: $TMP/shared/pre-commit and $TMP/shared/pre-push are the same file"
  assert_eq 1 "$(printf '%s\n' "$OUT" | grep -c 'ACTION NEEDED')" "one piece of advice"
  hooks_expect "$TMP/shared/pre-commit" $'#!/bin/sh\necho shared\n'
}

# Both tests on the hook's name are needed: a gate guarded for one hook and bare for the other
# still runs in the wrong hook.
test_a_shared_script_missing_one_guard_still_gets_the_advice() {
  one_script_repo symlink
  printf '#!/bin/sh\n%s\n%s\nfi\n%s\n' "$HOOK_TEST_GUARD_STAGED" "$HOOK_TEST_GATE_STAGED" "$HOOK_TEST_GATE_CI" > .git/hooks/pre-commit
  run "$G" install-hooks
  assert_contains "$OUT" "ACTION NEEDED"
  printf '#!/bin/sh\n%s\n%s\n%s\nfi\n' "$HOOK_TEST_GATE_STAGED" "$HOOK_TEST_GUARD_CI" "$HOOK_TEST_GATE_CI" > .git/hooks/pre-commit
  run "$G" install-hooks
  assert_contains "$OUT" "ACTION NEEDED"
}
