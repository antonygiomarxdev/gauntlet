# shellcheck shell=bash
# shellcheck disable=SC2153 # ROOT and G are set by test/lib.sh
# End-to-end tests of the whole runner. Each test makes a fresh repo whose path has
# a space, installs the runner from this checkout (install is the only command run
# from $G), then runs every other command through the vendored copy,
# .gauntlet/bin/gauntlet, and makes real git commits, so the hooks that install wrote
# are the ones that run. Each test lives under $TMP, which test/run.sh removes.
# The rules use rg, as the rest of the suite does: the rule helper in lib.sh defaults
# to rg, and no test skips when rg is missing.

E2E_GATE_STAGED='.gauntlet/bin/gauntlet check --staged || exit $?  # gauntlet'
E2E_LINE_STAGED='.gauntlet/bin/gauntlet check --staged  # gauntlet'
# The pre-push text has one source, lib/hooks.sh; the tests read it there and never paste it.
E2E_LINE_CI=$(hook_const HOOK_LINE_CI)
E2E_GATE_CI=$(hook_const HOOK_GATE_CI)
E2E_CMD_CI=$(hook_const GAUNTLET_CMD_CI)

# e2e_repo: a fresh repo at "$TMP/my repo" on main with one commit made before any
# gauntlet state exists, then cd into it.
e2e_repo() {
  must mkdir -p "$TMP/my repo"
  must cd "$TMP/my repo"
  must git init -q .
  must git symbolic-ref HEAD refs/heads/main
  must git config user.name "Test User"
  must git config user.email "test@example.com"
  must git config commit.gpgsign false
  printf 'hello\n' > README.md
  must git add README.md
  must git commit -q -m "chore: init"
}

# e2e_install: run the checkout's installer in the current repo. This is the one
# command that is not run through the vendored copy.
e2e_install() {
  run "$G" install
  assert_eq 0 "$STATUS" "install: $OUT"
}

# e2e_gl <args...>: run the vendored runner from the repo root.
e2e_gl() {
  run .gauntlet/bin/gauntlet "$@"
}

# e2e_todo [key=value...]: the rg rule `todo` over **/*.ts with its bad and good cases.
e2e_todo() {
  rule todo paths='**/*.ts' "$@"
  cases_of todo 'TODO x'
}

# e2e_baseline: stage everything, measure, then stage the new baseline too. A file
# counts only once it is in the index, so the first stage comes before the measure;
# the second keeps the index's copy of baseline.tsv equal to the working tree's.
e2e_baseline() {
  must git add -A
  e2e_gl baseline
  assert_eq 0 "$STATUS" "baseline: $OUT"
  must git add -A
}

# e2e_head_baseline: the baseline HEAD carries.
e2e_head_baseline() {
  git show "HEAD:.gauntlet/baseline.tsv"
}

# e2e_debt_total <baseline>: the sum of the counts in a baseline file.
e2e_debt_total() {
  awk -F '\t' '{ n += $4 } END { print n + 0 }' "$1"
}

# e2e_count_line <line> <file>: how many lines of <file> are exactly <line>.
e2e_count_line() {
  grep -Fxc -- "$1" "$2" || true
}

# e2e_expect <file> <content>: fail unless <file> holds exactly <content>, byte for byte.
e2e_expect() {
  printf '%s' "$2" > "$TMP/expect" || fail "cannot write the expectation"
  cmp -s "$TMP/expect" "$1" || fail "$1 differs from the expected bytes; it holds: $(cat "$1")"
}

# e2e_every_line_ok <doctor-output>: every line is an "ok <thing>" line, and the
# runner line is among them. The output goes to a file first, so an empty output fails.
e2e_every_line_ok() {
  printf '%s\n' "$1" > "$TMP/doctor.out" || fail "cannot write the doctor output"
  awk '!/^ok / { bad = 1 } END { exit bad }' "$TMP/doctor.out" \
    || fail "doctor printed a line that is not ok: $1"
  assert_contains "$1" "ok runner .gauntlet/bin/gauntlet"
}

