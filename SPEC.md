# SPEC — behavior contract for all language implementations

This document defines the behavior every implementation (`php/`, `bash/`, later `powershell/`)
must match. When fixing a bug or adding a feature, update this file first, then bring every
implementation in line with it, then update CHANGELOG.md.

## Purpose

Backs up all databases of every **running** PostgreSQL cluster/instance on the host into
per-day, per-cluster directories, keeps a rolling number of daily generations, and mails a run
summary. How clusters are found is distro-dependent — see "Cluster / instance discovery" below.

## Versioning

The whole project (all language implementations together) shares one version number, not one
per language — e.g. "1.3.0" describes the state of `php/`, `bash/`, etc. combined at that point,
even if a given release only actually touched one of them. Record what changed per area in
CHANGELOG.md.

## Cluster / instance discovery

Two discovery strategies, tried in order. An implementation must support at least strategy 1
where the tooling exists, and fall back to strategy 2 everywhere else.

### 1. `pg_lsclusters` (Debian/Ubuntu, via `postgresql-common`)

If the `pg_lsclusters` binary exists, use `pg_lsclusters -h -j` and trust its `version`,
`cluster`, `running`, `port`, `socketdir` fields directly. This is the only tool that reports
multiple *clusters of the same major version* (e.g. `main` + a second cluster on another port),
so prefer it whenever available.

### 2. `postmaster.pid` scan (RHEL/CentOS/Rocky/Alma and any other Linux)

RHEL-family PostgreSQL (distro package or PGDG `postgresqlNN-server` packages) has no
multi-cluster concept and no equivalent listing tool — each major version is normally exactly
one instance, one data directory. Detect it generically, using only facts PostgreSQL itself
guarantees, not distro conventions:

1. Look for data directories under a configurable list of glob patterns (default:
   `/var/lib/pgsql/data`, `/var/lib/pgsql/*/data` — covers both the single-instance distro
   package and versioned PGDG packages; additional globs can be added in the ini file for
   non-standard installs).
2. A directory is a valid PG data directory if it contains `PG_VERSION` — its content is the
   major version string (`version`).
3. It's running if `postmaster.pid` exists in that directory. If not present, skip it (log at
   terse level) exactly like a `pg_lsclusters` cluster with `running != 1`.
4. If running, **parse `postmaster.pid` directly** instead of asking the distro anything:
   line 4 is the port, line 5 is the socket directory (first entry if it lists more than one,
   comma-separated). This format is a PostgreSQL server guarantee, identical across distros —
   it's the same mechanism `pg_ctl`/`pg_isready` rely on, not something specific to RHEL.
5. `cluster` name: RHEL has no user-facing cluster name, so use `main` — there is normally only
   one instance per version, so this does not collide. (A future multi-instance-per-version setup
   on RHEL would need a real name source; out of scope for 1.3.0.)

Both strategies must produce the same shape: `{version, cluster, running, port, socketdir}`, so
the rest of the pipeline (database enumeration, `pg_dump`, directory layout) is identical
regardless of which one found the instance.

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
