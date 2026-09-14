#!/usr/bin/env bash
#
# pg_clusterbackup 1.6.0 (bash port)
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
# Requires bash 4.3+ (associative arrays, and `wait -n` for parallel dumps).
set -uo pipefail

VERSION="1.7.0"
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
  local txt="$1" level="${2:-0}" cluster="${3:-}"
  if (( ${SETTINGS[debug_level]:-1} >= level )); then
    local prefix="" line
    [[ -n "$cluster" ]] && prefix="[${cluster}] "
    line="$(date '+%Y-%m-%d %H:%M:%S') ${prefix}${txt}"
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

delete_cluster_backups() {
  local version="$1" cluster="$2"
  local backups=() d i parent grandparent
  while IFS= read -r d; do backups+=("$d"); done < <(
    find "${SETTINGS[backupdir]}" -maxdepth 3 -mindepth 3 -type d -path "*/${version}/${cluster}" | sort -r
  )
  for ((i = ${SETTINGS[maxkeep]}; i < ${#backups[@]}; i++)); do
    log "removing ${backups[$i]}" "$DEBUG_TERSE" "$cluster"
    rm -rf -- "${backups[$i]}"
    parent="$(dirname "${backups[$i]}")" # version dir
    rmdir "$parent" 2>/dev/null || true
    grandparent="$(dirname "$parent")" # date dir
    rmdir "$grandparent" 2>/dev/null || true
  done
}

delete_empty_dates() {
  local d
  while IFS= read -r d; do
    rmdir "$d" 2>/dev/null || true
  done < <(find "${SETTINGS[backupdir]}" -maxdepth 1 -mindepth 1 -type d -name '[0-9]*')
}

backup_cluster() {
  local version="$1" cluster="$2" port="$3" socketdir="$4" date="$5"
  local path="${SETTINGS[backupdir]}/${date}/${version}/${cluster}"
  log "Starting backup Cluster: ${cluster}" 0 "$cluster"
  checkdir "$path"
  local clustertemp="${SETTINGS[tempdir]}/${version}_${cluster}"
  checkdir "$clustertemp"

  local sql="SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres'"
  local databases db
  databases="$(sudo -u postgres psql -h "$socketdir" -p "$port" -U postgres --tuples-only -P format=unaligned -c "$sql")" \
    || fatal "Error listing databases for cluster ${cluster}"

  local -a dbarray=()
  while IFS= read -r db; do
    [[ -n "$db" ]] && dbarray+=("$db")
  done <<< "$databases"

  if [[ ${#dbarray[@]} -eq 0 ]]; then
    log 'No databases for backup!' 0 "$cluster"
  else
    backup_databases "$path" "$socketdir" "$port" "$cluster" "$clustertemp" "${dbarray[@]}"
  fi

  log "Starting backup globals" "$DEBUG_LOG" "$cluster"
  local globalsfile="${clustertemp}/globals.sql"
  sudo -u postgres pg_dumpall -g -h "$socketdir" -p "$port" -f "$globalsfile" \
    || fatal "Error dumping globals for cluster ${cluster}"
  move_file "$globalsfile" "${path}/globals.sql"
  delete_cluster_backups "$version" "$cluster"
  rmdir "$clustertemp" 2>/dev/null || true
}

# Dumps up to `parallel_jobs` databases concurrently (default 1 = unchanged sequential
# behavior). Not pg_dump's own -j/--jobs: that requires the directory format and would break
# the single-file-per-database restore story. See SPEC.md "Parallel database dumps".
backup_databases() {
  local path="$1" socketdir="$2" port="$3" cluster="$4" clustertemp="$5"
  shift 5
  local -a queue=("$@")
  local jobs="${SETTINGS[parallel_jobs]:-1}"
  local -A pid_db=() pid_tmp=()
  local active=0 failed="" db tempfile pid rc

  while [[ ( ${#queue[@]} -gt 0 && -z "$failed" ) || $active -gt 0 ]]; do
    while [[ ${#queue[@]} -gt 0 && -z "$failed" && $active -lt $jobs ]]; do
      db="${queue[0]}"
      queue=("${queue[@]:1}")
      log "Starting backup Database: ${db} " 0 "$cluster"
      tempfile="${clustertemp}/${db}.cus"
      sudo -u postgres pg_dump -c -h "$socketdir" -p "$port" -F"${SETTINGS[format]}" -f "$tempfile" "$db" &
      pid=$!
      pid_db[$pid]="$db"
      pid_tmp[$pid]="$tempfile"
      active=$((active + 1))
    done

    if [[ $active -gt 0 ]]; then
      wait -n 2>/dev/null || true
      for pid in "${!pid_db[@]}"; do
        if ! kill -0 "$pid" 2>/dev/null; then
          wait "$pid"; rc=$?
          db="${pid_db[$pid]}"; tempfile="${pid_tmp[$pid]}"
          unset 'pid_db[$pid]' 'pid_tmp[$pid]'
          active=$((active - 1))
          if [[ $rc -ne 0 ]]; then
            failed="Error dumping database ${db}"
          else
            move_file "$tempfile" "${path}/${db}.cus"
          fi
        fi
      done
    fi
  done

  [[ -n "$failed" ]] && fatal "$failed"
}

backup_all() {
  local date version cluster running_raw port socketdir
  acquire_lock
  date="$(date '+%Y%m%d')"
  checkdir "${SETTINGS[backupdir]}/${date}"
  cd "${SETTINGS[tempdir]}" || fatal "Cannot cd into tempdir ${SETTINGS[tempdir]}"

  local -a clusters_to_run=()
  while IFS=$'\t' read -r version cluster running_raw port socketdir; do
    [[ -n "$version" ]] || continue
    if [[ "$running_raw" == "1" || "$running_raw" == "true" ]]; then
      clusters_to_run+=("${version}"$'\t'"${cluster}"$'\t'"${port}"$'\t'"${socketdir}")
    else
      log "Cluster: ${cluster} not running!" "$DEBUG_LOG"
    fi
  done < <(detect_clusters)

  local cjobs="${SETTINGS[parallel_clusters]:-1}"
  if (( cjobs <= 1 || ${#clusters_to_run[@]} <= 1 )); then
    local item
    for item in "${clusters_to_run[@]}"; do
      IFS=$'\t' read -r version cluster port socketdir <<< "$item"
      backup_cluster "$version" "$cluster" "$port" "$socketdir" "$date"
    done
  else
    local -a cqueue=("${clusters_to_run[@]}")
    local -A c_pids=()
    local cactive=0 cfailed="" cpid crc citem

    while [[ ( ${#cqueue[@]} -gt 0 && -z "$cfailed" ) || $cactive -gt 0 ]]; do
      while [[ ${#cqueue[@]} -gt 0 && -z "$cfailed" && $cactive -lt $cjobs ]]; do
        citem="${cqueue[0]}"
        cqueue=("${cqueue[@]:1}")
        IFS=$'\t' read -r version cluster port socketdir <<< "$citem"
        backup_cluster "$version" "$cluster" "$port" "$socketdir" "$date" &
        cpid=$!
        c_pids[$cpid]="$cluster"
        cactive=$((cactive + 1))
      done

      if [[ $cactive -gt 0 ]]; then
        wait -n 2>/dev/null || true
        for cpid in "${!c_pids[@]}"; do
          if ! kill -0 "$cpid" 2>/dev/null; then
            wait "$cpid"; crc=$?
            cluster="${c_pids[$cpid]}"
            unset 'c_pids[$cpid]'
            cactive=$((cactive - 1))
            if [[ $crc -ne 0 ]]; then
              cfailed="Error backing up cluster ${cluster}"
            fi
          fi
        done
      fi
    done

    [[ -n "$cfailed" ]] && fatal "$cfailed"
  fi

  delete_empty_dates
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
  SETTINGS[parallel_jobs]="${CLI_j:-${SETTINGS[parallel_jobs]:-1}}"
  SETTINGS[parallel_clusters]="${CLI_C:-${SETTINGS[parallel_clusters]:-1}}"

  if [[ ${#PGDATA_GLOBS[@]} -eq 0 ]]; then
    PGDATA_GLOBS=('/var/lib/pgsql/data' '/var/lib/pgsql/*/data')
  fi
}

parse_args() {
  CLI_i="" CLI_h="" CLI_D="" CLI_T="" CLI_L="" CLI_F="" CLI_d="" CLI_n="" CLI_j="" CLI_C="" CLI_email=""
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
      -j) CLI_j="${2:-}"; shift 2 ;;
      -C) CLI_C="${2:-}"; shift 2 ;;
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

Author: Frank Glück (https://dozent.net)
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
-j     max concurrent pg_dump processes per cluster (default 1)
-C     max concurrent cluster backups (default 1)
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
