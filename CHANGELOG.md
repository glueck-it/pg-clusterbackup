# Changelog

## 1.5.0

- Added the PowerShell port (`powershell/pg_clusterbackup.ps1`). Windows has no `pg_lsclusters`
  equivalent, so discovery is a new, dedicated strategy: enumerate Windows services running
  `pg_ctl.exe` via `Get-CimInstance Win32_Service`, read the data directory straight from the
  service's own `-D` command-line argument (not guessed from a path convention), with a
  `pgdata_globs`-style glob scan as fallback for non-service/portable installs. Deliberately not
  a port scanner or blind directory scan — see SPEC.md "Cluster / instance discovery" strategy 3.
- PowerShell deviation (documented in SPEC.md): `-D`/`-d` can't coexist as PowerShell only
  parameter names/aliases are case-insensitive, so debug level is `-DebugLevel`/`-dl` instead of
  `-d`; long options use full names (`-Help`, `-IniWrite`, ...) rather than `--double-dash`.
- No Windows local MTA, so mail sending requires an `smtp_server` ini setting; skipped (logged,
  not fatal) when unset.
- No `sudo -u postgres` equivalent on Windows — requires `pg_hba.conf`/credentials that let the
  running user connect as the `postgres` role via `localhost`.
- PHP/Bash: no functional changes, version bumped to 1.5.0 to match the project-wide release.
- Verified: parser/AST check, `-Help`, `-IniWrite`/`-IniShow` roundtrip, and both discovery
  strategies (service-based and glob fallback, running/not-running) against simulated data
  directories and a mocked `Win32_Service` object.

## 1.4.0

- Added the Bash port (`bash/pg_clusterbackup.sh`), matching SPEC.md: same CLI options, ini
  format (incl. `pgdata_globs[]`), lock file, both discovery strategies, delete-after-success
  rotation, and cross-filesystem-safe moves (`mv` already handles this natively on Linux).
  Arguments are passed to commands as separate argv entries rather than interpolated into a
  shell string, so there's no `escapeshellarg`-equivalent needed for injection-safety.
- PHP: no functional changes, version bumped to 1.4.0 to match the project-wide release (see
  SPEC.md "Versioning" — the project shares one version number across implementations).

## 1.3.0 (PHP)

- Added RHEL/CentOS/Rocky/Alma support: when `pg_lsclusters` isn't installed, falls back to
  scanning configurable `pgdata_globs` and reading `postmaster.pid` directly for port/socket dir.
  See [SPEC.md](SPEC.md) "Cluster / instance discovery" for the design.
- Fixed `ini_get_settings()` writing array-type settings under a `[section]` header, which caused
  every setting written *after* it to be silently absorbed into that array on the next
  `--ini-write`/read. Surfaced by adding the first real array setting (`pgdata_globs`).

## 1.2.0 (PHP)

Initial public release. Rewrite of a long-standing internal script, hardened for release:

- Fixed `load_ini()` referencing an undefined variable, which crashed with a fatal error on any
  run after the first `--ini-write`.
- Fixed CLI argument parsing — `-D`, `-T`, `-L`, `-F`, `-h`, `-d`, `-n`, `--email` were previously
  silently ignored.
- Fixed `mkdir()` using a decimal instead of octal permission mode.
- Old backup generations are now only deleted after a successful run, not before.
- All values interpolated into shell commands are now shell-escaped.
- Moving dumps from the temp directory to the backup directory now falls back to copy+remove when
  they're on different filesystems, and errors are no longer silently swallowed.
- Fixed a fatal error in the failure-mail path when the backup object itself failed to construct.
- Added a lock file so overlapping cron runs can no longer corrupt each other's temp files.
- Restricted `umask` so temporary dump files aren't briefly world-readable.
- Fixed the executable bit not being tracked correctly by git on Windows.
- `logdir` is now created before first use, and the example config points it at its own
  subfolder instead of the backup root.

## Unreleased

- Parallel `pg_dump` (directory format + `--jobs`, and/or concurrent dumps across databases).
