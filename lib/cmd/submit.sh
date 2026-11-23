# submit.sh -- rename Molden files, then run spart and submit via the backend.

submit_usage() {
    cat >&2 <<'EOF'
Usage: sjob submit (--batch FILE ... | --all) [--force] [--no-throttle]
  --force        submit even if the batch is not marked as processed
  --no-throttle  do not wait for the queue to drop below MAX_QUEUED
Backend (BACKEND=sbatch|farm) decides how the jobs are submitted.
EOF
}

# Rename orca.molden.input -> <name>.molden.input for every case of the batch
# and write "<case dir>\t<molden basename>" lines to $2. Idempotent.
submit_prepare_cases() {
    local bf="$1" list="$2" src dest dir name old new
    : >"$list"
    while IFS=$'\t' read -r src dest; do
        dir=$(dest_to_case_dir "$dest")
        name=$(case_name "$src")
        old="$dir/orca.molden.input"
        new="$dir/${name}.molden.input"
        if [[ -f $old ]]; then
            mv -f "$old" "$new" || return 1
        elif [[ ! -f $new ]]; then
            echo "ERROR: neither $old nor $new exists" >&2
            return 1
        fi   # (only $new: already renamed on an earlier run)
        printf '%s\t%s\n' "$dir" "${name}.molden.input" >>"$list"
    done < <(batch_cases "$bf")
}

submit_batch() {
    local bf="$1" force="$2" throttle="$3" name list
    name=$(batch_name "$bf")
    if stage_done "$name" submitted; then info "[$name] already submitted"; return 0; fi
    if ((!force)) && ! stage_done "$name" processed; then
        die "[$name] not processed yet (run 'sjob process' first, or use --force)"
    fi
    ((throttle)) && wait_for_queue

    list=$(mktemp "${TMPDIR:-/tmp}/sjob-submit.XXXXXX") || die "mktemp failed"
    if ! submit_prepare_cases "$bf" "$list"; then rm -f "$list"; die "[$name] could not prepare Molden files"; fi
    info "[$name] submitting $(wc -l <"$list") cases via backend '$BACKEND'..."
    if ! "backend_${BACKEND}_submit_batch" "$bf" "$list"; then
        rm -f "$list"; die "[$name] submission failed (re-run to continue; submitted cases are skipped)"
    fi
    rm -f "$list"
    stage_mark "$name" submitted
}

submit_check_backend() {
    declare -F "backend_${BACKEND}_prepare" >/dev/null || die "unknown BACKEND '$BACKEND' (use sbatch or farm)"
    "backend_${BACKEND}_prepare"
}

cmd_submit() {
    SEL_FILES=(); SEL_ALL=0
    local force=0 throttle=1 used bf
    while (($#)); do
        case "$1" in
            --force) force=1; shift ;;
            --no-throttle) throttle=0; shift ;;
            -h|--help) submit_usage; return 0 ;;
            *) sel_opt "$@"; used=$?
               ((used)) || { submit_usage; die "unknown option: $1"; }
               shift "$used" ;;
        esac
    done
    select_batches
    require_var DEST_ROOT
    acquire_lock
    load_env
    submit_check_backend
    for bf in "${SEL_BATCHES[@]}"; do submit_batch "$bf" "$force" "$throttle"; done
}
