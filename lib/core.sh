# core.sh -- logging, stage markers, locking, environment, queue throttle.
# Sourced by bin/spartflow. Needs config.sh to have been loaded for most helpers.

SF_VERSION="0.1.0"
SF_VERBOSE="${SF_VERBOSE:-0}"

info()  { printf '%s\n' "$*" >&2; }
warn()  { printf 'WARNING: %s\n' "$*" >&2; }
die()   { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
vlog()  { if ((SF_VERBOSE)); then printf '%s\n' "$*" >&2; fi; return 0; }

# require_var NAME...  -- die unless each config variable is non-empty.
require_var() {
    local v
    for v in "$@"; do
        [[ -n "${!v:-}" ]] || die "config variable $v is not set.
  Config files read: ${SF_CONFIG_LOADED[*]:-(none)}
  Looked for: ${SF_CONFIG_SEARCHED[*]:-?} and --config FILE
  etc/spartflow.conf.example is only a template: copy it to ./spartflow.conf in the
  directory you run spartflow from (or pass --config FILE) and set $v there."
    done
}

require_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "required command not found on PATH: $c"
    done
}

# --------------------------------------------------------------------------
# Environment (pyenv / modules). Only commands that run spart/orca need it.
# --------------------------------------------------------------------------
load_env() {
    [[ -z "${SF_ENV_LOADED:-}" ]] || return 0
    if [[ -n "${ENV_SETUP//[[:space:]]/}" ]]; then
        set +u                      # pyenv/modulefiles reference unset variables
        eval "$ENV_SETUP" || { set -u; die "ENV_SETUP failed"; }
        set -u
    fi
    if [[ -z "${ORCA_2MKL:-}" ]]; then
        if [[ -n "${EBROOTORCA:-}" ]]; then ORCA_2MKL="$EBROOTORCA/orca_2mkl"; else ORCA_2MKL="orca_2mkl"; fi
    fi
    export ORCA_2MKL ZSTD SF_ENV_LOADED=1
}

# --------------------------------------------------------------------------
# Stage markers: $STATE_DIR/<batch>/<stage>   (transferred processed submitted collected)
# --------------------------------------------------------------------------
stage_done()   { [[ -f "$STATE_DIR/$1/$2" ]]; }
stage_mark()   { mkdir -p "$STATE_DIR/$1" && touch "$STATE_DIR/$1/$2"; }
stage_unmark() { rm -f "$STATE_DIR/$1/$2"; }

# One mutating spartflow per work directory.
acquire_lock() {
    command -v flock >/dev/null 2>&1 || { warn "flock not available; running without a lock"; return 0; }
    mkdir -p "$STATE_DIR" || die "cannot create $STATE_DIR"
    exec {SF_LOCK_FD}>"$STATE_DIR/lock" || die "cannot open lock file"
    flock -n "$SF_LOCK_FD" || die "another spartflow is already running in this directory ($STATE_DIR/lock)"
}

# --------------------------------------------------------------------------
# Queue throttle: block until fewer than MAX_QUEUED of my jobs are queued/running.
# --------------------------------------------------------------------------
queue_length() {
    # -r expands job arrays (each task counts toward the submit limit).
    local out
    out=$(squeue -u "${USER:-$(id -un)}" -h -r -o '%i' 2>/dev/null) || return 1
    if [[ -z $out ]]; then echo 0; else wc -l <<<"$out"; fi
}

wait_for_queue() {
    local n
    while true; do
        # A transient squeue failure must not be mistaken for "0 jobs".
        if ! n=$(queue_length); then
            info "squeue failed, retrying in ${POLL_SECONDS}s..."
            sleep "$POLL_SECONDS"
            continue
        fi
        if ((n < MAX_QUEUED)); then
            vlog "Queue has $n jobs (< $MAX_QUEUED). Continuing."
            return 0
        fi
        info "$(date '+%F %T') Queue has $n jobs (need < $MAX_QUEUED). Waiting ${POLL_SECONDS}s..."
        sleep "$POLL_SECONDS"
    done
}

# Run FUNCTION over many arguments in parallel via the dispatcher's internal
# worker entry point (no `export -f`). Usage: parallel_workers CMDFILE FUNC < args-one-per-line
parallel_workers() {
    xargs -r -d '\n' -P "$NPROC" -n 20 "$SF_BIN" _worker "$1" "$2"
}