# e2e_tree_hash: the tree hash of the working tree with .git left out. A temporary
# index stages every file, and write-tree names the tree (modes and bytes included).
e2e_tree_hash() {
  rm -f "$TMP/tree.idx"
  GIT_INDEX_FILE="$TMP/tree.idx" git add -A || fail "cannot stage the tree"
  GIT_INDEX_FILE="$TMP/tree.idx" git write-tree || fail "cannot write the tree"
}

test_full_lifecycle() {
  e2e_repo

  # 1. install into a fresh repo: the hooks, then the vendored runner and its state.
  e2e_install
  assert_contains "$OUT" "vendored runner to .gauntlet/"
  if [ ! -x .git/hooks/pre-commit ]; then fail "pre-commit is not executable"; fi
  if [ ! -x .git/hooks/pre-push ]; then fail "pre-push is not executable"; fi
  assert_eq 1 "$(e2e_count_line "$E2E_LINE_STAGED" .git/hooks/pre-commit)" "pre-commit gate line"
  assert_eq 1 "$(e2e_count_line "$E2E_LINE_CI" .git/hooks/pre-push)" "pre-push gate line"
  run cmp -s "$ROOT/bin/gauntlet" .gauntlet/bin/gauntlet
  assert_eq 0 "$STATUS" "the vendored runner is the checkout's bin/gauntlet"
  run diff -r "$ROOT/lib" .gauntlet/lib
  assert_eq 0 "$STATUS" "the vendored lib is the checkout's lib: $OUT"
  if [ ! -x .gauntlet/bin/gauntlet ]; then fail "the vendored runner is not executable"; fi
  e2e_expect .gauntlet/baseline.tsv ""
  e2e_expect .gauntlet/exceptions.tsv $'type\ttarget\treason\tdate\tbranch\n'
  e2e_expect .gauntlet/config $'touched=off\n'
  if [ ! -d .gauntlet/rules ]; then fail "missing .gauntlet/rules"; fi
  assert_eq "" "$(ls -d .gauntlet/.*.new .gauntlet/.*.old 2>/dev/null)" "no half-swapped copy is left"

  # 2. an rg rule with its bad and good cases; test-rules passes.
  e2e_todo
  e2e_gl test-rules
  assert_eq 0 "$STATUS" "test-rules: $OUT"

  # 3. baseline on main, committed through the hooks.
  printf 'TODO old one\n' > a.ts
  printf 'TODO old two\n' > c.ts
  e2e_baseline
  assert_eq 2 "$(e2e_debt_total .gauntlet/baseline.tsv)" "two old violations are in the baseline"
  run git commit -q -m "chore: add the gate"
  assert_eq 0 "$STATUS" "commit on main: $OUT"
  assert_contains "$OUT" "note: no baseline at HEAD"
  assert_contains "$OUT" "gauntlet: ok"

  # 4. branch f: a new violation is blocked, the fix passes, and removing old debt
  # lowers the baseline in the same commit, staged by hand and by commit -a.
  must git checkout -q -b f
  printf 'TODO fresh\n' > b.ts
  must git add b.ts
  local before
  before=$(git rev-parse HEAD)
  run git commit -q -m "feat: add b"
  assert_eq 1 "$STATUS" "blocked commit status: $OUT"
  assert_contains "$OUT" "  b.ts:1  todo  TODO fresh"
  assert_contains "$OUT" "fix: remove it"
  assert_eq "$before" "$(git rev-parse HEAD)" "HEAD after the blocked commit"

  printf 'ok\n' > b.ts
  must git add b.ts
  run git commit -q -m "fix: remove the fresh todo"
  assert_eq 0 "$STATUS" "the fix commit: $OUT"

  printf 'ok\n' > a.ts
  must git add a.ts
  run git commit -q -m "fix: remove the old a todo"
  assert_eq 0 "$STATUS" "commit that removes a.ts debt: $OUT"
  assert_contains "$(git show --stat --format= HEAD)" ".gauntlet/baseline.tsv"
  assert_not_contains "$(e2e_head_baseline)" "a.ts"
  assert_eq "" "$(git status --short)" "clean tree after the commit"

  printf 'ok\n' > c.ts
  run git commit -q -a -m "fix: remove the old c todo"
  assert_eq 0 "$STATUS" "commit -a that removes c.ts debt: $OUT"
  assert_contains "$(git show --stat --format= HEAD)" ".gauntlet/baseline.tsv"
  assert_eq "" "$(e2e_head_baseline)" "the baseline at HEAD is empty"
  assert_eq "" "$(git status --short)" "clean tree after commit -a"

  e2e_gl check --ci --base main
  assert_eq 0 "$STATUS" "check --ci --base main: $OUT"
  assert_contains "$OUT" "gauntlet: ok"

  # 5. lower the severity: check --ci fails and names the rule; a loosen row, committed,
  # makes it pass.
  e2e_todo severity=shadow
  must git add -A
  run git commit -q -m "chore: lower todo to shadow"
  assert_eq 0 "$STATUS" "commit that lowers the severity: $OUT"
  e2e_gl check --ci --base main
  assert_eq 1 "$STATUS" "check --ci after lowering: $OUT"
  assert_contains "$OUT" "[loosened]"
  assert_contains "$OUT" "  todo  severity block → shadow"
  e2e_gl loosen todo "stays shadow for one more sprint" "the rule needs a week of data"
  assert_eq 0 "$STATUS" "loosen: $OUT"
  must git add -A
  run git commit -q -m "chore: record the loosening"
  assert_eq 0 "$STATUS" "commit of the loosen row: $OUT"
  e2e_gl check --ci --base main
  assert_eq 0 "$STATUS" "check --ci with the committed loosen row: $OUT"
  assert_contains "$OUT" "gauntlet: ok"

  # 6. doctor: every line is ok, and it exits 0.
  e2e_gl doctor
  assert_eq 0 "$STATUS" "doctor: $OUT"
  e2e_every_line_ok "$OUT"
}

