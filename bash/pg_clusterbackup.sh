#!/usr/bin/env bash
#
# pg_clusterbackup 1.4.0 (bash port)
# Backs up every database of every running PostgreSQL cluster/instance on the host into
# separate files. Don't edit the defaults here — create an ini file instead.
# Full behavior contract: see SPEC.md.
#
# usage sample:
#   ./pg_clusterbackup.sh --ini-write
#   ./pg_clusterbackup.sh -D /backup/folder --email mail@to.me
#
# Errors are handled explicitly (checked exit codes -> fatal()) rather than via `set -e`,
# which is unreliable inside functions/conditionals for a script this size.
set -uo pipefail

VERSION="1.4.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEBUG_LOG=1
DEBUG_TERSE=2
DEBUG_VERBOSE=3

declare -A SETTINGS=()
PGDATA_GLOBS=()
LOG_LINES=()
INI_FILE=""
LOGFILE=""
LOCK_FD=9

# ---------- logging / lock / helpers ----------

log() {
  local txt="$1" level="${2:-0}"
  if (( ${SETTINGS[debug_level]:-1} >= level )); then
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') ${txt}"
    LOG_LINES+=("$line")
    printf '%s\n' "$line" >> "$LOGFILE"
  fi
}

checkdir() {
  local dir="$1"
  [[ -d "$dir" ]] || mkdir -p -m 0700 "$dir"
}

fatal() {
  log "FATAL: $1"
  send_mail "🟥 failed"
  release_lock
  exit 1
}

