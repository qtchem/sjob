# transfer.sh -- Globus transfer of the *gbw* files of a batch.
#
# Split into start/finish so `run` can overlap the next batch's transfer with
# the current batch's processing. The Globus task id is stored in
# state/<batch>/transfer_task, so an interrupted run waits for the SAME task
# instead of submitting a duplicate.

transfer_usage() {
    cat >&2 <<'EOF'
Usage: spartflow transfer (--batch FILE ... | --all) [--no-wait]
  --no-wait   only submit the Globus task(s); a later run waits for them
Needs SOURCE_ENDPOINT, DEST_ENDPOINT, DEST_ROOT.
EOF
}

# transfer_start BATCH_FILE -- idempotent: no-op if already transferred or a
# usable task already exists. Prints nothing; the task id lands in the state dir.
transfer_start() {
    local bf="$1" name task_file listing src dest status
    name=$(batch_name "$bf")
    task_file="$STATE_DIR/$name/transfer_task"
    if stage_done "$name" transferred; then return 0; fi

    if [[ -s $task_file ]]; then
        status=$(globus task show "$(<"$task_file")" --jmespath status --format unix 2>/dev/null || echo UNKNOWN)
        case "$status" in
            ACTIVE|INACTIVE|SUCCEEDED) vlog "[$name] reusing Globus task $(<"$task_file") ($status)"; return 0 ;;
            *) info "[$name] previous Globus task is $status; submitting a new one" ;;
        esac
    fi

    mkdir -p "$STATE_DIR/$name"
    listing=$(mktemp "${TMPDIR:-/tmp}/spartflow-transfer.XXXXXX") || die "mktemp failed"
    while IFS=$'\t' read -r src dest; do
        validate_src "$src"
        dest_rel "$dest" >/dev/null          # also checks it is inside DEST_ROOT
        printf '%s %s --recursive\n' "$src" "$dest" >>"$listing"
    done < <(batch_cases "$bf")
    [[ -s $listing ]] || { rm -f "$listing"; info "[$name] nothing to transfer"; return 0; }

    info "[$name] submitting Globus transfer..."
    local task_id
    task_id=$(globus transfer "$SOURCE_ENDPOINT:" "$DEST_ENDPOINT:" \
                  --include "*gbw*" --exclude "*" --batch "$listing" \
                  --label "spartflow $name" --jmespath task_id --format unix)
    local rc=$?
    rm -f "$listing"
    ((rc == 0)) && [[ -n $task_id ]] || die "[$name] Globus returned no task id"
    printf '%s\n' "$task_id" >"$task_file"
    info "[$name] Globus task $task_id"
}

# transfer_finish BATCH_FILE -- wait for the batch's task, verify, mark done.
transfer_finish() {
    local bf="$1" name task_file task_id status
    name=$(batch_name "$bf")
    task_file="$STATE_DIR/$name/transfer_task"
    if stage_done "$name" transferred; then return 0; fi
    if [[ ! -s $task_file ]]; then stage_mark "$name" transferred; return 0; fi   # nothing was transferred

    task_id=$(<"$task_file")
    info "[$name] waiting for Globus task $task_id..."
    globus task wait "$task_id" || true
    status=$(globus task show "$task_id" --jmespath status --format unix) || status=UNKNOWN
    if [[ $status != SUCCEEDED ]]; then
        rm -f "$task_file"          # next run submits a fresh task
        die "[$name] Globus task $task_id ended as $status; not processing this batch"
    fi
    stage_mark "$name" transferred
    info "[$name] transfer succeeded"
}

cmd_transfer() {
    SEL_FILES=(); SEL_ALL=0
    local nowait=0 used bf
    while (($#)); do
        case "$1" in
            --no-wait) nowait=1; shift ;;
            -h|--help) transfer_usage; return 0 ;;
            *) sel_opt "$@"; used=$?
               ((used)) || { transfer_usage; die "unknown option: $1"; }
               shift "$used" ;;
        esac
    done
    select_batches
    require_var SOURCE_ENDPOINT DEST_ENDPOINT DEST_ROOT
    require_cmd globus
    acquire_lock
    for bf in "${SEL_BATCHES[@]}"; do
        transfer_start "$bf"
        ((nowait)) || transfer_finish "$bf"
    done
}