test_waive_lifecycle() {
  e2e_repo
  e2e_install
  e2e_todo
  printf 'TODO legacy\n' > legacy.ts
  e2e_baseline
  run git commit -q -m "chore: add the gate"
  assert_eq 0 "$STATUS" "commit on main: $OUT"

  # Debt that cannot be paid on this branch: the new violation blocks, a waiver for
  # the file on this branch lets the commit through.
  must git checkout -q -b w
  printf 'TODO legacy\nTODO new\n' > legacy.ts
  must git add legacy.ts
  run git commit -q -m "feat: add debt"
  assert_eq 1 "$STATUS" "blocked before the waiver: $OUT"
  assert_contains "$OUT" "  legacy.ts:2  todo  TODO new"

  e2e_gl waive legacy.ts "legacy file, owned by another team"
  assert_eq 0 "$STATUS" "waive: $OUT"
  must git add -A
  run git commit -q -m "feat: add debt with a waiver"
  assert_eq 0 "$STATUS" "commit with the waiver: $OUT"
  assert_contains "$OUT" "gauntlet: ok"
  assert_eq "" "$(git status --short)" "clean tree after the waiver commit"

  e2e_gl doctor
  assert_eq 0 "$STATUS" "doctor on the waiver's branch: $OUT"
  assert_contains "$OUT" "ok no stale waivers"

  # Another branch, cut from w, carries the row. The row names w, so it does nothing here.
  must git checkout -q -b x
  e2e_gl doctor
  assert_eq 0 "$STATUS" "doctor on another branch: $OUT"
  assert_contains "$OUT" "stale waive legacy.ts (branch w)"
  assert_not_contains "$OUT" "FAIL"

  printf 'TODO legacy\nTODO new\nTODO third\n' > legacy.ts
  must git add legacy.ts
  run git commit -q -m "feat: more debt on x"
  assert_eq 1 "$STATUS" "the waiver does not apply on x: $OUT"
  assert_contains "$OUT" "  legacy.ts:3  todo  TODO third"
}

