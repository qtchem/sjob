#!/bin/bash
# tests/run.sh -- end-to-end tests against stub cluster tools (no Slurm/Globus needed).
#   tests/run.sh            run everything
#   tests/run.sh e2e farm   run only tests whose name contains one of the words
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SJ="$HERE/../bin/sjob"
PASS=0; FAIL=0; FAILED_TESTS=()
CUR=""

# ---------------------------------------------------------------- helpers
ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); FAILED_TESTS+=("$CUR: $*"); printf '    FAIL: %s\n' "$*"; }
assert_eq()       { [[ "$1" == "$2" ]] && ok || bad "${3:-value}: expected '$2', got '$1'"; }
assert_file()     { [[ -e "$1" ]] && ok || bad "missing: $1"; }
assert_no_file()  { [[ ! -e "$1" ]] && ok || bad "should not exist: $1"; }
assert_contains() { grep -qF -- "$2" <<<"$1" && ok || bad "output lacks '$2'"; }
assert_lacks()    { grep -qF -- "$2" <<<"$1" && bad "output has '$2'" || ok; }

# Fresh work dir with 10 fake cases (2 of them "BAD": spart fails on them).
setup() {
    W=$(mktemp -d "${TMPDIR:-/tmp}/sj-test.XXXXXX")
    export STUB_STATE="$W/stub" FAKE_SRC="$W/src"
    mkdir -p "$STUB_STATE" "$W/dest" "$W/src"
    export PATH="$HERE/stubs/bin:$PATH"
    local i name
    : >"$W/list.txt"
    for i in 01 02 03 04 05 06 07 08 09 10; do
        name="set/c$i"; [[ $i == 03 || $i == 08 ]] && name="set/c${i}_BAD"
        mkdir -p "$W/src/$name"
        printf 'gbw-data-%s' "$i" | zstd -q -o "$W/src/$name/orca.gbw.zstd0"
        echo "$name" >>"$W/list.txt"
    done
    cat >"$W/sjob.conf" <<EOF
DEST_ROOT="$W/dest"
SOURCE_ENDPOINT=src-ep
DEST_ENDPOINT=dst-ep
NPROC=4
POLL_SECONDS=1
MIN_AGE_MIN=0
FARM_ACCOUNT=def-test
ENV_SETUP='export SJ_TEST_ENV=loaded'
EOF
    cd "$W" || exit 1
}
teardown() { cd /; rm -rf "$W"; }
sj() { "$SJ" "$@" 2>&1; }

run_test() {
    CUR="$1"; shift
    printf '  %s\n' "$CUR"
    setup
    "$CUR"
    teardown
}

# ---------------------------------------------------------------- tests
t_config_precedence() {
    echo 'NPROC=3
MAX_QUEUED=11' >"$W/sjob.conf"
    echo 'MAX_QUEUED=22' >"$W/other.conf"
    # shellcheck disable=SC2016
    local show='source "$SJOB_HOME/lib/core.sh"; source "$SJOB_HOME/lib/config.sh"; sj_load_config "$1"; echo "$NPROC $MAX_QUEUED"'
    assert_eq "$(SJOB_HOME="$HERE/.." bash -c "$show" _ "")" "3 11" "file overrides default"
    assert_eq "$(SJOB_HOME="$HERE/.." bash -c "$show" _ "$W/other.conf")" "3 22" "--config overrides ./sjob.conf"
    assert_eq "$(NPROC=9 SJOB_HOME="$HERE/.." bash -c "$show" _ "$W/other.conf")" "9 22" "env overrides files"
}

t_batches() {
    local out
    out=$(sj batches list.txt --size 4)
    assert_contains "$out" "wrote 3 batch file(s)"
    assert_eq "$(wc -l <batch_0001.txt)" 4 "first batch size"
    assert_eq "$(wc -l <batch_0003.txt)" 2 "last batch size"
    assert_eq "$(head -1 batch_0001.txt)" "set/c01 $W/dest/set/c01" "line format"
    # a second call continues numbering instead of overwriting
    out=$(sj batches list.txt --size 4); assert_contains "$out" "batch_0004 ... batch_0006"
    assert_file batch_0004.txt
    echo "../etc/passwd" >evil.txt
    out=$(sj batches evil.txt --size 2 --out-dir evil); assert_contains "$out" "unsafe source path"
    assert_no_file evil/batch_0001.txt
}

# Run the whole pipeline on two batches of five cases.
make_two_batches() { sj batches list.txt --size 5 >/dev/null; }