send_mail() {
  local status="${1:-🟢 OK}"
  [[ -n "${SETTINGS[email]:-}" && ${#LOG_LINES[@]} -gt 0 ]] || return 0
  local subject subject_encoded body
  subject="${status} ${SETTINGS[hostname]} PG Backup Log"
  subject_encoded="=?UTF-8?B?$(printf '%s' "$subject" | base64 -w0)?="
  body="$(printf '%s\r\n' "${LOG_LINES[@]}")"
  printf '%s' "$body" | mail -s "$subject_encoded" -a "From: root@${SETTINGS[hostname]}" "${SETTINGS[email]}" 2>/dev/null || true
}

acquire_lock() {
  local lockfile="${SETTINGS[tempdir]}/pg_clusterbackup.lock"
  exec 9>"$lockfile" || fatal "Cannot open lock file: ${lockfile}"
  flock -n "$LOCK_FD" || fatal "Another backup run seems to be in progress (lock: ${lockfile})"
}

release_lock() {
  flock -u "$LOCK_FD" 2>/dev/null || true
  exec 9>&- 2>/dev/null || true
}

move_file() {
  local from="$1" to="$2"
  mv -f -- "$from" "$to" || fatal "Failed to move ${from} to ${to}"
}

# ---------- ini file ----------

load_ini() {
  local ini="$1"
  [[ -f "$ini" ]] || return 0
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^([A-Za-z0-9_]+)(\[\])?[[:space:]]*=[[:space:]]*\"(.*)\"[[:space:]]*$ ]] || continue
    key="${BASH_REMATCH[1]}"
    val="${BASH_REMATCH[3]}"
    if [[ -n "${BASH_REMATCH[2]}" ]]; then
      [[ "$key" == "pgdata_globs" ]] && PGDATA_GLOBS+=("$val")
    else
      SETTINGS["$key"]="$val"
    fi
  done < "$ini"
}

render_ini() {
  local key g
  for key in "${!SETTINGS[@]}"; do
    printf '%-20s = "%s"\n' "$key" "${SETTINGS[$key]}"
  done
  for g in "${PGDATA_GLOBS[@]}"; do
    printf '%-20s = "%s"\n' "pgdata_globs[]" "$g"
  done
}

write_ini() {
  render_ini > "$INI_FILE"
}

# ---------- cluster / instance discovery ----------
# Emits one tab-separated line per instance: version, cluster, running(1/0/true), port, socketdir
# See SPEC.md "Cluster / instance discovery" for why these two strategies exist.

detect_clusters() {
  if command -v pg_lsclusters >/dev/null 2>&1; then
    lsclusters_tsv
  else
    scan_instances
  fi
}

lsclusters_tsv() {
  command -v jq >/dev/null 2>&1 || fatal "pg_lsclusters found but 'jq' is required to parse its JSON output"
  pg_lsclusters -h -j | jq -r '.[] | [.version, .cluster, (.running|tostring), (.port|tostring), .socketdir] | @tsv'
}

scan_instances() {
  local pattern datadir version_file pidfile running port socketdir line
  for pattern in "${PGDATA_GLOBS[@]}"; do
    for datadir in $pattern; do
      version_file="${datadir}/PG_VERSION"
      [[ -f "$version_file" ]] || continue
      pidfile="${datadir}/postmaster.pid"
      if [[ -f "$pidfile" ]]; then
        running=1
        port="$(sed -n '4p' "$pidfile")"
        line="$(sed -n '5p' "$pidfile")"
        socketdir="${line%%,*}"
      else
        running=0
        port=""
        socketdir=""
      fi
      printf '%s\t%s\t%s\t%s\t%s\n' "$(cat "$version_file")" "main" "$running" "$port" "$socketdir"
    done
  done
}

# ---------- backup ----------

backup_cluster() {
  local version="$1" cluster="$2" port="$3" socketdir="$4" date="$5"
  local path="${SETTINGS[backupdir]}/${date}/${version}/${cluster}"
  log "Starting backup Cluster: ${cluster}"
  checkdir "$path"

  local sql="SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres'"
  local databases db count=0 tempfile
  databases="$(sudo -u postgres psql -h "$socketdir" -p "$port" -U postgres --tuples-only -P format=unaligned -c "$sql")" \
    || fatal "Error listing databases for cluster ${cluster}"

  while IFS= read -r db; do
    [[ -n "$db" ]] || continue
    count=$((count + 1))
    log "Starting backup Database: ${db} "
    tempfile="${SETTINGS[tempdir]}/${db}.cus"
    sudo -u postgres pg_dump -c -h "$socketdir" -p "$port" -F"${SETTINGS[format]}" -f "$tempfile" "$db" \
      || fatal "Error dumping database ${db}"
    move_file "$tempfile" "${path}/${db}.cus"
  done <<< "$databases"

  (( count == 0 )) && log "No databases for backup!"

  log "Starting backup globals" "$DEBUG_LOG"
  local globalsfile="${SETTINGS[tempdir]}/globals.sql"
  sudo -u postgres pg_dumpall -g -h "$socketdir" -p "$port" -f "$globalsfile" \
    || fatal "Error dumping globals for cluster ${cluster}"
  move_file "$globalsfile" "${path}/globals.sql"
}

delete_old_backups() {
  local backups=() d i
  while IFS= read -r d; do backups+=("$d"); done < <(
    find "${SETTINGS[backupdir]}" -maxdepth 1 -mindepth 1 -type d -name '[0-9]*' | sort -r
  )
  for ((i = ${SETTINGS[maxkeep]}; i < ${#backups[@]}; i++)); do
    log "removing ${backups[$i]}" "$DEBUG_TERSE"
    rm -rf -- "${backups[$i]}"
  done
}

backup_all() {
  local date version cluster running_raw port socketdir
  acquire_lock
  date="$(date '+%Y%m%d')"
  checkdir "${SETTINGS[backupdir]}/${date}"
  cd "${SETTINGS[tempdir]}" || fatal "Cannot cd into tempdir ${SETTINGS[tempdir]}"

  while IFS=$'\t' read -r version cluster running_raw port socketdir; do
    [[ -n "$version" ]] || continue
    if [[ "$running_raw" == "1" || "$running_raw" == "true" ]]; then
      backup_cluster "$version" "$cluster" "$port" "$socketdir" "$date"
    else
      log "Cluster: ${cluster} not running!" "$DEBUG_LOG"
    fi
  done < <(detect_clusters)

  delete_old_backups
  release_lock
  send_mail
}

# ---------- config / cli ----------

apply_config() {
  INI_FILE="${CLI_i:-${SCRIPT_DIR}/pg_clusterbackup.ini}"
  load_ini "$INI_FILE"

  SETTINGS[hostname]="${CLI_h:-${SETTINGS[hostname]:-$(hostname)}}"
  SETTINGS[backupdir]="${CLI_D:-${SETTINGS[backupdir]:-/data/backup/postgresql}}"
  SETTINGS[tempdir]="${CLI_T:-${SETTINGS[tempdir]:-/tmp}}"
  SETTINGS[email]="${CLI_email:-${SETTINGS[email]:-monitor@ibou.net}}"
  SETTINGS[maxkeep]="${CLI_n:-${SETTINGS[maxkeep]:-7}}"
  SETTINGS[format]="${CLI_F:-${SETTINGS[format]:-c}}"
  SETTINGS[logdir]="${CLI_L:-${SETTINGS[logdir]:-${SETTINGS[backupdir]}}}"
  SETTINGS[debug_level]="${CLI_d:-${SETTINGS[debug_level]:-1}}"

  if [[ ${#PGDATA_GLOBS[@]} -eq 0 ]]; then
    PGDATA_GLOBS=('/var/lib/pgsql/data' '/var/lib/pgsql/*/data')
  fi
}

parse_args() {
  CLI_i="" CLI_h="" CLI_D="" CLI_T="" CLI_L="" CLI_F="" CLI_d="" CLI_n="" CLI_email=""
  CLI_help=0 CLI_ini_write=0 CLI_ini_show=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -i) CLI_i="${2:-}"; shift 2 ;;
      -h) CLI_h="${2:-}"; shift 2 ;;
      -D) CLI_D="${2:-}"; shift 2 ;;
      -T) CLI_T="${2:-}"; shift 2 ;;
      -L) CLI_L="${2:-}"; shift 2 ;;
      -F) CLI_F="${2:-}"; shift 2 ;;
      -d) CLI_d="${2:-}"; shift 2 ;;
      -n) CLI_n="${2:-}"; shift 2 ;;
      --email) CLI_email="${2:-}"; shift 2 ;;
      --help) CLI_help=1; shift ;;
      --ini-write) CLI_ini_write=1; shift ;;
      --ini-show) CLI_ini_show=1; shift ;;
      *) shift ;;
    esac
  done
}