test_rename_carries_debt() {
  e2e_repo
  e2e_install
  e2e_todo
  printf 'TODO old\n' > a.ts
  e2e_baseline
  run git commit -q -m "chore: add the gate"
  assert_eq 0 "$STATUS" "commit on main: $OUT"

  must git checkout -q -b r
  must git mv a.ts renamed.ts
  run git commit -q -m "refactor: rename a.ts"
  assert_eq 0 "$STATUS" "rename commit: $OUT"
  assert_contains "$OUT" "gauntlet: ok"
  assert_eq "" "$(git status --short)" "clean tree after the rename"
  assert_contains "$(e2e_head_baseline)" "renamed.ts"
  assert_not_contains "$(e2e_head_baseline)" "a.ts"

  e2e_gl check --ci --base main
  assert_eq 0 "$STATUS" "check --ci --base main after the rename: $OUT"
}

test_stack_base() {
  e2e_repo
  e2e_install
  e2e_todo
  printf 'TODO old\n' > a.ts
  e2e_baseline
  run git commit -q -m "chore: add the gate"
  assert_eq 0 "$STATUS" "commit on main: $OUT"

  # a adds debt on purpose and waives it on its own branch.
  must git checkout -q -b a
  printf 'TODO old\nTODO a-new\n' > a.ts
  e2e_gl waive a.ts "branch a takes this debt on purpose"
  assert_eq 0 "$STATUS" "waive on a: $OUT"
  must git add -A
  run git commit -q -m "feat: a adds debt"
  assert_eq 0 "$STATUS" "commit on a: $OUT"

  # b is stacked on a and adds a clean file of its own.
  must git checkout -q -b b
  printf 'ok\n' > c.ts
  must git add c.ts
  run git commit -q -m "feat: b adds c"
  assert_eq 0 "$STATUS" "commit on b: $OUT"

  # Against main, b also carries a's debt, and a's waiver is not b's.
  e2e_gl check --ci
  assert_eq 1 "$STATUS" "check --ci against main: $OUT"
  assert_contains "$OUT" "  a.ts:2  todo  TODO a-new"

  e2e_gl base a
  assert_eq 0 "$STATUS" "base a: $OUT"
  e2e_gl base
  assert_eq a "$OUT" "base reports a"

  e2e_gl check --ci
  assert_eq 0 "$STATUS" "check --ci judges only b's changes: $OUT"
  assert_contains "$OUT" "gauntlet: ok"
}

test_existing_husky_coexists() {
  e2e_repo
  must mkdir -p .husky
  printf '#!/bin/sh\necho project-hook-ran\n' > .husky/pre-commit
  must chmod +x .husky/pre-commit
  must git config core.hooksPath .husky

  e2e_install
  assert_contains "$OUT" "added gauntlet line to .husky/pre-commit"
  local want=$'#!/bin/sh\n'"$E2E_GATE_STAGED"$'\necho project-hook-ran\n'
  e2e_expect .husky/pre-commit "$want"
  assert_eq ".husky" "$(git config core.hooksPath)" "core.hooksPath after install"

  # A clean commit passes the gate, and the project's own line still runs after it.
  e2e_todo
  printf 'TODO old\n' > a.ts
  e2e_baseline
  run git commit -q -m "chore: add the gate"
  assert_eq 0 "$STATUS" "clean commit on main: $OUT"
  assert_contains "$OUT" "project-hook-ran"
  assert_contains "$OUT" "gauntlet: ok"

  # A violating commit is blocked by the gate, which runs first: the project's line never runs.
  printf 'TODO old\nTODO new\n' > a.ts
  must git add a.ts
  local before
  before=$(git rev-parse HEAD)
  run git commit -q -m "feat: add debt"
  assert_eq 1 "$STATUS" "blocked commit: $OUT"
  assert_contains "$OUT" "  a.ts:2  todo  TODO new"
  assert_not_contains "$OUT" "project-hook-ran"
  assert_eq "$before" "$(git rev-parse HEAD)" "HEAD after the blocked commit"

  must git checkout -q HEAD -- a.ts
  printf 'hello again\n' > README.md
  must git add README.md
  run git commit -q -m "docs: touch the readme"
  assert_eq 0 "$STATUS" "clean commit: $OUT"
  assert_contains "$OUT" "project-hook-ran"
  assert_contains "$OUT" "gauntlet: ok"
  assert_eq "" "$(git status --short)" "clean tree"
  assert_eq ".husky" "$(git config core.hooksPath)" "core.hooksPath after the commits"
}

