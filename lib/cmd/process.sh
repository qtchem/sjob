# process.sh -- decompress each case's orca.gbw.zstd0 and convert it to Molden.

process_usage() {
    cat >&2 <<'EOF'
Usage: spartflow process (--batch FILE ... | --all) [--force]
  --force   process even if the batch is not marked as transferred
Runs NPROC cases in parallel. Cases that already have a Molden file and no
compressed/gbw file are skipped, so an interrupted run resumes cleanly.
EOF
}

# Worker: process_case DIR... (exit 255 on failure so xargs stops dispatching).
process_case() {
    local d
    for d; do process_one_case "$d" || exit 255; done
}

# Every critical command has an explicit "|| return 1": `set -e` is ignored
# inside functions called from an "||" context. The compressed file is never
# removed unless decompression succeeded.
process_one_case() {
    local dir="$1"
    local compressed="$dir/orca.gbw.zstd0" gbw="$dir/orca.gbw" molden="$dir/orca.molden.input"

    if [[ ! -f $compressed && ! -f $gbw ]]; then
        # Resume: already converted (possibly already renamed by `submit`).
        if [[ -s $molden ]] || compgen -G "$dir/*.molden.input" >/dev/null; then
            vlog "already processed: $dir"; return 0
        fi
        echo "ERROR: missing $compressed" >&2; return 1
    fi

    echo "Processing: $dir"
    if [[ -f $compressed ]]; then
        "$ZSTD" -d -f "$compressed" -o "$gbw" \
            || { echo "ERROR: decompression failed: $compressed" >&2; return 1; }
        rm "$compressed" || return 1
    fi

    # ORCA's converter expects the job basename, without .gbw.
    ( cd "$dir" || exit 1; "$ORCA_2MKL" orca -molden ) \
        || { echo "ERROR: orca_2mkl failed in $dir" >&2; return 1; }
    rm "$gbw" || return 1

    [[ -s $molden ]] || { echo "ERROR: Molden output missing or empty: $molden" >&2; return 1; }
    echo "Post-processing completed: $dir"
}

process_batch() {
    local bf="$1" name force="$2"
    name=$(batch_name "$bf")
    if stage_done "$name" processed; then info "[$name] already processed"; return 0; fi
    if ((!force)) && ! stage_done "$name" transferred; then
        die "[$name] not transferred yet (run 'spartflow transfer' first, or use --force)"
    fi
    info "[$name] processing with $NPROC parallel workers..."
    batch_case_dirs "$bf" | parallel_workers process process_case \
        || die "[$name] processing failed; fix the error and re-run (finished cases are skipped)"
    stage_mark "$name" processed
}

cmd_process() {
    SEL_FILES=(); SEL_ALL=0
    local force=0 used bf
    while (($#)); do
        case "$1" in
            --force) force=1; shift ;;
            -h|--help) process_usage; return 0 ;;
            *) sel_opt "$@"; used=$?
               ((used)) || { process_usage; die "unknown option: $1"; }
               shift "$used" ;;
        esac
    done
    select_batches
    require_var DEST_ROOT
    acquire_lock
    load_env
    require_cmd "$ZSTD" "$ORCA_2MKL"
    for bf in "${SEL_BATCHES[@]}"; do process_batch "$bf" "$force"; done
}