t_e2e_sbatch() {
    make_two_batches
    local out md5
    out=$(sj run --all)
    assert_contains "$out" "run finished: 2 batch(es) submitted"
    assert_eq "$(cat "$STUB_STATE/globus_count")" 2 "one transfer per batch"
    assert_file dest/set/c01/set_c01.molden.input
    assert_no_file dest/set/c01/orca.gbw.zstd0
    assert_no_file dest/set/c01/orca.gbw
    assert_file dest/set/c01/.jobid
    assert_eq "$(cat dest/set/c01/orca.molden.input 2>/dev/null | wc -l)" 0 "molden renamed away"

    out=$(sj status); assert_contains "$out" "batch_0001"

    # dry run changes nothing
    out=$(sj collect --all)
    assert_contains "$out" "[batch_0001] 5 cases: 4 DONE, 1 FAILED"
    assert_contains "$out" "dry run"
    assert_no_file results

    md5=$(cd dest && find set -path '*BAD*' -type f -printf '%p %s\n' | sort | md5sum)
    out=$(sj collect --all --apply)
    assert_contains "$out" "archived 4 cases (8 files)"
    assert_eq "$(zstd -dcq results/batch_0001.tar.zst | tar -tf - | wc -l)" 8 "archive entries"
    assert_eq "$(awk -F'\t' '!/^#/' failures/batch_0001.tsv | wc -l)" 1 "failure rows"
    assert_contains "$(cat failures/batch_0001.tsv)" "dipole_integration"
    assert_no_file dest/set/c01                       # cleaned, empty dir removed
    assert_eq "$(cd dest && find set -path '*BAD*' -type f -printf '%p %s\n' | sort | md5sum)" "$md5" "failed dirs untouched"
    assert_file state/batch_0001/collected

    # second run is a no-op
    out=$(sj collect --all --apply); assert_contains "$out" "already collected"
    out=$(sj report)
    assert_contains "$out" "DONE     8"
    assert_contains "$out" "dipole_integration       2"
    # archive round-trip
    mkdir x && zstd -dcq results/batch_0001.tar.zst | tar -xf - -C x
    assert_contains "$(cat x/set/c01/data_denspart.json)" "charges"
}

t_idempotent_rerun() {
    make_two_batches
    sj run --all >/dev/null
    local out; out=$(sj run --all)
    assert_contains "$out" "nothing to do"
    assert_eq "$(cat "$STUB_STATE/globus_count")" 2 "no extra transfers"
    assert_eq "$(cat "$STUB_STATE/sbatch_count")" 1010 "no extra jobs"
}

t_process_failure_resumes() {
    make_two_batches
    sj transfer --batch batch_0001.txt >/dev/null
    mv dest/set/c04/orca.gbw.zstd0 "$W/hold"            # one case lost
    local out; out=$(sj process --batch batch_0001.txt); local rc=$?
    assert_contains "$out" "missing"
    assert_eq "$((rc != 0))" 1 "process must fail"
    assert_no_file state/batch_0001/processed
    mv "$W/hold" dest/set/c04/orca.gbw.zstd0
    out=$(sj process --batch batch_0001.txt)
    assert_file state/batch_0001/processed
    assert_file dest/set/c01/orca.molden.input
    # submit refuses until processed, then works
    out=$(sj submit --batch batch_0002.txt); assert_contains "$out" "not processed yet"
}

t_running_job_blocks_collect() {
    make_two_batches
    sj run --all >/dev/null
    echo RUNNING >"$STUB_STATE/jobs/1001"
    local out; out=$(sj collect --batch batch_0001.txt --apply)
    assert_contains "$out" "not finished"
    assert_contains "$out" "slurm_RUNNING=1"
    assert_no_file results
    echo COMPLETED >"$STUB_STATE/jobs/1001"
    out=$(sj collect --batch batch_0001.txt --apply)
    assert_contains "$out" "archived"
}

t_corrupt_archive_blocks_delete() {
    make_two_batches
    sj run --all >/dev/null
    sj collect --batch batch_0001.txt --apply >/dev/null
    # simulate: files came back, marker lost, archive damaged
    rm state/batch_0001/collected
    head -c 50 results/batch_0001.tar.zst >results/x && mv results/x results/batch_0001.tar.zst
    mkdir -p dest/set/c01 && echo keep >dest/set/c01/data_denspart.json
    local out; out=$(sj collect --batch batch_0001.txt --apply)
    assert_contains "$out" "NOT deleting anything"
    assert_file dest/set/c01/data_denspart.json
}

t_collect_resume_cleanup_only() {
    make_two_batches
    sj run --all >/dev/null
    sj collect --batch batch_0001.txt --apply >/dev/null
    rm state/batch_0001/collected
    mkdir -p dest/set/c01 && echo x >dest/set/c01/data_denspart.json     # crash left files behind
    local out; out=$(sj collect --batch batch_0001.txt --apply)
    assert_contains "$out" "resuming"
    assert_no_file dest/set/c01
    assert_file state/batch_0001/collected
}

