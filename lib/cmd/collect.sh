# collect.sh -- classify finished cases, archive the good ones, record failures.
#
# Per batch (only once EVERY case in it has finished; otherwise it is skipped
# and picked up on a later run):
#   DONE    -> SUCCESS_FILES packed into results/<batch>.tar.zst; archive
#              verified; only then DELETE_GLOBS removed from those cases.
#   FAILED  -> recorded in failures/<batch>.tsv. Nothing is retried and
#              NOTHING is removed from a failed case.
# status/<batch>.tsv lists every case; state/<batch>/collected marks a batch
# finished. Dry run unless --apply.

collect_usage() {
    cat >&2 <<'EOF'
Usage: sjob collect (--batch FILE ... | --all) [--apply]
  --apply      really archive and delete (default: dry run, changes nothing)
  --verbose    (global -v) list every non-DONE case during a dry run
Settings: SUCCESS_FILES DELETE_GLOBS FAIL_PATTERNS RESULTS_DIR STATUS_DIR
          FAILURES_DIR MIN_AGE_MIN NPROC ... (see etc/sjob.conf.example)
EOF
}

# --------------------------------------------------------------------------
# Per-case helpers (run inside `sjob _worker collect ...`)
# --------------------------------------------------------------------------

# Print SUCCESS_FILES matches (relative to the case dir), one per line.
# Exit 0 only if every pattern matched a non-empty regular file.
collect_success_files_of() {
    (
        cd "$1" 2>/dev/null || exit 2
        shopt -s nullglob
        read -r -a pats <<<"$SUCCESS_FILES"
        ok=1
        for pat in "${pats[@]}"; do
            found=0
            for f in $pat; do
                if [[ -f $f && -s $f ]]; then printf '%s\n' "$f"; found=1; fi
            done
            ((found)) || ok=0
        done
        exit $((1 - ok))
    )
}

# Seconds since the newest file in the dir changed (huge if there is none).
collect_newest_age_sec() {
    local newest
    newest=$(find "$1" -maxdepth 1 -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -n 1)
    [[ -n $newest ]] || { echo 999999999; return; }
    echo $(($(date +%s) - ${newest%.*}))
}

# FAIL_PATTERNS lookup: prints the reason of the first matching entry.
collect_match_reason() {
    local entry pat reason
    for entry in "${FAIL_PATTERNS[@]}"; do
        pat="${entry%|*}"; reason="${entry##*|}"
        if grep -Eq -- "$pat" <<<"$1"; then printf '%s' "$reason"; return 0; fi
    done
    return 1
}

# One input line (tab separated, '-' = unknown):
#   rel  jobid  slurm_state  exit  elapsed  maxrss
# One output line:
#   rel  state  reason  slurm_state  exit  elapsed  maxrss  last_error_line
collect_classify_case() {
    local rel jobid sstate sexit selapsed smaxrss
    IFS=$'\t' read -r rel jobid sstate sexit selapsed smaxrss <<<"$1"
    local dir="$CASE_ROOT/$rel" state reason="-" err="-" log_file="" tail_txt="" sc

    collect_emit() {
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$rel" "$state" "$reason" "$sstate" "$sexit" "$selapsed" "$smaxrss" "$err"
    }

    if [[ ! -d $dir ]]; then state=ACTIVE; reason=dir_missing; collect_emit; return; fi

    log_file=$(find "$dir" -maxdepth 1 -name 'slurm-*.out' -printf '%T@ %p\n' 2>/dev/null \
               | sort -n | tail -n 1 | cut -d' ' -f2-)

    case "$sstate" in
        COMPLETED|FAILED|TIMEOUT|OUT_OF_MEMORY|CANCELLED|NODE_FAIL|PREEMPTED|BOOT_FAIL|DEADLINE) : ;;
        -)  # Slurm knows nothing about it: judge by the files
            if [[ -z $log_file && ! -e $dir/.jobid ]] \
               && ! compgen -G "$dir/*part.sh" >/dev/null \
               && ! compgen -G "$dir/*.queued" >/dev/null; then
                state=ACTIVE; reason=not_submitted; collect_emit; return
            fi
            if (($(collect_newest_age_sec "$dir") < MIN_AGE_MIN * 60)); then
                state=ACTIVE; reason=recent_activity; collect_emit; return
            fi ;;
        *)  state=ACTIVE; reason="slurm_$sstate"; collect_emit; return ;;   # PENDING, RUNNING, ...
    esac

    sc=0; collect_success_files_of "$dir" >/dev/null || sc=$?
    if [[ $sstate == "-" || $sstate == COMPLETED ]] && ((sc == 0)); then
        state=DONE; collect_emit; return
    fi

    state=FAILED
    if [[ -n $log_file ]]; then tail_txt=$(tail -n 20 "$log_file" 2>/dev/null || true); fi
    if [[ -n $tail_txt ]]; then
        err=$(grep -v '^[[:space:]]*$' <<<"$tail_txt" | tail -n 1 | tr '\t\r' '  ' | cut -c1-200)
        [[ -n $err ]] || err="-"
    fi
    case "$sstate" in
        -|COMPLETED|FAILED)
            reason=$(collect_match_reason "$tail_txt") || reason=""
            if [[ -z $reason ]]; then
                if [[ $sstate == "-" && -z $log_file ]]; then reason=no_output
                elif [[ $sstate == COMPLETED ]]; then reason=missing_output
                else reason=unknown_error; fi
            fi ;;
        *)  reason=$(tr 'A-Z' 'a-z' <<<"$sstate") ;;   # timeout, out_of_memory, ...
    esac
    collect_emit
}

