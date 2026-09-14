# pg-clusterbackup

Backs up **every database of every running PostgreSQL cluster/instance** on Debian/Ubuntu,
RHEL-family (CentOS/Rocky/Alma), or Windows in one scheduled job — no manual per-cluster,
per-database configuration needed. Detects instances via `pg_lsclusters`, Windows services, or by
scanning data directories directly, whichever applies; dumps each database individually (so
single databases can be restored without touching the rest), dumps globals separately, rotates
old generations, and mails you the result.

Available as **PHP** (`php/`), **Bash** (`bash/`), and **PowerShell** (`powershell/`)
implementations, kept behaviorally identical per [SPEC.md](SPEC.md).

Maintained by [Frank Glück](https://dozent.net) — database consultant, developer, and trainer.

## Why

Most PostgreSQL backup scripts assume a single cluster and a fixed list of databases. On hosts
running several PostgreSQL major versions / clusters side by side (a common Debian/Ubuntu setup
via `postgresql-common`), that means hand-maintaining the database list per cluster. This script
instead asks the OS what's actually running and backs up all of it — new databases and new
clusters are picked up automatically on the next run.

## Requirements

- Debian/Ubuntu with `postgresql-common` (provides `pg_lsclusters`), RHEL/CentOS/Rocky/Alma with
  PostgreSQL from the distro package or a PGDG `postgresqlNN-server` package, or Windows with
  PostgreSQL installed as a service (EDB installer, Chocolatey, ...)
- PHP CLI (for `php/`), Bash 4+ with `flock`, `mail`/`mailx`, and — only when `pg_lsclusters` is
  present — `jq` (for `bash/`), or PowerShell 5.1+/7+ (for `powershell/`)
- Linux: passwordless `sudo -u postgres` for the user running this script (typically root via
  cron). Windows: no `sudo` equivalent — configure `pg_hba.conf`/credentials so the running user
  can connect as the `postgres` role via `localhost`.
- Windows only: an `smtp_server` ini setting to send mail (there's no local MTA to fall back to)
- Enough free space on the backup destination; `tempdir` and `backupdir` may be on different
  filesystems, the script handles the fallback

On RHEL-family hosts without `pg_lsclusters`, and on Windows for non-service/portable installs,
data directories are found via the `pgdata_globs` setting (Linux default: `/var/lib/pgsql/data`,
`/var/lib/pgsql/*/data`; Windows default: `C:\Program Files\PostgreSQL\*\data`) — override it in
the ini file for non-standard locations. See [SPEC.md](SPEC.md) for how discovery works on each
platform.

## Install

Just want the script, no repo clutter? Download the single file, pinned to a release tag —
pick PHP, Bash, or PowerShell:

```sh
curl -O https://raw.githubusercontent.com/glueck-it/pg-clusterbackup/v1.7.0/php/pg_clusterbackup.php
chmod +x pg_clusterbackup.php
```

```sh
curl -O https://raw.githubusercontent.com/glueck-it/pg-clusterbackup/v1.7.0/bash/pg_clusterbackup.sh
chmod +x pg_clusterbackup.sh
```

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/glueck-it/pg-clusterbackup/v1.7.0/powershell/pg_clusterbackup.ps1 -OutFile pg_clusterbackup.ps1
```

Or clone the full repo (includes examples, SPEC.md, CHANGELOG.md):

```sh
git clone https://github.com/glueck-it/pg-clusterbackup.git
cd pg-clusterbackup/php    # or: cd pg-clusterbackup/bash, cd pg-clusterbackup/powershell
chmod +x pg_clusterbackup.*
```

## Quick start

All three implementations take equivalent options (see SPEC.md for the exact PowerShell naming
differences) — examples below use the PHP one, swap in `pg_clusterbackup.sh` or
`pg_clusterbackup.ps1` for the other ports.

```sh
# see all options
./pg_clusterbackup.php --help

# write your settings to an ini file once (-j 4: 4 databases concurrently, -C 2: 2 clusters concurrently)
./pg_clusterbackup.php -D /data/backup/postgresql --email you@example.com -n 14 -j 4 -C 2 --ini-write

# from then on, just run it (e.g. from cron) — it reads the ini file
./pg_clusterbackup.php
```

Example crontab entry (daily at 02:30):

```
30 2 * * * root /opt/pg-clusterbackup/pg_clusterbackup.php
```

PowerShell equivalent (long option names instead of `--double-dash`, see Options below):

```powershell
.\pg_clusterbackup.ps1 -D C:\Backup\PostgreSQL -Email you@example.com -MaxKeep 14 -Jobs 4 -ParallelClusters 2 -IniWrite
.\pg_clusterbackup.ps1
```

Register it as a Scheduled Task for unattended daily runs (`Register-ScheduledTask` or the Task
Scheduler GUI).

An example ini file is in [examples/pg_clusterbackup.ini.example](examples/pg_clusterbackup.ini.example).

## Options

| Short | Long          | Meaning                                              | Default                    |
|-------|---------------|-------------------------------------------------------|-----------------------------|
| `-i`  |               | path to ini file                                      | `<script-dir>/pg_clusterbackup.ini` |
| `-h`  |               | hostname used in mail subject/paths                   | system hostname             |
| `-D`  |               | backup root directory                                 | `/data/backup/postgresql`   |
| `-T`  |               | temp directory for in-progress dumps                  | `/tmp`                      |
| `-L`  |               | log directory                                         | same as `-D`                |
| `-F`  |               | `pg_dump` format: `c` (custom), `t` (tar), `p` (plain) | `c`                          |
| `-d`  |               | debug level: `0` off, `1` log, `2` terse, `3` verbose | `1`                          |
| `-n`  |               | number of daily generations to keep                   | `7`                          |
| `-j`  |               | max concurrent `pg_dump` processes per cluster        | `1`                          |
| `-C`  |               | max concurrent cluster backups                        | `1`                          |
|       | `--email`     | mail recipient for the run log                        | none                         |
|       | `--ini-write` | persist current settings (incl. any flags above) to the ini file | |
|       | `--ini-show`  | print current effective settings in ini format        |                              |
|       | `--help`      | show usage                                            |                              |

PowerShell uses the same short flags except debug level (`-DebugLevel`/`-dl` instead of `-d`,
since PowerShell parameter names are case-insensitive and can't tell `-D` and `-d` apart),
`-ParallelClusters` (alias `-cj` or `-C`), and
full names instead of `--double-dash` for the flag-only options (`-Help`, `-IniWrite`,
`-IniShow`, `-Email`). See [SPEC.md](SPEC.md) for the exact mapping and the full behavior
contract for all three ports.

## What it produces

```
<backupdir>/<YYYYMMDD>/<pg-version>/<cluster-name>/<database>.cus
<backupdir>/<YYYYMMDD>/<pg-version>/<cluster-name>/globals.sql
```

Restore a single database:

```sh
pg_restore -h <socketdir> -p <port> -d <database> <backupdir>/<date>/<version>/<cluster>/<database>.cus
```

## Safety features

- Exclusive lock file (or lock-file-equivalent handle on Windows) — an overlapping scheduled run
  refuses to start instead of corrupting temp files
- Old generations are deleted only *after* a successful run, never before
- No raw values are interpolated into a shell string (escaped in PHP, passed as separate
  argv/argument entries in Bash and PowerShell) — all three avoid the classic shell-injection
  footgun
- Temp-to-backup moves work across filesystem/drive boundaries
- Restrictive `umask` while dumping on Linux, so temp files aren't briefly world-readable

## Related Tools

- **[PostgreSQL Konfigurator](https://dozent.net/produkte/postgresql-konfigurator)** — A web-based tool to generate optimized, hardware-tailored `postgresql.conf` configurations (memory sizing, connection limits, checkpoint, and WAL tuning).

## License

MIT — see [LICENSE](LICENSE).

## About the author

Built and maintained by **Frank Glück** ([Glück IT](https://dozent.net)) — a consultant,
developer, and trainer working with databases and programming languages. A lot of my current
project work is migrating databases to PostgreSQL from
[Oracle](https://dozent.net/seminare/postgresql/migration/migration-von-oracle-zu-postgresql),
[SQL Server](https://dozent.net/seminare/postgresql/migration/postgresql-migration-von-sql-server),
[DB2](https://dozent.net/seminare/postgresql/migration/postgresql-migration-von-db2),
[Informix](https://dozent.net/seminare/postgresql/migration/postgresql-migration-von-informix),
[Sybase](https://dozent.net/seminare/postgresql/migration/postgresql-migration-von-sybase), or
[MS Access](https://dozent.net/seminare/postgresql/migration/postgresql-migration-von-ms-access),
plus data analysis work that isn't limited to PostgreSQL.

- Need help with PostgreSQL itself, a migration, or backup strategy? [Get in touch](https://dozent.net).
- I also run seminars (German) on [PostgreSQL administration](https://dozent.net/seminare/postgresql/postgresql-administration),
  [performance tuning](https://dozent.net/seminare/postgresql/postgresql-performance-tuning),
  [PL/pgSQL](https://dozent.net/seminare/postgresql/plpgsql-programmierung), SQL Server (T-SQL/SSRS/SSAS),
  [PHP](https://dozent.net/seminare/programmieren/php), JS, and other web technologies.
- I'm also building [Inside Filings](https://inside-filings.com/news) — tracking notable insider,
  congressional/White House, and 13F fund moves extracted from SEC filings.
