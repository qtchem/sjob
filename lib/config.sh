# config.sh -- layered configuration.
#
# Precedence, lowest to highest:
#   built-in defaults < /etc/spartflow.conf < ~/.config/spartflow/conf
#   < ./spartflow.conf < --config FILE < environment variables < flags
#
# Config files are plain bash with plain assignments (VAR=value). Environment
# variables win over every file, so  NPROC=4 spartflow process --all  works.

SF_VARS=(
    SOURCE_ENDPOINT DEST_ENDPOINT DEST_ROOT CASE_ROOT BATCH_DIR STATE_DIR
    ENV_SETUP ZSTD ORCA_2MKL NPROC MAX_QUEUED POLL_SECONDS SPART_ARGS BACKEND
    SUCCESS_FILES DELETE_GLOBS RMDIR_EMPTY RESULTS_DIR STATUS_DIR FAILURES_DIR
    ZSTD_LEVEL ZSTD_THREADS MIN_AGE_MIN SACCT_SINCE SACCT_CHUNK
    FARM_ROOT FARM_NJOBS FARM_ACCOUNT FARM_MEM FARM_TIME
)

sf_set_defaults() {
    SOURCE_ENDPOINT=""          # Globus endpoint UUIDs (required by `transfer`)
    DEST_ENDPOINT=""
    DEST_ROOT=""                # where batch_*.txt destinations live on the cluster
    CASE_ROOT=""                # where those dirs are NOW (default: DEST_ROOT)
    BATCH_DIR="."
    STATE_DIR="state"
    ENV_SETUP=""                # shell lines run once: pyenv activate, module load ...
    ZSTD="zstd"
    ORCA_2MKL=""                # default: $EBROOTORCA/orca_2mkl
    NPROC="${SLURM_CPUS_PER_TASK:-$(nproc)}"
    MAX_QUEUED=800
    POLL_SECONDS=600
    SPART_ARGS="-s mbis avh-b -a 100:590"
    BACKEND="sbatch"            # sbatch | farm

    SUCCESS_FILES="data_denspart.json last_iteration_coeffs_*.npz"
    DELETE_GLOBS="*.molden.input *part.sh slurm-*.out .jobid *.queued data_denspart.json last_iteration_coeffs_*.npz"
    RMDIR_EMPTY=1
    FAIL_PATTERNS=(
        'Integration error of dipole moment|dipole_integration'
        'molden or mkl file .* contains errors|molden_load_error'
        'MemoryError|python_memory_error'
    )
    RESULTS_DIR="results"
    STATUS_DIR="status"
    FAILURES_DIR="failures"
    ZSTD_LEVEL=10
    ZSTD_THREADS=0
    MIN_AGE_MIN=30
    SACCT_SINCE="now-30days"
    SACCT_CHUNK=500

    FARM_ROOT="metafarm"
    FARM_NJOBS=7
    FARM_ACCOUNT=""
    FARM_MEM="8G"
    FARM_TIME="10:00:00"
}

# sf_load_config [EXPLICIT_FILE]
sf_load_config() {
    local explicit="${1:-}" v f
    local -A envsnap=()
    for v in "${SF_VARS[@]}"; do
        if [[ -n "${!v+x}" ]]; then envsnap[$v]="${!v}"; fi
    done

    sf_set_defaults
    SF_CONFIG_LOADED=()
    SF_CONFIG_SEARCHED=(/etc/spartflow.conf "${XDG_CONFIG_HOME:-$HOME/.config}/spartflow/conf" "$PWD/spartflow.conf")
    for f in "${SF_CONFIG_SEARCHED[@]}"; do
        if [[ -f $f ]]; then
            # shellcheck disable=SC1090
            source "$f"; SF_CONFIG_LOADED+=("$f")
        fi
    done
    if [[ -n $explicit ]]; then
        [[ -f $explicit ]] || { printf 'ERROR: config not found: %s\n' "$explicit" >&2; exit 1; }
        # shellcheck disable=SC1090
        source "$explicit"; SF_CONFIG_LOADED+=("$explicit")
    fi

    for v in "${!envsnap[@]}"; do printf -v "$v" '%s' "${envsnap[$v]}"; done
    [[ -n $CASE_ROOT ]] || CASE_ROOT="$DEST_ROOT"
    DEST_ROOT="${DEST_ROOT%/}"
    CASE_ROOT="${CASE_ROOT%/}"
    export "${SF_VARS[@]}"
}