test_second_install_is_a_no_op() {
  e2e_repo
  e2e_install
  local tree1 tree2 hook1 hook2
  tree1=$(e2e_tree_hash)
  [ -n "$tree1" ] || fail "no tree hash after the first install"
  hook1=$(cat .git/hooks/pre-commit)

  run "$G" install
  assert_eq 0 "$STATUS" "second install: $OUT"
  assert_contains "$OUT" "already present in .git/hooks/pre-commit"
  tree2=$(e2e_tree_hash)
  assert_eq "$tree1" "$tree2" "tree hash after a second install"
  hook2=$(cat .git/hooks/pre-commit)
  assert_eq "$hook1" "$hook2" "pre-commit after a second install"

  # The vendored runner can run install itself: it finds its own copy and changes nothing.
  e2e_gl install
  assert_eq 0 "$STATUS" "install from the vendored runner: $OUT"
  assert_eq "$tree1" "$(e2e_tree_hash)" "tree hash after install from the vendored runner"
}

test_promote_and_status() {
  e2e_repo
  e2e_install
  e2e_todo severity=shadow since=2026-10-15
  printf 'TODO old\n' > a.ts
  e2e_baseline
  run git commit -q -m "chore: add a shadow rule"
  assert_eq 0 "$STATUS" "commit on main: $OUT"

  # 2026-10-23 is 8 days after the since date, so the rule is due.
  run env GAUNTLET_TODAY=2026-10-23 .gauntlet/bin/gauntlet status
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "promote due: todo (shadow since 2026-10-15, 8 days), 1 found"

  e2e_gl promote todo
  assert_eq 0 "$STATUS" "promote: $OUT"
  assert_eq "promoted todo: shadow -> block; commit the rule file" "$OUT" "promote output"
  must git add .gauntlet/rules/todo.md
  run git commit -q -m "chore: promote todo"
  assert_eq 0 "$STATUS" "commit of the promoted rule: $OUT"

  # The gate enforces the block rule now.
  printf 'TODO old\nTODO new\n' > a.ts
  must git add a.ts
  run git commit -q -m "feat: add debt"
  assert_eq 1 "$STATUS" "blocked after the promotion: $OUT"
  assert_contains "$OUT" "  a.ts:2  todo  TODO new"

  must git checkout -q HEAD -- a.ts
  e2e_gl doctor
  assert_eq 0 "$STATUS" "doctor: $OUT"
  e2e_every_line_ok "$OUT"
}

