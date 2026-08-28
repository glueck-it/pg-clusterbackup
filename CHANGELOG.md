# Changelog

## v2.0.0 (PHP)

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

## Unreleased

- Bash/`sh` port (`bash/`) — planned.
- PowerShell port (`powershell/`) — planned, needs its own cluster-discovery design since Windows
  supports multiple parallel PostgreSQL versions/instances but has no `pg_lsclusters` equivalent.
- Parallel `pg_dump` (directory format + `--jobs`, and/or concurrent dumps across databases).
