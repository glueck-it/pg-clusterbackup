# pg-clusterbackup

Backs up **every database of every running PostgreSQL cluster/instance** on a Debian/Ubuntu or
RHEL-family (CentOS/Rocky/Alma) host in one cron job — no manual per-cluster, per-database
configuration needed. Detects clusters via `pg_lsclusters` where available, or by scanning data
directories directly otherwise; dumps each database individually (so single databases can be
restored without touching the rest), dumps globals separately, rotates old generations, and mails
you the result.

Available as **PHP** (`php/`) and **Bash** (`bash/`) implementations, kept behaviorally identical
per [SPEC.md](SPEC.md). A **PowerShell** port is planned for later, once multi-instance
PostgreSQL-on-Windows discovery is designed.

Maintained by [Frank Glück](https://www.dozent.net) — PostgreSQL/Linux consulting and
[PHP training](https://dozent.net/seminare/programmieren/php).

## Why

Most PostgreSQL backup scripts assume a single cluster and a fixed list of databases. On hosts
running several PostgreSQL major versions / clusters side by side (a common Debian/Ubuntu setup
via `postgresql-common`), that means hand-maintaining the database list per cluster. This script
instead asks the OS what's actually running and backs up all of it — new databases and new
clusters are picked up automatically on the next run.

## Requirements

- Debian/Ubuntu with `postgresql-common` (provides `pg_lsclusters`), **or** RHEL/CentOS/Rocky/Alma
  with PostgreSQL installed from the distro package or a PGDG `postgresqlNN-server` package
- PHP CLI (for `php/`), or Bash 4+ with `flock`, `mail`/`mailx`, and — only when `pg_lsclusters`
  is present — `jq` to parse its JSON output (for `bash/`)
- Passwordless `sudo -u postgres` for the user running this script (typically root via cron)
- Enough free space on the backup destination; `tempdir` and `backupdir` may be on different
  filesystems, the script handles the fallback

On RHEL-family hosts without `pg_lsclusters`, data directories are found via the `pgdata_globs`
setting (default: `/var/lib/pgsql/data`, `/var/lib/pgsql/*/data`) — override it in the ini file if
your installation uses a non-standard location. See [SPEC.md](SPEC.md) for how discovery works.

## Install

Just want the script, no repo clutter? Download the single file, pinned to a release tag —
pick PHP or Bash:

```sh
curl -O https://raw.githubusercontent.com/glueck-it/pg-clusterbackup/v1.4.0/php/pg_clusterbackup.php
chmod +x pg_clusterbackup.php
```

```sh
curl -O https://raw.githubusercontent.com/glueck-it/pg-clusterbackup/v1.4.0/bash/pg_clusterbackup.sh
chmod +x pg_clusterbackup.sh
```

Or clone the full repo (includes examples, SPEC.md, CHANGELOG.md):

```sh
git clone https://github.com/glueck-it/pg-clusterbackup.git
cd pg-clusterbackup/php    # or: cd pg-clusterbackup/bash
chmod +x pg_clusterbackup.*
```

## Quick start

Both implementations take the same options (see SPEC.md) — examples below use the PHP one,
swap in `pg_clusterbackup.sh` for the Bash port.

```sh
# see all options
./pg_clusterbackup.php --help

# write your settings to an ini file once
./pg_clusterbackup.php -D /data/backup/postgresql --email you@example.com -n 14 --ini-write

# from then on, just run it (e.g. from cron) — it reads the ini file
./pg_clusterbackup.php
```

Example crontab entry (daily at 02:30):

```
30 2 * * * root /opt/pg-clusterbackup/pg_clusterbackup.php
```

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
|       | `--email`     | mail recipient for the run log                        | none                         |
|       | `--ini-write` | persist current settings (incl. any flags above) to the ini file | |
|       | `--ini-show`  | print current effective settings in ini format        |                              |
|       | `--help`      | show usage                                            |                              |

Full behavior contract for all language ports: [SPEC.md](SPEC.md).

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

- Exclusive lock file — an overlapping cron run refuses to start instead of corrupting temp files
- Old generations are deleted only *after* a successful run, never before
- No raw values are interpolated into a shell string (escaped in PHP, passed as separate argv
  entries in Bash) — both avoid the classic shell-injection footgun
- Temp-to-backup moves work across filesystem boundaries
- Restrictive `umask` while dumping, so temp files aren't briefly world-readable

## Roadmap

- [ ] Parallel `pg_dump` (directory format + `--jobs`, and/or concurrent per-database dumps)
- [ ] PowerShell port for Windows (multi-instance discovery TBD)

## License

MIT — see [LICENSE](LICENSE).

## About the author

Built and maintained by **Frank Glück** ([Glück IT](https://www.dozent.net)).

- Need help with PostgreSQL, Linux ops, or backup strategy? [Get in touch](https://www.dozent.net).
- Want to actually get good at PHP? I run [PHP programming seminars](https://dozent.net/seminare/programmieren/php)
  (German), from language basics to OOP.
- I'm also building [Inside Filings](https://inside-filings.com/news) — tracking notable insider,
  congressional/White House, and 13F fund moves extracted from SEC filings.
