# shellcheck shell=bash
# Measurement: count each rule's violations per fingerprint. Sourced, never
# executed. Bash 3.2 compatible; awk, sort and coreutils only.
# Needs core.sh, rules.sh, paths.sh and detect.sh sourced first.

# measure <mode> <workdir> [rule-ids...]: write <workdir>/located.tsv (rule,
# path, line, fingerprint, message) and <workdir>/measure.tsv (rule, path,
# fingerprint, count), both LC_ALL=C sorted. Mode all reads every file, staged
# reads the staged paths. Rule ids default to every rule. Returns 2 on a bad
# mode, a missing rule or a broken detector.
measure() {
  local mode=$1 work=$2 root scratch status=0
  shift 2
  root=$(repo_root) || return 2
  mkdir -p "$work" || return 2
  scratch=$(mktemp -d) || return 2
  measure_in "$mode" "$work" "$root" "$scratch" "$@" || status=$?
  rm -rf "$scratch"
  return "$status"
}

# measure_in <mode> <workdir> <root> <scratch> [rule-ids...]: the work of
# measure, with intermediate files kept in <scratch>.
measure_in() {
  local mode=$1 work=$2 root=$3 scratch=$4 id rf paths exclude t0 t1
  shift 4
  case "$mode" in
    all) tracked_files > "$scratch/inputs" || return 2 ;;
    staged)
      # A staged path missing on disk (staged, then deleted) has no working-tree
      # content to measure, so the detector never sees it.
      staged_files > "$scratch/staged.all" || return 2
      : > "$scratch/inputs" || return 2
      while IFS= read -r p; do
        if [ -e "$root/$p" ] || [ -L "$root/$p" ]; then printf '%s\n' "$p"; fi
      done < "$scratch/staged.all" > "$scratch/inputs" || return 2
      ;;
    *)
      printf 'gauntlet: measure mode must be all or staged, got [%s]\n' "$mode" >&2
      return 2
      ;;
  esac
  # R15: files under .gauntlet/ are never measured, whatever the rule's paths.
  awk 'index($0, ".gauntlet/") != 1' "$scratch/inputs" > "$scratch/kept" || return 2
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" > "$scratch/ids" || return 2
  else
    rule_ids > "$scratch/ids" || return 2
  fi

  # time.tsv: wall milliseconds per rule, for the check report's [time] section.
  : > "$scratch/raw"
  : > "$work/time.tsv" || return 2
  while IFS= read -r id; do
    rf="$root/.gauntlet/rules/$id.md"
    if [ ! -f "$rf" ]; then
      printf 'gauntlet: unknown rule %s\n' "$id" >&2
      return 2
    fi
    t0=$(now_ms)
    paths=$(rule_get "$rf" paths) || return 2
    exclude=$(rule_get "$rf" exclude) || return 2
    select_files "$paths" "$exclude" < "$scratch/kept" > "$scratch/files" || return 2
    run_detector "$rf" "$scratch/files" "$scratch/rule.tsv" || return 2
    t1=$(now_ms)
    printf '%s\t%s\n' "$id" "$((t1 - t0))" >> "$work/time.tsv" || return 2
    cat "$scratch/rule.tsv" >> "$scratch/raw" || return 2
  done < "$scratch/ids"

  # R28: only rows of kept paths count, whichever way the detector found them. A
  # whole-program detector walks the disk and also reports untracked and ignored
  # files, which a fresh clone does not have; kept holds the tracked paths (the
  # staged ones at commit) and never a .gauntlet/ path (R15).
  GL_KEPT="$scratch/kept" awk -F "$DETECT_TAB" '
    FILENAME == ENVIRON["GL_KEPT"] { keep[$0] = 1; next }
    $2 in keep
  ' "$scratch/kept" "$scratch/raw" > "$scratch/raw.kept" || return 2

  # Group the rows by path so each file is read once, then take each matched
  # line from the working tree and normalize it into the fingerprint.
  LC_ALL=C sort -t "$DETECT_TAB" -k2,2 "$scratch/raw.kept" > "$scratch/sorted" || return 2
  GL_ROOT="$root" awk -F "$DETECT_TAB" '
    function normalize(s) {
      gsub(/\r/, "", s)
      gsub(/[ \t]+/, " ", s)
      sub(/^ /, "", s)
      sub(/ $/, "", s)
      return s
    }
    $2 != cur {
      cur = $2
      n = 0
      while ((getline l < (ENVIRON["GL_ROOT"] "/" cur)) > 0) lines[++n] = l
      close(ENVIRON["GL_ROOT"] "/" cur)
    }
    {
      # located.tsv: fields 1-4 are rule, path, line and fingerprint. Field 5
      # runs to the end of the line and is the message, which may contain tabs.
      # It starts after the first four fields and their separators.
      msg = substr($0, length($1) + length($2) + length($3) + 4)
      ln = $3 + 0
      fp = (ln >= 1 && ln <= n) ? normalize(lines[ln]) : ""
      print $1 "\t" $2 "\t" $3 "\t" fp "\t" msg
    }
  ' "$scratch/sorted" > "$scratch/located" || return 2
  LC_ALL=C sort "$scratch/located" > "$work/located.tsv" || return 2

  awk -F "$DETECT_TAB" '
    { count[$1 "\t" $2 "\t" $4]++ }
    END { for (k in count) print k "\t" count[k] }
  ' "$work/located.tsv" > "$scratch/counts" || return 2
  LC_ALL=C sort "$scratch/counts" > "$work/measure.tsv" || return 2
}
