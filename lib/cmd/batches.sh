# batches.sh -- split a list of source directories into batch_NNNN.txt files.

batches_usage() {
    cat >&2 <<'EOF'
Usage: sjob batches LIST --size N [--out-dir DIR] [--start N] [--force]
  LIST       file with one source directory per line (relative to the Globus
             source endpoint; '#' comments and blank lines ignored)
  --size N   cases per batch (required)
  --out-dir  where to write batch_NNNN.txt (default: BATCH_DIR)
  --start N  first batch number (default: continue after the highest existing)
  --force    overwrite existing batch files
Each output line is "<source_dir> <DEST_ROOT>/<source_dir>".
EOF
}

cmd_batches() {
    local list="" size="" out="$BATCH_DIR" start="" force=0
    while (($#)); do
        case "$1" in
            --size)    [[ $# -ge 2 ]] || die "--size needs a number"; size="$2"; shift 2 ;;
            --out-dir) [[ $# -ge 2 ]] || die "--out-dir needs a directory"; out="$2"; shift 2 ;;
            --start)   [[ $# -ge 2 ]] || die "--start needs a number"; start="$2"; shift 2 ;;
            --force)   force=1; shift ;;
            -h|--help) batches_usage; return 0 ;;
            -*)        batches_usage; die "unknown option: $1" ;;
            *)         [[ -z $list ]] || die "only one LIST file allowed"; list="$1"; shift ;;
        esac
    done
    [[ -n $list && -f $list ]] || { batches_usage; die "LIST file required"; }
    [[ $size =~ ^[1-9][0-9]*$ ]] || { batches_usage; die "--size must be a positive integer"; }
    require_var DEST_ROOT
    mkdir -p "$out" || die "cannot create $out"

    if [[ -z $start ]]; then
        start=$(
            shopt -s nullglob
            max=0
            for f in "$out"/batch_*.txt; do
                n=$(basename "$f" .txt); n="${n#batch_}"; n=$((10#${n:-0}))
                ((n > max)) && max=$n
            done
            echo $((max + 1))
        )
    fi
    [[ $start =~ ^[0-9]+$ ]] || die "--start must be a number"

    local -a srcs=()
    local line seen=0 dups=0 total
    # Normalise (CR, one trailing slash) and drop duplicate lines with awk:
    # bash 3.2 (macOS) has no associative arrays, and awk is fast for millions of lines.
    total=$(sed -e 's/\r$//' -e 's#/$##' "$list" | grep -cvE '^[[:space:]]*(#|$)')
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -z "${line//[[:space:]]/}" || $line == \#* ]] && continue
        validate_src "$line"
        seen=$((seen + 1))
        srcs+=("$line")
    done < <(sed -e 's/\r$//' -e 's#/$##' "$list" | awk '!s[$0]++')
    dups=$((total - seen))
    ((${#srcs[@]})) || die "no source directories in $list"
    ((dups == 0)) || warn "skipped $dups duplicate entries"

    local i=0 num=$start file nfiles=0
    for line in "${srcs[@]}"; do
        if ((i % size == 0)); then
            file=$(printf '%s/batch_%04d.txt' "$out" "$num")
            if [[ -e $file ]] && ((!force)); then die "$file exists (use --force or --start)"; fi
            : >"$file"
            num=$((num + 1)); nfiles=$((nfiles + 1))
        fi
        printf '%s %s/%s\n' "$line" "$DEST_ROOT" "$line" >>"$file"
        i=$((i + 1))
    done
    info "wrote $nfiles batch file(s) with ${#srcs[@]} cases to $out (batch_$(printf '%04d' "$start") ... batch_$(printf '%04d' $((num - 1))))"
}
