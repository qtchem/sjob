# sbatch backend: `spart part ... -j` writes one *part.sh per case, each is
# sbatch'ed and its job id recorded in <case>/.jobid (used by `collect`).

backend_sbatch_prepare() { require_cmd spart sbatch; }

# $1 batch file, $2 list of "<case dir>\t<molden basename>"
backend_sbatch_submit_batch() {
    local list="$2" dir molden script script_dir jid
    local -a spart_args todo_dirs=() molden_files=()
    read -r -a spart_args <<<"$SPART_ARGS"

    # Cases that already have a job id were submitted by an earlier (interrupted) run.
    while IFS=$'\t' read -r dir molden; do
        [[ -e $dir/.jobid ]] && continue
        todo_dirs+=("$dir"); molden_files+=("$dir/$molden")
    done <"$list"
    if ((${#molden_files[@]} == 0)); then info "  nothing left to submit"; return 0; fi

    info "  running spart on ${#molden_files[@]} Molden files..."
    spart part "${molden_files[@]}" "${spart_args[@]}" -j || return 1

    local failed=0
    for dir in "${todo_dirs[@]}"; do
        while IFS= read -r -d '' script; do
            script_dir=$(dirname "$script")
            if jid=$(cd "$script_dir" && sbatch --parsable "$(basename "$script")"); then
                echo "${jid%%;*}" >"$script_dir/.jobid"
            else
                warn "sbatch failed for $script"; failed=1
            fi
        done < <(find "$dir" -name '*part.sh' -print0)
    done
    return "$failed"
}