# EXC-AC7 end to end: a loosen row committed on the base is old, so it does not cover a
# second loosening of the same rule. The second branch stacks on the first, so the row is
# in its base; only a row committed on the second branch covers the new change.
test_old_loosen_row_does_not_cover_a_new_loosening() {
  e2e_repo
  e2e_install
  e2e_todo
  printf 'TODO legacy\n' > legacy.ts
  e2e_baseline
  run git commit -q -m "chore: add the gate"
  assert_eq 0 "$STATUS" "commit of the gate: $OUT"

  must git checkout -q -b first
  e2e_todo severity=shadow
  must git add -A
  run git commit -q -m "chore: lower todo to shadow"
  assert_eq 0 "$STATUS" "commit that lowers the severity: $OUT"
  e2e_gl loosen todo "stays shadow for one sprint" "the rule needs a week of data"
  assert_eq 0 "$STATUS" "loosen: $OUT"
  must git add -A
  run git commit -q -m "chore: record the first loosening"
  assert_eq 0 "$STATUS" "commit of the first row: $OUT"
  e2e_gl check --ci --base main
  assert_eq 0 "$STATUS" "check --ci for the first loosening: $OUT"

  must git checkout -q -b second
  e2e_todo severity=shadow paths='src/**'
  e2e_baseline
  run git commit -q -m "chore: narrow todo to src"
  assert_eq 0 "$STATUS" "commit that narrows the paths: $OUT"
  e2e_gl check --ci --base first
  assert_eq 1 "$STATUS" "check --ci: the old row must not cover the new loosening: $OUT"
  assert_contains "$OUT" "[loosened]"
  assert_contains "$OUT" "  todo  paths narrowed: **/*.ts"

  e2e_gl loosen todo "only src for now" "legacy files move later"
  assert_eq 0 "$STATUS" "second loosen: $OUT"
  must git add -A
  run git commit -q -m "chore: record the second loosening"
  assert_eq 0 "$STATUS" "commit of the second row: $OUT"
  e2e_gl check --ci --base first
  assert_eq 0 "$STATUS" "check --ci with the second row: $OUT"
}

# FRD-03 section 4.11 with the real hook and a real `git push`: the gate judges the branches
# git is about to push, not whatever is checked out. Each test installs the runner, commits
# the gate on main, adds a bare remote and leaves feat checked out, one commit ahead.
e2e_push_repo() {
  e2e_repo
  e2e_install
  e2e_todo
  printf 'ok\n' > a.ts
  e2e_baseline
  run git commit -q -m "chore: add the gate"
  assert_eq 0 "$STATUS" "commit on main: $OUT"
  must git init -q --bare "$TMP/remote.git"
  must git remote add origin "$TMP/remote.git"
  must git checkout -q -b feat
  printf 'ok too\n' > b.ts
  must git add b.ts
  run git commit -q -m "feat: add b"
  assert_eq 0 "$STATUS" "commit on feat: $OUT"
  must git branch other main
}

# e2e_remote_has <ref>: succeed when the bare remote holds the ref.
e2e_remote_has() {
  git --git-dir="$TMP/remote.git" rev-parse -q --verify "$1" > /dev/null
}

test_the_installed_pre_push_hook_passes_git_stdin_to_the_gate() {
  e2e_repo
  e2e_install
  assert_eq 1 "$(e2e_count_line "$E2E_LINE_CI" .git/hooks/pre-push)" "pre-push gate line"
  assert_contains "$(cat .git/hooks/pre-push)" "$E2E_CMD_CI"
}

test_push_of_the_checked_out_branch_passes_the_gate() {
  e2e_push_repo
  run git push origin feat
  assert_eq 0 "$STATUS" "push: $OUT"
  assert_contains "$OUT" "gauntlet: ok"
  e2e_remote_has refs/heads/feat || fail "feat did not reach the remote"
}

# The hook used to judge HEAD whatever it pushed; now a branch that is not checked out is refused
# and nothing is sent.
test_push_of_another_branch_is_refused_and_not_sent() {
  e2e_push_repo
  run git push origin other
  assert_eq 1 "$STATUS" "push: $OUT"
  assert_contains "$OUT" "gauntlet checks the checked-out branch; check out other and push again"
  if e2e_remote_has refs/heads/other; then fail "other reached the remote"; fi
}

