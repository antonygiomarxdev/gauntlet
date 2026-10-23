# shellcheck shell=bash
# shellcheck disable=SC2153 # ROOT, G and STATUS are set by test/lib.sh
# Tests for install and install-hooks: the runner is vendored into .gauntlet/,
# each existing hook gets one gauntlet line (before a final exit), husky,
# lefthook, prek and custom hooks paths each get their own handling, and nothing
# outside the hooks and the state files is ever changed. Each test runs in a
# fresh repo under $TMP.

HOOK_TEST_STAGED='.gauntlet/bin/gauntlet check --staged  # gauntlet'
HOOK_TEST_CI='.gauntlet/bin/gauntlet check --ci  # gauntlet'

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
  local want=$'#!/bin/sh\necho one\necho two\n'"$HOOK_TEST_STAGED"$'\n'
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
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_STAGED" .git/hooks/pre-commit)" "the gate line was added"
  assert_eq 1 "$(hooks_lines "echo tidy  # gauntlet" .git/hooks/pre-commit)" "the other line is kept once"
}

test_insert_before_exit() {
  hooks_repo "$TMP/repo"
  printf '#!/bin/sh\necho one\n  exit 0   \n\n' > .git/hooks/pre-commit
  chmod 755 .git/hooks/pre-commit
  local want=$'#!/bin/sh\necho one\n'"$HOOK_TEST_STAGED"$'\n  exit 0   \n\n'
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "first install-hooks"
  hooks_expect .git/hooks/pre-commit "$want"
  if [ ! -x .git/hooks/pre-commit ]; then fail "the hook lost its exec bit"; fi
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "second install-hooks"
  hooks_expect .git/hooks/pre-commit "$want"
}

test_insert_before_exit_without_newline() {
  hooks_repo "$TMP/repo"
  printf '#!/bin/sh\necho two\nexit 0' > .git/hooks/pre-push
  chmod 644 .git/hooks/pre-push
  local want=$'#!/bin/sh\necho two\n'"$HOOK_TEST_CI"$'\nexit 0\n'
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "first install-hooks"
  hooks_expect .git/hooks/pre-push "$want"
  if [ -x .git/hooks/pre-push ]; then fail "an existing hook gained the exec bit"; fi
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "second install-hooks"
  hooks_expect .git/hooks/pre-push "$want"
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
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_STAGED" .husky/pre-commit)" "pre-commit line"
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
  local want=$'#!/bin/sh\nnpm test\n'"$HOOK_TEST_STAGED"$'\n'
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
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_STAGED" .husky/pre-commit)" "one pre-commit line"
}

# husky configured but its directory not there yet: both hooks are created.
test_husky_creates_missing_directory() {
  hooks_repo "$TMP/repo"
  must git config core.hooksPath .husky
  run "$G" install-hooks
  assert_eq 0 "$STATUS" "install-hooks"
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_STAGED" .husky/pre-commit)" "pre-commit line"
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_CI" .husky/pre-push)" "pre-push line"
  assert_eq "#!/usr/bin/env sh" "$(head -n 1 .husky/pre-push)" "created hook starts with the shebang"
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
  assert_contains "$OUT" "run: .gauntlet/bin/gauntlet check --ci"
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
  assert_contains "$OUT" "entry: .gauntlet/bin/gauntlet check --ci"
  assert_eq "$config" "$(hooks_sum .pre-commit-config.yaml)" "the config is unchanged"
  assert_eq "$hooks" "$(hooks_sum .git/hooks)" "no hook was written"
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
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_STAGED" .git/hooks/pre-commit)" "one pre-commit line"
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

test_custom_hookspath_relative() {
  hooks_repo "$TMP/repo"
  must mkdir -p tools/hooks
  printf '#!/bin/sh\necho custom\n' > tools/hooks/pre-commit
  must git config core.hooksPath tools/hooks
  local plain
  plain=$(hooks_sum .git/hooks)
  run "$G" install
  assert_eq 0 "$STATUS" "install"
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_STAGED" tools/hooks/pre-commit)" "pre-commit line"
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_CI" tools/hooks/pre-push)" "pre-push line"
  assert_eq "$plain" "$(hooks_sum .git/hooks)" ".git/hooks is untouched"
}

test_custom_hookspath_absolute() {
  hooks_repo "$TMP/repo"
  # The directory does not exist yet: install creates it.
  local dir="$TMP/hook dir"
  must git config core.hooksPath "$dir"
  run "$G" install
  assert_eq 0 "$STATUS" "install"
  if [ ! -d "$dir" ]; then fail "the hooksPath directory was not created"; fi
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_STAGED" "$dir/pre-commit")" "pre-commit line"
  assert_eq 1 "$(hooks_lines "$HOOK_TEST_CI" "$dir/pre-push")" "pre-push line"
  assert_eq "$dir" "$(git config --get core.hooksPath)" "absolute hooksPath is kept"
  if [ -e .git/hooks/pre-commit ]; then fail "the hooks went to .git/hooks"; fi
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

# A rule committed on its own first: a rule that is new in the commit that
# carries its violation is exempt from the new check, so the violation must come
# in a later commit.
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
