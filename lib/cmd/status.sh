# status.sh -- per-batch progress from the stage markers + live queue length.

cmd_status() {
    SEL_FILES=(); SEL_ALL=1
    local used bf name n d f t p s c
    while (($#)); do
        case "$1" in
            -h|--help) echo "Usage: sjob status [--batch FILE ...]   (default: all batches)" >&2; return 0 ;;
            *) SEL_ALL=0; sel_opt "$@"; used=$?
               ((used)) || die "unknown option: $1"
               shift "$used" ;;
        esac
    done
    if ((SEL_ALL)); then
        [[ -n "$(list_batches)" ]] || { info "no batch_*.txt in $BATCH_DIR"; return 0; }
    fi
    select_batches

    local mark=$'✓'
    printf '%-14s %7s  %-5s %-5s %-5s %-5s  %7s %7s\n' BATCH CASES XFER PROC SUBM COLL DONE FAILED
    local tot_cases=0 tot_done=0 tot_fail=0
    for bf in "${SEL_BATCHES[@]}"; do
        name=$(batch_name "$bf")
        n=$(batch_cases "$bf" | wc -l)
        t="-"; p="-"; s="-"; c="-"
        stage_done "$name" transferred && t="$mark"
        stage_done "$name" processed   && p="$mark"
        stage_done "$name" submitted   && s="$mark"
        stage_done "$name" collected   && c="$mark"
        d="-"; f="-"
        if [[ -f $STATUS_DIR/$name.tsv ]]; then
            d=$(awk -F'\t' '!/^#/ && $2=="DONE"' "$STATUS_DIR/$name.tsv" | wc -l)
            f=$(awk -F'\t' '!/^#/ && $2=="FAILED"' "$STATUS_DIR/$name.tsv" | wc -l)
            tot_done=$((tot_done + d)); tot_fail=$((tot_fail + f))
        fi
        tot_cases=$((tot_cases + n))
        printf '%-14s %7s  %-5s %-5s %-5s %-5s  %7s %7s\n' "$name" "$n" "$t" "$p" "$s" "$c" "$d" "$f"
    done
    printf '%-14s %7s  %-5s %-5s %-5s %-5s  %7s %7s\n' TOTAL "$tot_cases" "" "" "" "" "$tot_done" "$tot_fail"
    if command -v squeue >/dev/null 2>&1; then
        local q
        if q=$(queue_length); then printf '\nqueue: %s of my jobs queued/running (MAX_QUEUED=%s)\n' "$q" "$MAX_QUEUED"; fi
    fi
}