test_push_of_head_under_another_name_passes() {
  e2e_push_repo
  run git push origin HEAD:refs/heads/x
  assert_eq 0 "$STATUS" "push: $OUT"
  assert_contains "$OUT" "gauntlet: ok"
  e2e_remote_has refs/heads/x || fail "x did not reach the remote"
}

test_a_delete_push_passes_the_gate() {
  e2e_push_repo
  run git push origin feat
  assert_eq 0 "$STATUS" "first push: $OUT"
  run git push origin :feat
  assert_eq 0 "$STATUS" "delete push: $OUT"
  if e2e_remote_has refs/heads/feat; then fail "feat is still on the remote"; fi
}

test_a_tag_push_passes_the_gate() {
  e2e_push_repo
  must git tag v1 main
  run git push origin v1
  assert_eq 0 "$STATUS" "tag push: $OUT"
  e2e_remote_has refs/tags/v1 || fail "v1 did not reach the remote"
}

test_push_all_with_a_branch_that_is_not_checked_out_is_refused() {
  e2e_push_repo
  run git push origin --all
  assert_eq 1 "$STATUS" "push --all: $OUT"
  assert_contains "$OUT" "check out main and push again"
  assert_contains "$OUT" "check out other and push again"
  if e2e_remote_has refs/heads/feat; then fail "feat reached the remote although the push was refused"; fi
}

# A failing gate on HEAD still blocks the push of HEAD.
test_a_failing_gate_still_blocks_the_push_of_head() {
  e2e_push_repo
  printf 'TODO fresh\n' > c.ts
  must git add c.ts
  run git commit -q --no-verify -m "feat: add c with a todo"
  assert_eq 0 "$STATUS" "commit: $OUT"
  run git push origin feat
  assert_eq 1 "$STATUS" "push: $OUT"
  assert_contains "$OUT" "  c.ts:1  todo  TODO fresh"
  if e2e_remote_has refs/heads/feat; then fail "feat reached the remote"; fi
}

# The gate is the first command of an existing pre-push hook, so git's stdin reaches it whole.
# A hook that reads stdin before our line would leave the gate nothing to judge.
test_an_existing_pre_push_hook_still_hands_stdin_to_the_gate() {
  e2e_repo
  printf '#!/bin/sh\ncat > /dev/null\n' > .git/hooks/pre-push
  must chmod +x .git/hooks/pre-push
  e2e_install
  assert_eq "#!/bin/sh" "$(sed -n 1p .git/hooks/pre-push)" "shebang first"
  assert_eq "$E2E_GATE_CI" "$(sed -n 2p .git/hooks/pre-push)" "gate second"
  e2e_todo
  e2e_baseline
  run git commit -q -m "chore: add the gate"
  assert_eq 0 "$STATUS" "commit on main: $OUT"
  must git init -q --bare "$TMP/remote.git"
  must git remote add origin "$TMP/remote.git"
  must git branch other
  must git checkout -q -b feat
  printf 'ok too\n' > b.ts
  must git add b.ts
  run git commit -q -m "feat: add b"
  assert_eq 0 "$STATUS" "commit on feat: $OUT"
  run git push origin other
  assert_eq 1 "$STATUS" "push: $OUT"
  assert_contains "$OUT" "check out other and push again"
}

# e2e_same_bytes <file> <content>: fail unless <file> is exactly <content>, byte for byte.
e2e_same_bytes() {
  printf '%s' "$2" > "$TMP/expected.txt" || fail "cannot write the expectation"
  cmp -s "$TMP/expected.txt" "$1" || fail "$1 differs from what git sent; it holds [$(cat "$1")], git sent [$2]"
}

