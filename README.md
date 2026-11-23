# sjob

One command for the whole spart pipeline on DRAC clusters (Nibi / Fir / Narval):

```
batches -> transfer -> process -> submit -> (jobs run) -> collect -> report
 split      Globus     zstd -d +    spart +    Slurm        classify,     counts
 list       *gbw*      orca_2mkl    sbatch     or farm      archive,
                                                             clean
```

## Quick start
```bash
make install                         # ~/.local/bin/sjob  (or ./install.sh PREFIX)
mkdir work && cd work
cp /path/to/sjob/etc/sjob.conf.example sjob.conf   # edit endpoints, DEST_ROOT, ENV_SETUP

sjob batches sources.txt --size 500   # sources.txt: one source dir per line -> batch_0001.txt ...
sjob run --all --collect              # transfer -> process -> submit (resumable), collect finished batches
sjob status                           # per-batch progress + queue length
sjob collect --all                    # dry run: what would be archived / recorded
sjob collect --all --apply            # do it
sjob report                           # counts by state / failure reason / dataset
```
Everything is relative to the directory you run in (`state/`, `results/`, `status/`, `failures/`, `batch_*.txt`).

## Commands
| command | what it does |
|---|---|
| `batches LIST --size N` | writes `batch_NNNN.txt` (`<src> <DEST_ROOT>/<src>`); continues numbering; rejects unsafe paths and duplicates |
| `transfer` | Globus transfer of `*gbw*`; the task id is stored, so an interrupted run waits for the same task |
| `process` | `zstd -d` + `orca_2mkl` per case, `NPROC` in parallel; finished cases are skipped on re-run |
| `submit` | renames Molden files, runs `spart ... -j`, submits through the backend, records `<case>/.jobid` |
| `collect` | per batch, once every case has finished: DONE -> `results/<batch>.tar.zst` (verified, then `DELETE_GLOBS` removed); FAILED -> `failures/<batch>.tsv`, **nothing removed, nothing retried** |
| `report` | summary of `status/*.tsv` |
| `run` | the stages over many batches; the next transfer overlaps this batch's processing; `--collect`, `--max-batches N`, `--dry-run` |
| `status` | stage markers, DONE/FAILED counts, `squeue` length |

Per-batch commands take `--batch FILE` (repeatable) or `--all`. `collect` is a dry run unless `--apply`.

## How `collect` decides
1. Slurm `PENDING/RUNNING/...` (one `sacct` per 500 ids) -> the batch is skipped and retried next time.
2. `DONE`: Slurm `COMPLETED` **and** every `SUCCESS_FILES` pattern matches a non-empty file.
3. Anything else that finished is `FAILED`, with a reason: the Slurm state (`timeout`, `out_of_memory`, ...) or the first `FAIL_PATTERNS` regex matching the end of `slurm-*.out`, else `unknown_error`.
4. Cases without a job id (e.g. data from older scripts) are judged by files; a case whose newest file is younger than `MIN_AGE_MIN` counts as still running.

Safety: the archive is written to `*.tmp`, tested (`zstd -t`, entry count, every DONE case present) and only then moved into place and used to delete anything. A crash after that resumes with cleanup only.

## Configuration
Layers, lowest to highest: defaults < `/etc/sjob.conf` < `~/.config/sjob/conf` < `./sjob.conf` < `--config FILE` < environment. See `etc/sjob.conf.example` for every setting. Config files use plain assignments (`NPROC=4`), not `: "${NPROC:=4}"`.

## Backends
- `sbatch` (default): one job per case from spart's `-j` script.
- `farm` (`BACKEND=farm`): one META-Farm wave per batch, one `spart part ...` line per case in `table.dat`, no `-auto`. `ENV_SETUP` must `module load meta-farm`. Each case gets `.jobid = farm:spf_wave_<batch>` and its log in `slurm-farm.out`, so `collect` waits while the wave is queued. Per-case Slurm states are unknown here (no `sacct` detail), so failures are judged from files and the log.

## Tests
`make test` runs `tests/run.sh` against stub `globus`, `sbatch`, `sacct`, `squeue`, `spart`, `orca_2mkl`, `farm_init.run`, `submit.run` (no cluster needed). `make lint` runs `bash -n` and shellcheck when installed.

`legacy/` holds frozen copies of the old scripts for reference.
