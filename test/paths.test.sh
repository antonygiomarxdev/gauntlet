# shellcheck shell=bash
# Tests for lib/paths.sh: glob matching of rule paths and exclude lists.

# paths_lib: source the library under test into the current test subshell.
paths_lib() {
  # shellcheck source=lib/paths.sh
  . "$ROOT/lib/paths.sh"
}

test_double_star_matches_root_and_nested() {
  paths_lib
  OUT=$(printf 'a.test.ts\nx/y/a.test.ts\nb.ts\n' | select_files "**" "**/*.test.ts")
  assert_eq "b.ts" "$OUT"
}

test_single_star_stays_in_dir() {
  paths_lib
  OUT=$(printf 'src/a.ts\nsrc/x/a.ts\n' | select_files "src/*.ts" "")
  assert_eq "src/a.ts" "$OUT"
}

test_dot_is_literal() {
  paths_lib
  OUT=$(printf 'axts\na.ts\n' | select_files "*.ts" "")
  assert_eq "a.ts" "$OUT"
}

test_listing_prints_special_names_raw() {
  mkrepo
  paths_lib
  must sh -c 'echo one > "q\"x.ts" && echo two > "b\\s.ts"'
  must git add -A
  must git commit -q -m "special names"
  OUT=$(tracked_files)
  assert_contains "$OUT" 'b\s.ts'
  assert_contains "$OUT" 'q"x.ts'
  assert_not_contains "$OUT" '"b'
  must sh -c 'echo three > "q\"x.ts"'
  must git add -A
  OUT=$(staged_files)
  assert_eq 'q"x.ts' "$OUT" "staged_files"
}

test_staged_files_excludes_deleted() {
  mkrepo
  paths_lib
  must sh -c 'echo one > keep.txt && echo two > gone.txt'
  must git add keep.txt gone.txt
  must git commit -q -m "add files"
  must git rm -q gone.txt
  must sh -c 'echo changed >> keep.txt'
  must git add keep.txt
  OUT=$(staged_files)
  assert_eq "keep.txt" "$OUT"
}

test_empty_paths_selects_everything() {
  paths_lib
  OUT=$(printf 'a.ts\nx/b\n' | select_files "" "")
  assert_eq "a.ts
x/b" "$OUT"
}

test_double_star_alone_matches_nested() {
  paths_lib
  OUT=$(printf 'a\nx/y/z.ts\n' | select_files "**" "")
  assert_eq "a
x/y/z.ts" "$OUT"
}

test_metacharacters_match_literally() {
  paths_lib
  OUT=$(printf 'c++/a(1).ts\ncc/a1.ts\n' | select_files "c++/a(1).ts" "")
  assert_eq "c++/a(1).ts" "$OUT"
}

test_blank_paths_selects_everything() {
  paths_lib
  OUT=$(printf 'a.ts\nx/b\n' | select_files "  " "")
  assert_eq "a.ts
x/b" "$OUT"
}

test_staged_files_prints_unicode_unquoted() {
  mkrepo
  paths_lib
  must sh -c 'echo one > é.txt'
  must git add é.txt
  OUT=$(staged_files)
  assert_eq "é.txt" "$OUT"
}

test_all_files_lists_tracked_and_untracked_omits_ignored() {
  mkrepo
  paths_lib
  must sh -c 'echo one > tracked.txt'
  must git add tracked.txt
  must git commit -q -m "add tracked"
  must sh -c 'echo two > untracked-é.txt'
  must sh -c 'echo three > ignored.log'
  must sh -c 'echo "*.log" > .gitignore'
  OUT=$(all_files)
  assert_contains "$OUT" "tracked.txt"
  assert_contains "$OUT" "untracked-é.txt"
  assert_contains "$OUT" ".gitignore"
  assert_not_contains "$OUT" "ignored.log"
}

test_all_files_omits_deleted_tracked_file() {
  mkrepo
  paths_lib
  must sh -c 'echo one > keep.txt && echo two > gone.txt'
  must git add keep.txt gone.txt
  must git commit -q -m "add files"
  must rm gone.txt
  OUT=$(all_files)
  assert_contains "$OUT" "keep.txt"
  assert_not_contains "$OUT" "gone.txt"
}

test_all_files_keeps_dangling_symlink() {
  mkrepo
  paths_lib
  must ln -s nowhere link
  must git add link
  must git commit -q -m "add link"
  OUT=$(all_files)
  assert_contains "$OUT" "link"
}

test_all_files_lists_unmerged_path_once() {
  mkrepo
  paths_lib
  must sh -c 'echo base > f'
  must git add f
  must git commit -q -m "add f"
  must git checkout -q -b side
  must sh -c 'echo side > f'
  must git commit -q -am "side"
  must git checkout -q main
  must sh -c 'echo main > f'
  must git commit -q -am "main"
  git merge -q side >/dev/null 2>&1 || true
  OUT=$(all_files)
  COUNT=$(printf '%s\n' "$OUT" | awk '$0 == "f" { n++ } END { print n + 0 }')
  assert_eq 1 "$COUNT" "f count"
}

test_tracked_files_omits_untracked() {
  mkrepo
  printf 'x\n' > t.ts
  must git add t.ts
  must git commit -q -m t
  printf 'x\n' > u.ts
  paths_lib
  OUT=$(tracked_files | awk "!/^\.gauntlet\//")
  assert_eq "t.ts" "$OUT" "tracked only"
}

test_tracked_files_omits_deleted_from_disk() {
  mkrepo
  printf 'x\n' > a.ts
  printf 'x\n' > b.ts
  must git add a.ts b.ts
  must git commit -q -m ab
  must rm b.ts
  paths_lib
  OUT=$(tracked_files | awk "!/^\.gauntlet\//")
  assert_eq "a.ts" "$OUT" "deletion left unstaged"
}

test_tracked_files_lists_staged_new_file() {
  mkrepo
  printf 'x\n' > n.ts
  must git add n.ts
  paths_lib
  OUT=$(tracked_files | awk "!/^\.gauntlet\//")
  assert_eq "n.ts" "$OUT" "staged new file"
}

test_tracked_files_lists_unmerged_path_once() {
  mkrepo
  printf 'a\n' > f.txt
  must git add f.txt
  must git commit -q -m base
  must git checkout -q -b other
  printf 'x\n' > f.txt
  must git commit -q -am other
  must git checkout -q main
  printf 'm\n' > f.txt
  must git commit -q -am main
  run git merge -q other
  assert_eq 1 "$STATUS" "merge conflicts"
  paths_lib
  OUT=$(tracked_files | awk "!/^\.gauntlet\//")
  assert_eq "f.txt" "$OUT" "unmerged path once"
}