# Worker entry: arguments are classification input lines.
collect_classify_cases() {
    local line
    for line; do collect_classify_case "$line"; done
}

# --------------------------------------------------------------------------
# Batch-level helpers
# --------------------------------------------------------------------------

# $1 archive, $2 file of DONE rels, $3 optional expected entry count
collect_verify_archive() {
    local arch="$1" done_list="$2" expect="${3:-}" listing="$COLLECT_TMP/archive.lst"
    zstd -tq "$arch" || return 1
    zstd -dcq "$arch" | tar -tf - >"$listing" || return 1
    if [[ -n $expect && $(wc -l <"$listing") -ne $expect ]]; then
        info "  archive has $(wc -l <"$listing") entries, expected $expect"
        return 1
    fi
    [[ -z "$(LC_ALL=C comm -23 <(LC_ALL=C sort -u "$done_list") \
             <(sed 's|/[^/]*$||' "$listing" | LC_ALL=C sort -u))" ]]
}

collect_cleanup_done_cases() {
    local rel dir pat f g nfiles=0 ndirs=0
    local -a pats
    read -r -a pats <<<"$DELETE_GLOBS"
    while IFS= read -r rel; do
        dir="$CASE_ROOT/$rel"
        [[ -d $dir ]] || continue
        for pat in "${pats[@]}"; do
            while IFS= read -r -d '' f; do
                rm -f -- "$f" && nfiles=$((nfiles + 1))
            done < <(cd "$dir" && shopt -s nullglob && for g in $pat; do
                         [[ -f $g || -L $g ]] && printf '%s\0' "$dir/$g"
                     done)
        done
        if [[ ${RMDIR_EMPTY:-1} == 1 ]] && rmdir "$dir" 2>/dev/null; then ndirs=$((ndirs + 1)); fi
    done <"$1"
    info "  cleanup: removed $nfiles files, $ndirs empty case dirs"
}

