# SPEC — behavior contract for all language implementations

This document defines the behavior every implementation (`php/`, `bash/`, later `powershell/`)
must match. When fixing a bug or adding a feature, update this file first, then bring every
implementation in line with it, then update CHANGELOG.md.

## Purpose

Backs up all databases of every **running** PostgreSQL cluster detected via `pg_lsclusters -h -j`
into per-day, per-cluster directories, keeps a rolling number of daily generations, and mails a
run summary.

## CLI options

| Short | Long          | Value | Default                        | Meaning                                   |
|-------|---------------|-------|---------------------------------|--------------------------------------------|
| `-i`  |               | path  | `<script-dir>/pg_clusterbackup.ini` | ini file to read/write                |
| `-h`  |               | str   | `gethostname()`                 | hostname used in mail subject/paths       |
| `-D`  |               | path  | `/data/backup/postgresql`       | backup root directory                     |
| `-T`  |               | path  | `/tmp`                          | temp directory for in-progress dumps      |
| `-L`  |               | path  | value of `-D`                   | log directory                             |
| `-F`  |               | c/t/p | `c`                              | `pg_dump` format                          |
| `-d`  |               | 0-3   | `1`                              | debug/log level (0=off,1=log,2=terse,3=verbose) |
| `-n`  |               | int   | `7`                              | number of daily generations to keep       |
|       | `--email`     | str   | `monitor@ibou.net`              | mail recipient for the run log            |
|       | `--help`      | flag  |                                  | print usage and exit                      |
|       | `--ini-write` | flag  |                                  | persist current settings to the ini file  |
|       | `--ini-show`  | flag  |                                  | print current settings in ini format      |

All non-flag options are also persisted to / read from the ini file; CLI values always win over
ini values.

## Ini file format

Standard INI, one `key = "value"` per line, no sections unless a setting is itself an array.
Written with `ini-write`, read on every run if present.

## Directory layout produced

```
<backupdir>/<YYYYMMDD>/<pg-version>/<cluster-name>/<database>.cus
<backupdir>/<YYYYMMDD>/<pg-version>/<cluster-name>/globals.sql
```

## Run behavior (must match across implementations)

1. Acquire an exclusive lock (e.g. `<tempdir>/pg_clusterbackup.lock`) — abort with a clear error
   if another run holds it. Never let two runs write to the same temp files concurrently.
2. Enumerate clusters; skip (and log) any cluster where `running != 1`.
3. For each running cluster: list non-template databases (excluding `postgres`), dump each with
   `pg_dump -c -F<format>` to a temp file, then move it into the final dated path.
4. Dump globals with `pg_dumpall -g`.
5. Only **after** all clusters/databases were backed up without a fatal error: delete backup-date
   directories beyond the newest `-n` generations.
6. Mail the collected log (🟢 OK on success, 🟥 failed on any fatal error) if an email recipient
   is configured and there is anything to report.
7. All values interpolated into shell commands must be shell-escaped.
8. A move from temp dir to backup dir must work even when both are on different filesystems
   (fall back to copy+remove if a direct rename/move fails).

## Exit / error behavior

- Any fatal error during backup must still result in a failure mail being sent, with the error
  message included in the log — even if the error happened during initial setup.
- `--help`, `--ini-write`, `--ini-show` never trigger a backup run.