usage() {
  cat <<TXT
pg_clusterbackup ${VERSION}
----------------------------------------------------------------------------------------------
Backup all PostgreSQL Databases from all running Clusters.

Author: Frank Glück (https://www.dozent.net)
Create pg_clusterbackup.ini with settings to override defaults
You can combine --ini-write with other options to generate an ini file with those values

--help         shows this page
--ini-write    write ini file with current settings [${INI_FILE}]
--ini-show     shows ini file with current settings
--email        recipient for log

-i      path and filename for ini file
-h      hostname (default is system hostname)
-d      debug level 0=off, 1=log (default), 2=terse, 3=verbose

Folders
-D     backup dir
-T     temp dir     [${SETTINGS[tempdir]}]
-L     log dir      [${SETTINGS[logdir]}] (default: backup dir)

Backup settings
-F     dump format (c|t|p)
-n     max number of backup generations to keep
TXT
  exit 0
}

main() {
  umask 0077
  parse_args "$@"
  apply_config

  (( CLI_help )) && usage
  (( CLI_ini_show )) && { render_ini; exit 0; }
  if (( CLI_ini_write )); then
    write_ini
    echo "ini file written to ${INI_FILE}"
    exit 0
  fi

  checkdir "${SETTINGS[logdir]}"
  LOGFILE="${SETTINGS[logdir]}/pg_backupcluster.log"

  backup_all
}

main "$@"
