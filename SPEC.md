# SPEC — behavior contract for all language implementations

This document defines the behavior every implementation (`php/`, `bash/`, `powershell/`)
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

Per-platform discovery strategies. An implementation must support the primary strategy for its
platform where the tooling exists, and fall back to the platform's secondary strategy otherwise.

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

### 3. Windows service enumeration (PowerShell — planned, not yet implemented)

Windows has no `pg_lsclusters` equivalent either, but this is closer to Debian's model than to
RHEL's: every PostgreSQL install (EDB installer, Chocolatey, etc.) registers itself as its own
named Windows service running `pg_ctl.exe`, one per version/instance — and Windows genuinely
supports several instances side by side under different service names/ports, unlike RHEL.

**Deliberately not a port scanner and not a blind directory scan.** A listening port doesn't
tell you it's PostgreSQL, which version, or where its data directory is; you'd have to guess a
port range and probe every hit. Windows already tracks this authoritatively — use it:

1. `Get-CimInstance Win32_Service | Where-Object { $_.PathName -match 'pg_ctl\.exe' }` — finds
   every PostgreSQL service regardless of install location or naming, no guessing needed.
2. Extract the data directory from the service's own command line — the `-D "<path>"` argument
   inside `PathName` (e.g. `"...\pg_ctl.exe" runservice -N "postgresql-x64-15" -D "C:\Program
   Files\PostgreSQL\15\data" -w`). This is the service definition's authoritative source, not a
   guess from a naming convention.
3. `running`: the service's `State -eq 'Running'` — more reliable than a pidfile existence check.
4. `version`: read `PG_VERSION` from the data directory, same as strategy 2 — not parsed from the
   install path, which is user-configurable.
5. `port`: read `postmaster.pid` line 4 — the same pidfile format PostgreSQL uses on every
   platform. Windows PostgreSQL has no Unix socket, so `socketdir` is not applicable there.
6. `cluster` name: the Windows service name itself (e.g. `postgresql-x64-15`) — unlike RHEL's
   hardcoded `main`, this correctly distinguishes genuine multiple instances of the same version.

Fallback (portable/non-service installs that never register a service): scan a configurable list
of glob patterns, the same `pgdata_globs`-style mechanism as strategy 2, for parity with the
Linux fallback.

All three strategies must produce the same shape: `{version, cluster, running, port, socketdir}`,
so the rest of the pipeline (database enumeration, `pg_dump`, directory layout) is identical
regardless of which one found the instance. On Windows, `socketdir` is empty/null and
implementations must connect via `-h localhost -p <port>` instead.

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

**PowerShell deviation:** PowerShell parameter names/aliases are case-insensitive, so `-D`
(backup dir) and `-d` (debug level) can't coexist as distinct flags there. The PowerShell port
keeps `-D`/`-BackupDir`, but debug level is `-DebugLevel` (alias `-dl`) instead of `-d`. It also
uses full names for the long options (`-Help`, `-IniWrite`, `-IniShow`, `-Email`) rather than
`--double-dash` syntax, since that isn't idiomatic PowerShell. Behavior is otherwise identical.

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