# Sets sacct.tsv (jobid state exit elapsed maxrss) for the jobs listed in $1
# (jobs.tsv: rel<TAB>jobid). Real Slurm job ids go through sacct in chunks;
# "farm:<jobname>" ids (META-Farm waves) are looked up once per name in squeue.
collect_lookup_jobs() {
    local jobs="$1" out="$2" ids name
    : >"$out"
    if command -v sacct >/dev/null && awk -F'\t' '$2!="-" && $2 !~ /^farm:/' "$jobs" | grep -q .; then
        while IFS= read -r ids; do
            sacct -n -P -S "$SACCT_SINCE" -j "$ids" -o JobID,State,ExitCode,Elapsed,MaxRSS 2>/dev/null \
            | awk -F'|' -v OFS='\t' '
                { split($1, a, ".")
                  if ($1 !~ /\./) { st = $2; sub(/ .*/, "", st); S[a[1]] = st; E[a[1]] = $3; T[a[1]] = $4 }
                  else if ($1 ~ /\.batch$/ && $5 != "") M[a[1]] = $5 }
                END { for (i in S) print i, S[i], E[i], T[i], (M[i] == "" ? "-" : M[i]) }' \
            >>"$out" || true
        done < <(awk -F'\t' -v n="$SACCT_CHUNK" '$2!="-" && $2 !~ /^farm:/ {
                    ids = ids (c++ % n ? "," : (ids == "" ? "" : "\n")) $2 }
                 END { print ids }' "$jobs" | grep .)
    fi
    if awk -F'\t' '$2 ~ /^farm:/' "$jobs" | grep -q . && command -v squeue >/dev/null; then
        while IFS= read -r name; do
            if [[ -n "$(squeue -u "${USER:-$(id -un)}" -h -n "${name#farm:}" -o %i 2>/dev/null)" ]]; then
                printf '%s\tRUNNING\t-\t-\t-\n' "$name" >>"$out"
            fi
        done < <(awk -F'\t' '$2 ~ /^farm:/ {print $2}' "$jobs" | sort -u)
    fi
}

collect_process_batch() {
    local bf="$1" name tmp statusf failf arch p rel nrel jid
    name=$(batch_name "$bf")
    statusf="$STATUS_DIR/$name.tsv"
    failf="$FAILURES_DIR/$name.tsv"
    arch="$RESULTS_DIR/$name.tar.zst"

    if stage_done "$name" collected; then info "[$name] already collected, skipping"; return 0; fi
    tmp="$COLLECT_TMP/$name"; mkdir -p "$tmp"

    # Resume: archive + status exist, only cleanup remains.
    if [[ -f $arch && -f $statusf ]]; then
        awk -F'\t' '!/^#/ && $2=="DONE" {print $1}' "$statusf" | LC_ALL=C sort >"$tmp/done.lst"
        info "[$name] resuming: archive and status exist, only cleanup remains"
        if ((COLLECT_APPLY)); then
            collect_verify_archive "$arch" "$tmp/done.lst" \
                || { info "[$name] archive failed verification, NOT deleting anything"; return 1; }
            collect_cleanup_done_cases "$tmp/done.lst"
            stage_mark "$name" collected
        else
            info "  (dry run) would clean up $(wc -l <"$tmp/done.lst") DONE cases"
        fi
        return 0
    fi

    local -a rels=()
    while IFS= read -r p; do rels+=("$(dest_rel "$p")"); done < <(batch_cases "$bf" | cut -f2)
    nrel=${#rels[@]}
    ((nrel > 0)) || { info "[$name] no cases listed, skipping"; return 0; }

    : >"$tmp/jobs.tsv"
    for rel in "${rels[@]}"; do
        jid="-"
        if [[ -r $CASE_ROOT/$rel/.jobid ]]; then
            jid=$(tr -d '[:space:]' <"$CASE_ROOT/$rel/.jobid"); [[ -n $jid ]] || jid="-"
        fi
        printf '%s\t%s\n' "$rel" "$jid" >>"$tmp/jobs.tsv"
    done
    collect_lookup_jobs "$tmp/jobs.tsv" "$tmp/sacct.tsv"

    awk -F'\t' -v OFS='\t' '
        FILENAME == ARGV[1] { s[$1] = $2 OFS $3 OFS $4 OFS $5; next }   # not NR==FNR: sacct.tsv may be empty
        { if ($2 in s) print $1, $2, s[$2]; else print $1, $2, "-", "-", "-", "-" }
    ' "$tmp/sacct.tsv" "$tmp/jobs.tsv" >"$tmp/cases.tsv"

    parallel_workers collect collect_classify_cases <"$tmp/cases.tsv" >"$tmp/status.raw"
    LC_ALL=C sort -t $'\t' -k1,1 "$tmp/status.raw" >"$tmp/status.tsv"

    local n_done n_fail n_active
    n_done=$(awk -F'\t' '$2=="DONE"' "$tmp/status.tsv" | wc -l)
    n_fail=$(awk -F'\t' '$2=="FAILED"' "$tmp/status.tsv" | wc -l)
    n_active=$(awk -F'\t' '$2=="ACTIVE"' "$tmp/status.tsv" | wc -l)
    if ((n_done + n_fail + n_active != nrel)); then
        info "[$name] classification returned $((n_done + n_fail + n_active)) of $nrel cases; aborting this batch"
        return 1
    fi

    if ((n_active > 0)); then
        info "[$name] $n_active of $nrel cases not finished ($(awk -F'\t' '$2=="ACTIVE" {c[$3]++} END {for (r in c) printf "%s=%d ", r, c[r]}' "$tmp/status.tsv")); skipping this batch for now"
        return 0
    fi

    info "[$name] $nrel cases: $n_done DONE, $n_fail FAILED"
    if ((n_fail > 0)); then
        awk -F'\t' '$2=="FAILED" {c[$3]++} END {for (r in c) printf "    %-24s %d\n", r, c[r]}' "$tmp/status.tsv" >&2
    fi

    if ((!COLLECT_APPLY)); then
        if ((SJ_VERBOSE)); then awk -F'\t' '$2!="DONE" {print "    " $1 "\t" $3 "\t" $8}' "$tmp/status.tsv" >&2; fi
        info "  (dry run) would archive $n_done cases to $arch, record $n_fail failures, then delete: $DELETE_GLOBS"
        return 0
    fi

    mkdir -p "$STATUS_DIR" "$FAILURES_DIR" "$RESULTS_DIR" || return 1

    awk -F'\t' '$2=="DONE" {print $1}' "$tmp/status.tsv" >"$tmp/done.lst"
    local nfiles=0 f
    if ((n_done > 0)); then
        : >"$tmp/files.lst"
        while IFS= read -r rel; do
            while IFS= read -r f; do
                printf '%s/%s\n' "$rel" "$f" >>"$tmp/files.lst"
                nfiles=$((nfiles + 1))
            done < <(collect_success_files_of "$CASE_ROOT/$rel")
        done <"$tmp/done.lst"

        rm -f "$arch.tmp"
        if ! tar -C "$CASE_ROOT" -cf - -T "$tmp/files.lst" \
             | zstd -q -f -"$ZSTD_LEVEL" -T"$ZSTD_THREADS" -o "$arch.tmp"; then
            rm -f "$arch.tmp"; info "[$name] packing failed, nothing deleted"; return 1
        fi
        if ! collect_verify_archive "$arch.tmp" "$tmp/done.lst" "$nfiles"; then
            rm -f "$arch.tmp"; info "[$name] archive verification failed, nothing deleted"; return 1
        fi
    fi

    # status + failures first, archive last (its presence is the resume signal)
    {
        printf '#case\tstate\treason\tslurm_state\texit_code\telapsed\tmax_rss\tlast_error_line\n'
        cat "$tmp/status.tsv"
    } >"$statusf.tmp" && mv -f "$statusf.tmp" "$statusf" || return 1
    {
        printf '#case\tstate\treason\tslurm_state\texit_code\telapsed\tmax_rss\tlast_error_line\n'
        awk -F'\t' '$2=="FAILED"' "$tmp/status.tsv"
    } >"$failf.tmp" && mv -f "$failf.tmp" "$failf" || return 1
    if ((n_done > 0)); then
        mv -f "$arch.tmp" "$arch" || return 1
        info "  archived $n_done cases ($nfiles files) -> $arch ($(du -h "$arch" | cut -f1))"
        collect_cleanup_done_cases "$tmp/done.lst"
    fi
    stage_mark "$name" collected
    info "  recorded: $statusf, $failf"
}

collect_check_config() {
    require_var DEST_ROOT
    require_cmd zstd tar
    [[ -n "${SUCCESS_FILES// }" ]] || die "SUCCESS_FILES is empty"
    local pat; local -a all_pats
    read -r -a all_pats <<<"$SUCCESS_FILES $DELETE_GLOBS"      # no glob expansion here
    for pat in "${all_pats[@]}"; do
        [[ $pat != */* ]] || die "patterns must not contain '/': $pat"
    done
}

# collect_run_batches FILE...  -- uses COLLECT_APPLY; the caller holds the lock.
collect_run_batches() {
    local rc=0 bf
    COLLECT_TMP=$(mktemp -d "${TMPDIR:-/tmp}/sjob.XXXXXX") || die "cannot create temp dir"
    for bf; do collect_process_batch "$bf" || rc=1; done
    rm -rf "$COLLECT_TMP"
    return "$rc"
}

cmd_collect() {
    COLLECT_APPLY=0
    SEL_FILES=(); SEL_ALL=0
    local used
    while (($#)); do
        case "$1" in
            --apply) COLLECT_APPLY=1; shift ;;
            -h|--help) collect_usage; return 0 ;;
            *) sel_opt "$@"; used=$?
               ((used)) || { collect_usage; die "unknown option: $1"; }
               shift "$used" ;;
        esac
    done
    select_batches
    collect_check_config
    if ((COLLECT_APPLY)); then acquire_lock; fi
    local rc=0
    collect_run_batches "${SEL_BATCHES[@]}" || rc=1
    ((COLLECT_APPLY)) || info "(dry run: nothing was changed; pass --apply to act)"
    return "$rc"
}
