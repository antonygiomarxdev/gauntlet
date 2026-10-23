# shellcheck shell=bash
# shellcheck disable=SC2153 # ROOT, G and STATUS are set by test/lib.sh
# Tests for lib/base.sh and the gauntlet base command: the base is the branch
# target, the merge-base is never guessed, and only the branch key is written.

# base_lib: source the libraries under test into the current test subshell.
base_lib() {
  # shellcheck source=lib/core.sh
  . "$ROOT/lib/core.sh"
  # shellcheck source=lib/base.sh
  . "$ROOT/lib/base.sh"
}

test_branch_config_wins() {
  mkrepo
  base_lib
  must git checkout -q -b feature-b
  run "$G" base feature-a
  assert_eq 0 "$STATUS" "base status"
  assert_eq "feature-a" "$(resolve_base "")" "resolved"
}

test_falls_back_to_main() {
  mkrepo
  run "$G" base
  assert_eq 0 "$STATUS" "status"
  assert_eq "main" "$OUT" "no remote, no config"
}

test_origin_head_before_main() {
  mkrepo
  base_lib
  must git update-ref refs/remotes/origin/main HEAD
  must git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  assert_eq "origin/main" "$(resolve_base "")" "resolved"
}

test_github_head_ref() {
  mkrepo
  base_lib
  must git checkout -q --detach
  export GITHUB_HEAD_REF=pr-1
  assert_eq "pr-1" "$(current_branch)" "current branch"
  unset GITHUB_HEAD_REF
  assert_eq "HEAD" "$(current_branch)" "detached without CI"
}

test_stacked_merge_base() {
  mkrepo
  base_lib
  must git checkout -q -b a
  printf 'a\n' > a.txt
  must git add -A
  must git commit -q -m a1
  must git checkout -q -b b
  printf 'b\n' > b.txt
  must git add -A
  must git commit -q -m b1
  run "$G" base a
  assert_eq 0 "$STATUS" "base status"
  assert_eq "$(git rev-parse a)" "$(merge_base "$(resolve_base "")")" "merge-base is a's tip"
}

test_unknown_ref_exits_2() {
  mkrepo
  base_lib
  run bash -c ". '$ROOT/lib/core.sh'; . '$ROOT/lib/base.sh'; merge_base nope"
  assert_eq 2 "$STATUS" "status"
  assert_contains "$OUT" "unknown ref: nope"
}

test_shallow_clone_merge_base_exits_2() {
  mkrepo
  must git checkout -q -b feat
  printf 'f\n' > f.txt
  must git add -A
  must git commit -q -m feat1
  must git clone -q --depth 1 --branch feat "file://$TMP/repo" "$TMP/shallow"
  must cd "$TMP/shallow"
  run bash -c ". '$ROOT/lib/core.sh'; . '$ROOT/lib/base.sh'; merge_base origin/main"
  assert_eq 2 "$STATUS" "status"
  assert_contains "$OUT" "shallow clone: fetch full history"
}

test_failed_fetch_warns_and_continues() {
  mkrepo
  base_lib
  must git update-ref refs/remotes/origin/main HEAD
  must git remote add origin "$TMP/nonexistent"
  run bash -c ". '$ROOT/lib/core.sh'; . '$ROOT/lib/base.sh'; merge_base origin/main"
  assert_eq 0 "$STATUS" "status"
  assert_contains "$OUT" "fetch of origin/main failed"
  assert_contains "$OUT" "$(git rev-parse HEAD)"
}

test_base_command_writes_only_branch_key() {
  mkrepo
  must git checkout -q -b feature-b
  before=$(git config --local --list)
  run "$G" base feature-a
  assert_eq 0 "$STATUS" "status"
  assert_eq "$(printf '%s\nbranch.feature-b.gauntletbase=feature-a' "$before")" \
    "$(git config --local --list)" "local config"
}

test_at_base_absent_path_prints_nothing() {
  mkrepo
  base_lib
  printf 'hi\n' > f.txt
  must git add -A
  must git commit -q -m two
  sha=$(git rev-parse HEAD)
  assert_eq "hi" "$(at_base "$sha" f.txt)" "present"
  assert_eq "" "$(at_base "$sha" missing.txt)" "absent"
}

test_base_outside_repo_exits_2() {
  cd "$TMP" || fail "cd failed"
  run "$G" base
  assert_eq 2 "$STATUS" "status"
  assert_contains "$OUT" "not inside a git repository"
}

test_base_refuses_detached_head() {
  mkrepo
  must git checkout -q --detach
  run "$G" base feature-a
  assert_eq 2 "$STATUS" "status"
  assert_contains "$OUT" "detached HEAD: check out a branch first"
  assert_not_contains "$(git config --local --list)" "gauntletbase"
}

test_fetch_never_prompts() {
  unset GIT_TERMINAL_PROMPT
  mkrepo
  base_lib
  must git update-ref refs/remotes/origin/main HEAD
  must git remote add origin "$TMP/nonexistent"
  mkdir -p "$TMP/stub" || fail "mkdir failed"
  real_git=$(command -v git)
  cat > "$TMP/stub/git" <<EOS
#!/bin/bash
if [ "\$1" = fetch ]; then printf '%s' "\$GIT_TERMINAL_PROMPT" > "$TMP/prompt"; fi
exec "$real_git" "\$@"
EOS
  must chmod +x "$TMP/stub/git"
  run env PATH="$TMP/stub:$PATH" bash -c ". '$ROOT/lib/core.sh'; . '$ROOT/lib/base.sh'; merge_base origin/main"
  assert_eq "0" "$(cat "$TMP/prompt")" "GIT_TERMINAL_PROMPT during fetch"
}

test_resolve_explicit_ref_wins() {
  mkrepo
  base_lib
  must git checkout -q -b feature-b
  must git config branch.feature-b.gauntletBase feature-a
  assert_eq "feature-z" "$(resolve_base feature-z)" "explicit ref"
}

test_config_base_beats_origin_head_and_main() {
  mkrepo
  base_lib
  must git update-ref refs/remotes/origin/main HEAD
  must git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  echo "base=team-base" > .gauntlet/config
  assert_eq "team-base" "$(resolve_base "")" "config base"
}

test_at_base_bad_sha_dies() {
  mkrepo
  run bash -c ". '$ROOT/lib/core.sh'; . '$ROOT/lib/base.sh'; at_base deadbeef f.txt"
  assert_eq 2 "$STATUS" "bad sha status"
  assert_contains "$OUT" "bad sha: deadbeef"
  run bash -c ". '$ROOT/lib/core.sh'; . '$ROOT/lib/base.sh'; at_base '' f.txt"
  assert_eq 2 "$STATUS" "empty sha status"
  assert_contains "$OUT" "bad sha:"
}
