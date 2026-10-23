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

# Absent is not an error: the gate reads files the base never had (a rules directory
# with no exceptions.tsv) and takes the empty answer.
test_at_base_of_an_absent_path_returns_0_and_prints_nothing() {
  mkrepo
  base_lib
  sha=$(git rev-parse HEAD)
  run at_base "$sha" missing.txt
  assert_eq 0 "$STATUS" "status: $OUT"
  assert_eq "" "$OUT" "output"
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

# base_has answers three ways: 0 present, 1 absent, 2 when git cannot tell.
test_base_has_present_absent_and_directory() {
  mkrepo
  base_lib
  must mkdir -p "my dir"
  printf 'hi\n' > "my dir/a b.txt"
  rule x
  must git add -A
  must git commit -q -m two
  sha=$(git rev-parse HEAD)
  run base_has "$sha" "my dir/a b.txt"
  assert_eq 0 "$STATUS" "file with spaces: $OUT"
  run base_has "$sha" ".gauntlet/rules"
  assert_eq 0 "$STATUS" "directory: $OUT"
  run base_has "$sha" "my dir/missing.txt"
  assert_eq 1 "$STATUS" "absent file: $OUT"
  assert_eq "" "$OUT" "absent is silent"
  run base_has "$sha" "my dir/*.txt"
  assert_eq 1 "$STATUS" "a glob names nothing: $OUT"
}

test_base_has_reads_root_relative_paths_from_a_subdirectory() {
  mkrepo
  base_lib
  sha=$(git rev-parse HEAD)
  must mkdir -p sub
  must cd sub
  run base_has "$sha" ".gauntlet/config"
  assert_eq 0 "$STATUS" "root path from sub: $OUT"
}

test_base_has_returns_2_on_a_git_error_and_says_it_once() {
  mkrepo
  base_lib
  run base_has 0000000000000000000000000000000000000000 .gauntlet/config
  assert_eq 2 "$STATUS" "bad sha: $OUT"
  assert_contains "$OUT" "0000000000000000000000000000000000000000"
  assert_contains "$OUT" ".gauntlet/config"
  assert_eq 1 "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "one message line: $OUT"
}

# A blob git cannot read is not an absent file: the tree still lists it, so base_has
# says present, and at_base fails instead of printing nothing.
test_at_base_fails_on_an_unreadable_blob() {
  mkrepo
  base_lib
  printf 'unique content\n' > f.txt
  must git add -A
  must git commit -q -m two
  sha=$(git rev-parse HEAD)
  unreadable_object "$sha:f.txt"
  run base_has "$sha" f.txt
  assert_eq 0 "$STATUS" "the tree still lists it: $OUT"
  run at_base "$sha" f.txt
  [ "$STATUS" -ne 0 ] || fail "at_base printed an unreadable blob as if it were absent: $OUT"
}

# The failed read is named the way a failed listing is: path, sha, and gauntlet's prefix,
# not git's raw "fatal: bad object" with no hint which read it was.
test_at_base_names_the_read_that_failed() {
  mkrepo
  base_lib
  printf 'unique content\n' > f.txt
  must git add -A
  must git commit -q -m two
  sha=$(git rev-parse HEAD)
  unreadable_object "$sha:f.txt"
  run at_base "$sha" f.txt
  assert_eq 2 "$STATUS" "status: $OUT"
  assert_contains "$OUT" "gauntlet: cannot read f.txt at $sha"
  assert_not_contains "$OUT" "fatal:"
}

test_index_has_present_absent_and_error() {
  mkrepo
  base_lib
  run index_has .gauntlet/baseline.tsv
  assert_eq 0 "$STATUS" "in the index: $OUT"
  run index_has nothing.txt
  assert_eq 1 "$STATUS" "not in the index: $OUT"
  run index_has ".gauntlet/base*.tsv"
  assert_eq 1 "$STATUS" "a glob names nothing: $OUT"
  # Root-relative like base_has: the answer from a subdirectory is the root's.
  must mkdir -p sub
  must cd sub
  run index_has .gauntlet/baseline.tsv
  assert_eq 0 "$STATUS" "in the index, from a subdirectory: $OUT"
  run index_has nothing.txt
  assert_eq 1 "$STATUS" "not in the index, from a subdirectory: $OUT"
  must cd ..
  printf 'not an index' > .git/index
  run index_has .gauntlet/baseline.tsv
  assert_eq 2 "$STATUS" "unreadable index: $OUT"
  assert_contains "$OUT" ".gauntlet/baseline.tsv"
}

# A path with glob characters names that file and nothing else, in the base and in the
# index: a1.ts is not a[1].ts, and a file called *.ts is found by its name.
test_base_has_and_index_has_treat_glob_characters_literally() {
  mkrepo
  base_lib
  printf 'x\n' > a1.ts
  printf 'x\n' > 'b[1].ts'
  printf 'x\n' > '*.ts'
  must git add -A
  must git commit -q -m two
  sha=$(git rev-parse HEAD)
  local p
  for p in 'b[1].ts' '*.ts'; do
    run base_has "$sha" "$p"
    assert_eq 0 "$STATUS" "base_has finds [$p]: $OUT"
    run index_has "$p"
    assert_eq 0 "$STATUS" "index_has finds [$p]: $OUT"
  done
  for p in 'a[1].ts' 'a?.ts' 'c*.ts'; do
    run base_has "$sha" "$p"
    assert_eq 1 "$STATUS" "base_has does not glob [$p]: $OUT"
    run index_has "$p"
    assert_eq 1 "$STATUS" "index_has does not glob [$p]: $OUT"
  done
}

# I1 (d): the gate's own error for a base it cannot find says how to name the right one. The
# demo is a repo whose default branch is master and that has no origin/HEAD: the fallback is main.
test_check_ci_on_a_repo_without_main_says_how_to_set_the_base() {
  mkrepo
  must git branch -m main master
  run "$G" check --ci
  assert_eq 2 "$STATUS" "check --ci: $OUT"
  assert_contains "$OUT" "gauntlet: unknown ref: main; run gauntlet base <ref> or set base= in .gauntlet/config"
  run "$G" check --ci --base nope
  assert_eq 2 "$STATUS" "check --ci --base nope: $OUT"
  assert_contains "$OUT" "gauntlet: unknown ref: nope; run gauntlet base <ref> or set base= in .gauntlet/config"
  run "$G" check --ci --base master
  assert_eq 0 "$STATUS" "check --ci --base master: $OUT"
}
