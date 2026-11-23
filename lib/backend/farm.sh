# farm backend: one META-Farm "wave" per batch. spart runs WITHOUT -j, so each
# case is just one `cd <dir> && spart part ...` line in the wave's table.dat and
# no per-case Slurm script exists. No -auto: a failed case stays failed.
#
# ENV_SETUP must `module load meta-farm` (and activate spart's environment):
# it is also spliced into the wave's job_script.sh so every metajob has it.
#
# Each case gets <case>/.jobid = "farm:<job name>" so `collect` can tell
# whether the wave is still queued/running (one squeue lookup per wave), and
# spart's output goes to <case>/slurm-farm.out so `collect` finds a log.

backend_farm_prepare() {
    require_var FARM_ACCOUNT FARM_ROOT
    command -v farm_init.run >/dev/null 2>&1 && command -v submit.run >/dev/null 2>&1 \
        || die "farm_init.run/submit.run not on PATH -- does ENV_SETUP include 'module load meta-farm'?"
    require_cmd spart
    FARM_ROOT=$(realpath -m "$FARM_ROOT")
    mkdir -p "$FARM_ROOT"
}

# backend_farm_wave_dir BATCH_FILE -> creates the wave once, prints its dir
backend_farm_wave_dir() {
    local wave_name wave_dir f last env_file
    wave_name="wave_$(batch_name "$1")"
    wave_dir="$FARM_ROOT/$wave_name"
    if [[ ! -d $wave_dir ]]; then
        info "  creating META-Farm wave $wave_name"
        # farm_init.run's chatter goes to stderr: callers capture our stdout.
        ( cd "$FARM_ROOT" && farm_init.run "$wave_name" ) >&2 || { warn "farm_init.run failed"; return 1; }

        # Mandatory account line (job_script.sh and resubmit_script.sh both have one).
        for f in "$wave_dir"/*.sh; do
            [[ -f $f ]] && grep -q '^#SBATCH -A ' "$f" && sed -i "s/^#SBATCH -A .*/#SBATCH -A $FARM_ACCOUNT/" "$f"
        done
        # Per-case resources (cases run one at a time inside a metajob) and a
        # job name collect can look up.
        sed -i \
            -e "s/^#SBATCH -t .*/#SBATCH -t $FARM_TIME/" \
            -e "s/^#SBATCH --time=.*/#SBATCH --time=$FARM_TIME/" \
            -e "s/^#SBATCH --mem=.*/#SBATCH --mem=$FARM_MEM/" \
            -e "s/^#SBATCH --mem-per-cpu=.*/#SBATCH --mem-per-cpu=$FARM_MEM/" \
            -e "/^#SBATCH \(-J\|--job-name\)/d" \
            "$wave_dir/job_script.sh"
        grep -q '^#SBATCH --mem' "$wave_dir/job_script.sh" || sed -i "1a #SBATCH --mem=$FARM_MEM" "$wave_dir/job_script.sh"
        sed -i "1a #SBATCH -J spf_$wave_name" "$wave_dir/job_script.sh"

        # Environment once per metajob, right after the #SBATCH block.
        last=$(grep -n '^#SBATCH' "$wave_dir/job_script.sh" | tail -1 | cut -d: -f1)
        env_file=$(mktemp)
        printf '%s\n' "$ENV_SETUP" >"$env_file"
        sed -i "${last}r $env_file" "$wave_dir/job_script.sh"
        rm -f "$env_file"

        : >"$wave_dir/table.dat"       # drop any example content from the template
    fi
    printf '%s\n' "$wave_dir"
}

# $1 batch file, $2 list of "<case dir>\t<molden basename>"
backend_farm_submit_batch() {
    local bf="$1" list="$2" wave_dir wave_name dir molden ncases njobs
    wave_name="wave_$(batch_name "$bf")"
    wave_dir=$(backend_farm_wave_dir "$bf") || return 1

    if [[ ! -f $wave_dir/.submitted ]]; then
        while IFS=$'\t' read -r dir molden; do
            [[ -e $dir/$molden.queued ]] && continue        # queued by an earlier run
            printf 'cd %q && spart part %q %s > slurm-farm.out 2>&1\n' \
                "$dir" "$molden" "$SPART_ARGS" >>"$wave_dir/table.dat"
            : >"$dir/$molden.queued"
        done <"$list"

        ncases=$(wc -l <"$wave_dir/table.dat")
        if ((ncases > 0)); then
            njobs=$((ncases < FARM_NJOBS ? ncases : FARM_NJOBS))
            info "  submitting wave $wave_name ($ncases cases, $njobs metajobs)"
            ( cd "$wave_dir" && submit.run "$njobs" ) || { warn "submit.run failed for $wave_name"; return 1; }
        fi
        touch "$wave_dir/.submitted"
    fi

    while IFS=$'\t' read -r dir molden; do
        printf 'farm:spf_%s\n' "$wave_name" >"$dir/.jobid"
    done <"$list"
}
