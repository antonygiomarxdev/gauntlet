# shellcheck shell=bash
# Human-only exceptions: the rows of .gauntlet/exceptions.tsv that waive a path,
# loosen a rule or remove one; the commands that write them; and the lookups the
# gate makes. Sourced, never executed. Bash 3.2 compatible; awk, git, date and
# coreutils only. Needs core.sh, base.sh and detect.sh (DETECT_TAB) sourced first.

EXC_NL='
'

# exc_file: print the path of .gauntlet/exceptions.tsv in the working tree.
exc_file() {
  local root
  root=$(repo_root) || return 2
  printf '%s/.gauntlet/exceptions.tsv\n' "$root"
}

# exc_text_check <label> <text>: exit 2 when text is empty or holds a tab or a
# newline, which would break its TSV row (R21).
exc_text_check() {
  [ -n "$2" ] || die "$1 must not be empty"
  case "$2" in
    *"$DETECT_TAB"*|*"$EXC_NL"*) die "$1 must not contain a tab or newline" ;;
  esac
}

# exc_require_dir: exit 2 with one message when the repo has no .gauntlet/ directory, which
# is what gauntlet install makes. Without it the row cannot be written anywhere.
exc_require_dir() {
  local root
  root=$(repo_root) || return 2
  [ -d "$root/.gauntlet" ] || die "no .gauntlet/ directory; run gauntlet install"
}

# exc_rule_known <id>: succeed (0) when .gauntlet/rules/<id>.md, a rule and not a case file
# (rule_is_case_file), exists in the working tree,
# in HEAD, or at the merge-base of HEAD and the base ref; 1 when it exists nowhere; 2 when
# git cannot tell (R32). A human may delete the file before running remove, or commit the
# deletion first, so the working tree alone is not enough. The base is the local ref, never
# fetched: these commands do not touch the network. When HEAD or the base does not
# resolve, that place is skipped.
exc_rule_known() {
  local id=$1 root path rc ref mb
  root=$(repo_root) || return 2
  case "$id" in */*) return 1 ;; esac
  if rule_is_case_file "$id"; then return 1; fi
  path=.gauntlet/rules/$id.md
  if [ -f "$root/$path" ]; then return 0; fi
  git rev-parse -q --verify 'HEAD^{commit}' > /dev/null 2>&1 || return 1
  rc=0
  base_has HEAD "$path" || rc=$?
  case "$rc" in 0) return 0 ;; 1) ;; *) return 2 ;; esac
  ref=$(resolve_base "") || return 2
  git rev-parse -q --verify "$ref^{commit}" > /dev/null 2>&1 || return 1
  mb=$(git merge-base HEAD "$ref" 2> /dev/null) || return 1
  rc=0
  base_has "$mb" "$path" || rc=$?
  case "$rc" in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
}

# exc_rule_check <id>: exit 2 with "no rule <id>" when the rule exists nowhere (see
# exc_rule_known), and 2 when git cannot tell.
exc_rule_check() {
  local rc=0
  exc_rule_known "$1" || rc=$?
  case "$rc" in
    0) ;;
    1) die "no rule $1" ;;
    *) exit 2 ;;
  esac
}

# exc_append <type> <target> <reason> <branch>: append one row, dated today, to
# exceptions.tsv. The file gets its header when it is missing or empty.
exc_append() {
  local file today
  file=$(exc_file) || return 2
  if [ ! -s "$file" ]; then
    printf 'type\ttarget\treason\tdate\tbranch\n' > "$file" || return 2
  elif [ -n "$(tail -c 1 "$file")" ]; then
    # The last row has no newline: end it, or the new row is glued onto it.
    printf '\n' >> "$file" || return 2
  fi
  today=$(date +%Y-%m-%d) || return 2
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$today" "$4" >> "$file" || return 2
}

# exc_script_hint <rule-id>: print how to approve a script rule: the row to add by hand
# to exceptions.tsv, in the columns exc_append writes in its header. No command writes
# a script row.
exc_script_hint() {
  printf '.gauntlet/exceptions.tsv: add the row script<TAB>%s<TAB><reason><TAB><YYYY-MM-DD><TAB>- (columns: type, target, reason, date, branch)\n' "$1"
}

# exc_waive <path> <reason>: waive a path on the current branch. The path is
# relative to the repo root and must exist in git or in the working tree.
exc_waive() {
  local path reason branch
  [ "$#" -eq 2 ] || die "usage: gauntlet waive <path> <reason>"
  exc_require_dir || return 2
  path=$1
  reason=$2
  exc_text_check path "$path"
  exc_text_check reason "$reason"
  # A path names one file: no ./ prefix, no trailing slash, no glob (the exact
  # path must exist, checked literally below).
  case "$path" in
    ./*) die "path must be relative to the repo root, without ./: $path" ;;
    */) die "path must name a file, not end with /: $path" ;;
  esac
  branch=$(current_branch) || return 2
  [ "$branch" != HEAD ] || die "detached HEAD: check out a branch first"
  if ! { [ -e "$path" ] || [ -n "$(git --literal-pathspecs ls-files -- "$path")" ]; }; then
    die "not a path in git or the working tree: $path"
  fi
  exc_append waive "$path" "$reason" "$branch" || return 2
}