t_delete_globs_from_config() {
    make_two_batches
    sj run --all >/dev/null
    echo 'DELETE_GLOBS="*.molden.input"' >>sjob.conf
    sj collect --batch batch_0001.txt --apply >/dev/null
    assert_file dest/set/c01/data_denspart.json              # results kept: not in DELETE_GLOBS
    assert_no_file dest/set/c01/set_c01.molden.input
}

t_throttle_and_lock() {
    make_two_batches
    printf '1\n2\n3\n' >"$STUB_STATE/queue"
    echo 'MAX_QUEUED=2' >>sjob.conf
    timeout 4 "$SJ" run --all >/dev/null 2>&1; local rc=$?
    assert_eq "$rc" 124 "blocked by full queue"
    assert_no_file "$STUB_STATE/globus_count"
    # lock: a second mutating command is refused while one holds the lock
    : >"$STUB_STATE/queue"
    mkdir -p state
    ( exec 9>state/lock; flock 9; sleep 4 ) &
    sleep 1
    local out; out=$(sj transfer --all); assert_contains "$out" "already running"
    wait
}

t_failed_sbatch_is_not_marked_submitted() {
    make_two_batches
    touch "$STUB_STATE/sbatch_fail"
    local out; out=$(sj run --batch batch_0001.txt)
    assert_no_file state/batch_0001/submitted
    assert_contains "$out" "sbatch failed"
    rm "$STUB_STATE/sbatch_fail"
    out=$(sj run --batch batch_0001.txt)
    assert_file state/batch_0001/submitted
    assert_file dest/set/c01/.jobid
}

t_run_collect_hook() {
    make_two_batches
    local out; out=$(sj run --all --collect)
    assert_contains "$out" "archived 4 cases"        # batch 1 collected before batch 2 starts
    assert_file state/batch_0001/collected
    assert_no_file state/batch_0002/collected        # nothing after it to trigger collecting
}

t_farm_backend() {
    make_two_batches
    echo 'BACKEND=farm' >>sjob.conf
    echo "FARM_ROOT=$W/metafarm" >>sjob.conf
    local out; out=$(sj run --all)
    assert_contains "$out" "submitting wave wave_batch_0001 (5 cases, 5 metajobs)"
    local wave=metafarm/wave_batch_0001
    assert_lacks "$(cat $wave/table.dat)" " -j"
    assert_lacks "$(cat $wave/table.dat)" "example line"
    assert_contains "$(cat $wave/table.dat)" "spart part set_c01.molden.input"
    assert_contains "$(cat $wave/job_script.sh)" "#SBATCH -A def-test"
    assert_contains "$(cat $wave/job_script.sh)" "#SBATCH -J spf_wave_batch_0001"
    assert_contains "$(cat $wave/job_script.sh)" "export SJ_TEST_ENV=loaded"
    assert_eq "$(cat dest/set/c01/.jobid)" "farm:spf_wave_batch_0001" ".jobid"
    assert_file dest/set/c01/slurm-farm.out

    # wave still in the queue -> collect waits; afterwards it classifies
    echo spf_wave_batch_0001 >"$STUB_STATE/farm_running"
    out=$(sj collect --batch batch_0001.txt --apply)
    assert_contains "$out" "not finished"
    assert_contains "$out" "slurm_RUNNING=5"
    : >"$STUB_STATE/farm_running"
    out=$(sj collect --batch batch_0001.txt --apply)
    assert_contains "$out" "4 DONE, 1 FAILED"
    assert_contains "$(cat failures/batch_0001.tsv)" "dipole_integration"
    assert_no_file dest/set/c01
}

t_transfer_task_reused_after_interrupt() {
    make_two_batches
    sj transfer --batch batch_0001.txt --no-wait >/dev/null
    assert_file state/batch_0001/transfer_task
    local out; out=$(sj transfer --batch batch_0001.txt)
    assert_eq "$(cat "$STUB_STATE/globus_count")" 1 "task reused, not resubmitted"
    assert_file state/batch_0001/transferred
}

# ---------------------------------------------------------------- main
filter=("$@")
for fn in $(declare -F | awk '{print $3}' | grep '^t_'); do
    if ((${#filter[@]})); then
        hit=0; for w in "${filter[@]}"; do [[ $fn == *"$w"* ]] && hit=1; done
        ((hit)) || continue
    fi
    run_test "$fn"
done

echo
echo "passed: $PASS  failed: $FAIL"
if ((FAIL)); then printf '  - %s\n' "${FAILED_TESTS[@]}"; exit 1; fi