# e2e_own_pre_push_hook <seen-file>: replace the pre-push hook of e2e_push_repo by one of the
# project's own, which writes what it reads on stdin to <seen-file>, then let install-hooks put the
# gate line into it, the way a project that already had a hook gets it.
e2e_own_pre_push_hook() {
  printf '#!/bin/sh\ncat > "%s"\n' "$1" > .git/hooks/pre-push
  must chmod +x .git/hooks/pre-push
  e2e_gl install-hooks
  assert_eq 0 "$STATUS" "install-hooks: $OUT"
  assert_contains "$OUT" "added gauntlet line to .git/hooks/pre-push"
  assert_eq "$E2E_GATE_CI" "$(sed -n 2p .git/hooks/pre-push)" "the gate line is the second line"
}

# R41 with the real hook and a real `git push`: the gate is the first command of the project's own
# hook and used to drain stdin, so a project command after it (git lfs pre-push reads the ref
# lines) saw nothing. It gets every byte git sent. The expectation is built from the push: one
# line, "<local ref> <local sha> <remote ref> <remote sha>", the remote sha all zeros for a new branch.
test_an_existing_pre_push_hook_still_receives_the_ref_lines_git_sent() {
  e2e_push_repo
  e2e_own_pre_push_hook "$TMP/seen.txt"
  local sha zero
  sha=$(git rev-parse feat)
  zero=$(printf '%040d' 0)
  run git push origin feat
  assert_eq 0 "$STATUS" "push: $OUT"
  assert_contains "$OUT" "gauntlet: ok"
  e2e_same_bytes "$TMP/seen.txt" "refs/heads/feat $sha refs/heads/feat $zero"$'\n'
  e2e_remote_has refs/heads/feat || fail "feat did not reach the remote"
}

# Two refs in one push are two lines, in the order git sends them.
test_an_existing_pre_push_hook_receives_every_ref_of_a_push() {
  e2e_push_repo
  e2e_own_pre_push_hook "$TMP/seen.txt"
  local sha zero
  sha=$(git rev-parse feat)
  zero=$(printf '%040d' 0)
  run git push origin feat HEAD:refs/heads/x
  assert_eq 0 "$STATUS" "push: $OUT"
  e2e_same_bytes "$TMP/seen.txt" "refs/heads/feat $sha refs/heads/feat $zero"$'\n'"HEAD $sha refs/heads/x $zero"$'\n'
}

# The buffer is not a leftover: after a push that passes and after one the gate refuses, TMPDIR is
# empty, and the refused push never reaches the project's command.
test_the_pre_push_line_leaves_nothing_in_tmpdir_after_a_push_or_a_refusal() {
  e2e_push_repo
  e2e_own_pre_push_hook "$TMP/seen.txt"
  must mkdir "$TMP/pushtmp"
  run env TMPDIR="$TMP/pushtmp" git push origin feat
  assert_eq 0 "$STATUS" "push: $OUT"
  assert_eq "" "$(ls -A "$TMP/pushtmp")" "TMPDIR after a push that passed"
  rm -f "$TMP/seen.txt"
  run env TMPDIR="$TMP/pushtmp" git push origin other
  assert_eq 1 "$STATUS" "refused push: $OUT"
  assert_contains "$OUT" "check out other and push again"
  assert_eq "" "$(ls -A "$TMP/pushtmp")" "TMPDIR after a refused push"
  if [ -e "$TMP/seen.txt" ]; then fail "the project's own command ran although the gate refused the push"; fi
}

# A temp directory git's hook cannot use blocks the push: no gate, no push.
test_a_push_is_blocked_when_the_hook_cannot_make_its_temp_file() {
  e2e_push_repo
  e2e_own_pre_push_hook "$TMP/seen.txt"
  run env TMPDIR="$TMP/no-such-dir" git push origin feat
  if [ "$STATUS" -eq 0 ]; then fail "the push went through without the gate: $OUT"; fi
  if e2e_remote_has refs/heads/feat; then fail "feat reached the remote"; fi
  if [ -e "$TMP/seen.txt" ]; then fail "the project's own command ran"; fi
}