# exc_loosen <rule> <what> <reason>: record a loosening of a rule, or of .gauntlet/config
# when the rule is @config. It covers every loosening of that rule that the gate finds
# since the merge-base. The rule must exist (exc_rule_check).
exc_loosen() {
  [ "$#" -eq 3 ] || die "usage: gauntlet loosen <rule> <what> <reason>"
  exc_require_dir || return 2
  exc_text_check rule "$1"
  exc_text_check what "$2"
  exc_text_check reason "$3"
  # @config stands for .gauntlet/config (see cmp_config): it has no rule file.
  if [ "$1" != @config ]; then exc_rule_check "$1"; fi
  exc_append loosen "$1: $2" "$3" - || return 2
}

# exc_remove <rule> <reason>: record the removal of a rule. The rule must exist
# (exc_rule_check): in the working tree, in HEAD or at the merge-base.
exc_remove() {
  [ "$#" -eq 2 ] || die "usage: gauntlet remove <rule> <reason>"
  exc_require_dir || return 2
  exc_text_check rule "$1"
  exc_text_check reason "$2"
  exc_rule_check "$1"
  exc_append remove "$1" "$2" - || return 2
}

# waived_paths: print the paths waived on the current branch (decision 5). A
# waive row from another branch exempts nothing. Prints nothing without a file.
waived_paths() {
  local file branch
  file=$(exc_file) || return 2
  [ -f "$file" ] || return 0
  branch=$(current_branch) || return 2
  GL_BRANCH=$branch awk -F "$DETECT_TAB" '$1 == "waive" && $5 == ENVIRON["GL_BRANCH"] { print $2 }' "$file"
}

# exc_has_script <rule-id>: succeed when exceptions.tsv in the working tree has a
# script row for the rule (RULE-AC2). Only the row's presence is asked for. Fails
# when the file is missing or unreadable.
exc_has_script() {
  local file
  file=$(exc_file) || return 2
  [ -f "$file" ] || return 1
  GL_ID=$1 awk -F "$DETECT_TAB" '$1 == "script" && $2 == ENVIRON["GL_ID"] { found = 1 } END { exit !found }' "$file"
}

# exc_new_rows <merge-base> <out>: write the exceptions.tsv rows that are absent
# from the merge-base's file (decision 6). The rows are written as they are; a
# row that was already there at the base never counts as new.
exc_new_rows() {
  local mb=$1 out=$2 root base
  root=$(repo_root) || return 2
  base="$out.base"
  at_base "$mb" .gauntlet/exceptions.tsv > "$base" || return 2
  if [ ! -f "$root/.gauntlet/exceptions.tsv" ]; then
    : > "$out" || return 2
    return 0
  fi
  GL_BASE=$base awk '
    FILENAME == ENVIRON["GL_BASE"] { seen[$0] = 1; next }
    !($0 in seen)
  ' "$base" "$root/.gauntlet/exceptions.tsv" > "$out" || return 2
}
