# sjob

`sjob` runs the whole spart pipeline on DRAC clusters (Nibi, Fir, Narval) from one command. It takes a list of case directories and carries them through transfer, preparation, job submission and cleanup. It was built for millions of small single-core ORCA/spart cases.

```
batches  ->  transfer  ->  process   ->  submit    ->  (jobs run)  ->  collect   ->  report
split        Globus        zstd -d +     spart +        Slurm or        sort, pack,    counts
the list     *gbw*         orca_2mkl     sbatch         META-Farm       clean up
```

## Install

```bash
./install.sh                  # installs to ~/.local/bin/sjob
./install.sh /some/prefix     # or somewhere else
./install.sh --uninstall      # remove it again
```

Make sure the install directory's `bin` is on your `PATH`. The installer warns you if it isn't.

To update, pull the repo and run `./install.sh` again. It replaces the installed copy. Your config files are not touched.

## Quick start

Work in a fresh directory. `sjob` keeps all its files (batches, state, results) in the directory you run it from.

```bash
mkdir work && cd work
cp /path/to/sjob/etc/sjob.conf.example sjob.conf
$EDITOR sjob.conf                    # set the endpoints, DEST_ROOT and ENV_SETUP

sjob batches sources.txt --size 500  # sources.txt: one source directory per line
sjob run --all --collect             # transfer -> process -> submit, then collect finished batches
sjob status                          # progress per batch, plus the queue length
sjob collect --all                   # dry run: shows what would be archived
sjob collect --all --apply           # do it for real
sjob report                          # summary of the results
```

`sjob run` can be stopped and started again at any time. Every stage skips work that is already done.

## Commands

| Command | What it does |
|---|---|
| `batches LIST --size N` | Splits a list of source directories into `batch_0001.txt`, `batch_0002.txt`, ... Each line is `<source> <DEST_ROOT>/<source>`. Numbering continues from existing batches. Unsafe paths and duplicates are rejected. |
| `transfer` | Starts a Globus transfer of the `*gbw*` files and waits for it. The task id is saved, so an interrupted run waits for the same task instead of starting a new one. |
| `process` | Runs `zstd -d` and `orca_2mkl` on every case, `NPROC` cases at a time. |
| `submit` | Renames the Molden files, runs `spart ... -j`, submits the jobs and records the job id in `<case>/.jobid`. |
| `collect` | Looks at finished cases and sorts them into DONE and FAILED (see below). |
| `report` | Summarises the results by state, failure reason and dataset. |
| `run` | Runs the stages above over many batches. The next batch's transfer overlaps with the current batch's processing. Options: `--collect`, `--max-batches N`, `--dry-run`. |
| `status` | Shows stage progress, DONE/FAILED counts and the current `squeue` length. |

Commands that work on batches take `--batch FILE` (repeatable) or `--all`. Run `sjob <command> --help` for the options of each command. `collect` is always a dry run unless you add `--apply`.

## How `collect` works

For each batch, once every case has finished:

1. **Still running?** If any case is pending or running in Slurm, the whole batch is skipped and checked again next time. Slurm is queried once per 500 job ids.
2. **DONE** means Slurm says `COMPLETED` and every pattern in `SUCCESS_FILES` matches a non-empty file.
3. **Anything else is FAILED**, with a reason. The reason is the Slurm state (`timeout`, `out_of_memory`, ...), or the first `FAIL_PATTERNS` match in the end of `slurm-*.out`, or `unknown_error`.
4. **Cases without a job id** (for example data made by the old scripts) are judged by their files. A case whose newest file is younger than `MIN_AGE_MIN` minutes counts as still running.

What happens to each group:

- DONE cases are packed into `results/<batch>.tar.zst`. The files in `DELETE_GLOBS` are removed afterwards.
- FAILED cases are listed in `failures/<batch>.tsv`. They are left exactly as they are, and nothing is retried.

The archive is written to a temporary file and tested first (`zstd -t`, entry count, every DONE case present). Only then is it moved into place, and only then is anything deleted. If `collect` crashes after that point, the next run just finishes the cleanup.

## Configuration

Settings are read from these places. Later ones win:

1. built-in defaults
2. `/etc/sjob.conf`
3. `~/.config/sjob/conf`
4. `./sjob.conf`
5. `--config FILE`
6. environment variables, so `NPROC=4 sjob process --all` always wins

Config files are plain shell assignments such as `NPROC=4`. Do not use the `: "${NPROC:=4}"` form. `etc/sjob.conf.example` lists every setting with comments.

The settings you will touch most often:

| Setting | Meaning |
|---|---|
| `SOURCE_ENDPOINT`, `DEST_ENDPOINT` | Globus endpoint ids. |
| `DEST_ROOT` | Where cases are copied to. It is required, and batch files only hold paths below it. |
| `ENV_SETUP` | Shell lines that load your Python environment and modules. |
| `NPROC` | Cases processed at once. |
| `MAX_QUEUED` | `run` waits while this many of your jobs are queued or running. |
| `SPART_ARGS` | Extra arguments for `spart`. |
| `BACKEND` | `sbatch` (default) or `farm`. |
| `SUCCESS_FILES`, `DELETE_GLOBS`, `FAIL_PATTERNS` | What counts as success, what gets removed, and how failures are named. |

## Backends

- **`sbatch`** (default): one Slurm job per case, from the script that `spart -j` writes.
- **`farm`** (`BACKEND=farm`): one META-Farm wave per batch, with one `spart` line per case in `table.dat`.
  - `ENV_SETUP` must include `module load meta-farm`.
  - Each case gets `.jobid = farm:spf_wave_<batch>`, and its log goes to `slurm-farm.out`. `collect` waits while the wave is queued.
  - Slurm has no per-case state here, so failures are judged from the files and the log only. This is the main drawback of `farm`.

## Where files go

Everything is relative to the directory you run `sjob` in:

| Path | Contents |
|---|---|
| `batch_*.txt` | The batches. |
| `state/` | Stage markers, the lock file and Globus task ids. |
| `results/` | One `.tar.zst` per collected batch. |
| `status/` | DONE/FAILED records, read by `report`. |
| `failures/` | One `.tsv` per batch listing the failed cases. |

Most of these locations can be changed in the config (`STATE_DIR`, `RESULTS_DIR`, `STATUS_DIR`, `FAILURES_DIR`, `BATCH_DIR`).
