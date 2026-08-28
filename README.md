# pg-clusterbackup

Backs up **every database of every running PostgreSQL cluster** on a Debian/Ubuntu host in one
cron job — no manual per-cluster, per-database configuration needed. Detects clusters via
`pg_lsclusters`, dumps each database individually (so single databases can be restored without
touching the rest), dumps globals separately, rotates old generations, and mails you the result.

Available today as a **PHP** implementation. A **Bash** port is planned next (see
[CHANGELOG.md](CHANGELOG.md)); a **PowerShell** port is planned for later, once multi-instance
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

- Debian/Ubuntu with `postgresql-common` (provides `pg_lsclusters`)
- PHP CLI (for the PHP implementation)
- Passwordless `sudo -u postgres` for the user running this script (typically root via cron)
- Enough free space on the backup destination; `tempdir` and `backupdir` may be on different
  filesystems, the script handles the fallback

## Install

Just want the script, no repo clutter? Download the single file, pinned to a release tag:

```sh
curl -O https://raw.githubusercontent.com/glueck-it/pg-clusterbackup/v1.2.0/php/pg_clusterbackup.php
chmod +x pg_clusterbackup.php
```

Or clone the full repo (includes examples, SPEC.md, CHANGELOG.md):

```sh
git clone https://github.com/glueck-it/pg-clusterbackup.git
cd pg-clusterbackup/php
chmod +x pg_clusterbackup.php
```

## Quick start

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
- All values passed to shell commands are escaped
- Temp-to-backup moves work across filesystem boundaries
- Restrictive `umask` while dumping, so temp files aren't briefly world-readable

## Roadmap

- [ ] Bash/`sh` port
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
