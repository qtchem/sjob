# run.sh -- all stages end-to-end over many batches (transfer -> process -> submit).

run_usage() {
    cat >&2 <<'EOF'
Usage: sjob run [--batch FILE ... | --all] [--max-batches N] [--collect]
                     [--no-pipeline] [--dry-run]
  (default selection: --all)
  --max-batches N  stop after submitting N batches (smoke tests)
  --collect        before each new batch, collect (apply) earlier submitted
                   batches whose jobs have all finished
  --no-pipeline    do not start the next batch's transfer while processing
  --dry-run        show what is pending and exit
Resumable: finished stages are skipped (see 'sjob status').
EOF
}

# Submitted-but-not-collected batches among the selected ones.
run_collect_candidates() {
    local bf name
    for bf in "${SEL_BATCHES[@]}"; do
        name=$(batch_name "$bf")
        if stage_done "$name" submitted && ! stage_done "$name" collected; then printf '%s\n' "$bf"; fi
    done
}

cmd_run() {
    SEL_FILES=(); SEL_ALL=0
    local max=0 do_collect=0 pipeline=1 dry=0 used bf name i n count=0
    while (($#)); do
        case "$1" in
            --max-batches) [[ ${2:-} =~ ^[1-9][0-9]*$ ]] || die "--max-batches needs a positive number"; max="$2"; shift 2 ;;
            --collect) do_collect=1; shift ;;
            --no-pipeline) pipeline=0; shift ;;
            --dry-run) dry=1; shift ;;
            -h|--help) run_usage; return 0 ;;
            *) sel_opt "$@"; used=$?
               ((used)) || { run_usage; die "unknown option: $1"; }
               shift "$used" ;;
        esac
    done
    ((${#SEL_FILES[@]} == 0)) && SEL_ALL=1
    select_batches
    require_var SOURCE_ENDPOINT DEST_ENDPOINT DEST_ROOT

    local -a pending=()
    for bf in "${SEL_BATCHES[@]}"; do
        stage_done "$(batch_name "$bf")" submitted || pending+=("$bf")
    done
    if ((${#pending[@]} == 0)); then info "nothing to do: every selected batch is already submitted"; fi

    if ((dry)); then
        info "pending batches (${#pending[@]}):"
        for bf in "${pending[@]}"; do
            name=$(batch_name "$bf")
            printf '  %-14s transfer:%s process:%s submit:pending\n' "$name" \
                "$(stage_done "$name" transferred && echo done || echo todo)" \
                "$(stage_done "$name" processed && echo done || echo todo)"
        done
        return 0
    fi

    acquire_lock
    load_env
    require_cmd globus "$ZSTD" "$ORCA_2MKL"
    submit_check_backend
    if ((do_collect)); then collect_check_config; fi

    n=${#pending[@]}
    for ((i = 0; i < n; i++)); do
        bf="${pending[$i]}"; name=$(batch_name "$bf")
        ((max > 0 && count >= max)) && { info "reached --max-batches $max"; break; }
        info "========================================"
        info "[$name] batch $((i + 1)) of $n"
        info "========================================"

        if ((do_collect)); then
            local -a cand=()
            mapfile -t cand < <(run_collect_candidates)
            if ((${#cand[@]})); then
                COLLECT_APPLY=1
                collect_run_batches "${cand[@]}" || warn "collect reported problems (continuing)"
            fi
        fi

        wait_for_queue
        transfer_start "$bf"
        # Overlap: stage the NEXT batch while this one is processed.
        if ((pipeline && i + 1 < n)); then transfer_start "${pending[$((i + 1))]}"; fi
        transfer_finish "$bf"
        process_batch "$bf" 0
        submit_batch "$bf" 0 1
        info "[$name] completed"
        count=$((count + 1))
    done
    info "run finished: $count batch(es) submitted"
}
