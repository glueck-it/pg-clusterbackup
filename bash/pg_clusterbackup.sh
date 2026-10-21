#!/usr/bin/env bash
#
# pg_clusterbackup 1.8.0 (bash port)
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

VERSION="1.8.0"
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
    if [[ "${SETTINGS[dry_run]:-0}" == "1" ]]; then
      prefix="[DRY-RUN] "
    fi
    [[ -n "$cluster" ]] && prefix="${prefix}[${cluster}] "
    line="$(date '+%Y-%m-%d %H:%M:%S') ${prefix}${txt}"
    LOG_LINES+=("$line")
    if [[ "${SETTINGS[dry_run]:-0}" != "1" && -n "$LOGFILE" ]]; then
      printf '%s\n' "$line" >> "$LOGFILE"
    fi
  fi
}

checkdir() {
  local dir="$1"
  if [[ "${SETTINGS[dry_run]:-0}" != "1" ]]; then
    [[ -d "$dir" ]] || mkdir -p -m 0700 "$dir"
  fi
}

ping_webhook() {
  local endpoint="${1:-}" msg="${2:-}"
  local url="${SETTINGS[ping_url]:-}"
  [[ -n "$url" ]] || return 0
  url="${url%/}"
  [[ -n "$endpoint" ]] && url="${url}/${endpoint#/}"

  if command -v curl >/dev/null 2>&1; then
    if [[ -n "$msg" ]]; then
      curl -s -m 10 -X POST -H "Content-Type: text/plain" --data-binary "$msg" "$url" >/dev/null 2>&1 || true
    else
      curl -s -m 10 "$url" >/dev/null 2>&1 || true
    fi
  fi
}

format_bytes() {
  local b="$1"
  if (( b < 1024 )); then
    printf '%d B' "$b"
  elif (( b < 1048576 )); then
    printf '%.2f KB' "$(( b * 100 / 1024 ))e-2" 2>/dev/null || printf '%d KB' "$(( b / 1024 ))"
  elif (( b < 1073741824 )); then
    printf '%.2f MB' "$(( b * 100 / 1048576 ))e-2" 2>/dev/null || printf '%d MB' "$(( b / 1048576 ))"
  else
    printf '%.2f GB' "$(( b * 100 / 1073741824 ))e-2" 2>/dev/null || printf '%d GB' "$(( b / 1073741824 ))"
  fi
}

check_disk_space() {
  local min_gb="${SETTINGS[min_free_space_gb]:-0}"
  (( min_gb > 0 )) || return 0

  local dir available_kb available_gb
  for dir in "${SETTINGS[backupdir]}" "${SETTINGS[tempdir]}"; do
    local check_path="$dir"
    while [[ ! -d "$check_path" && "$check_path" != "/" && "$check_path" != "." ]]; do
      check_path="$(dirname "$check_path")"
    done
    available_kb="$(df -k "$check_path" 2>/dev/null | awk 'NR==2 {print $4}')"
    if [[ -n "$available_kb" ]]; then
      available_gb=$(( available_kb / 1048576 ))
      log "Checking free disk space on ${dir} (${check_path}): ${available_gb} GB" "$DEBUG_VERBOSE"
      if (( available_gb < min_gb )); then
        fatal "Insufficient disk space on ${dir} (${check_path}): ${available_gb} GB free, required: ${min_gb} GB"
      fi
    fi
  done
}

fatal() {
  log "FATAL: $1"
  ping_webhook "fail" "$1"
  send_mail "🟥 failed"
  release_lock
  exit 1
}

send_mail() {
  local status="${1:-🟢 OK}"
  if [[ "${SETTINGS[dry_run]:-0}" == "1" ]]; then
    status="🟡 DRY-RUN"
  fi
  [[ -n "${SETTINGS[email]:-}" && ${#LOG_LINES[@]} -gt 0 ]] || return 0
  local subject subject_encoded body
  subject="${status} ${SETTINGS[hostname]} PG Backup Log"
  subject_encoded="=?UTF-8?B?$(printf '%s' "$subject" | base64 -w0)?="
  body="$(printf '%s\r\n' "${LOG_LINES[@]}")"
  printf '%s' "$body" | mail -s "$subject_encoded" -a "From: root@${SETTINGS[hostname]}" "${SETTINGS[email]}" 2>/dev/null || true
}

acquire_lock() {
  [[ "${SETTINGS[dry_run]:-0}" == "1" ]] && return 0
  local lockfile="${SETTINGS[tempdir]}/pg_clusterbackup.lock"
  exec 9>"$lockfile" || fatal "Cannot open lock file: ${lockfile}"
  flock -n "$LOCK_FD" || fatal "Another backup run seems to be in progress (lock: ${lockfile})"
}

release_lock() {
  flock -u "$LOCK_FD" 2>/dev/null || true
  exec 9>&- 2>/dev/null || true
}

move_file() {
  [[ "${SETTINGS[dry_run]:-0}" == "1" ]] && return 0
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
    [[ "$key" == "dry_run" ]] && continue
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
    find "${SETTINGS[backupdir]}" -maxdepth 3 -mindepth 3 -type d -path "*/${version}/${cluster}" 2>/dev/null | sort -r
  )
  for ((i = ${SETTINGS[maxkeep]}; i < ${#backups[@]}; i++)); do
    if [[ "${SETTINGS[dry_run]:-0}" == "1" ]]; then
      log "would remove old backup directory ${backups[$i]}" "$DEBUG_TERSE" "$cluster"
    else
      log "removing ${backups[$i]}" "$DEBUG_TERSE" "$cluster"
      rm -rf -- "${backups[$i]}"
      parent="$(dirname "${backups[$i]}")"
      rmdir "$parent" 2>/dev/null || true
      grandparent="$(dirname "$parent")"
      rmdir "$grandparent" 2>/dev/null || true
    fi
  done
}

delete_empty_dates() {
  [[ "${SETTINGS[dry_run]:-0}" == "1" ]] && return 0
  local d
  while IFS= read -r d; do
    rmdir "$d" 2>/dev/null || true
  done < <(find "${SETTINGS[backupdir]}" -maxdepth 1 -mindepth 1 -type d -name '[0-9]*' 2>/dev/null)
}

filter_databases() {
  local -n in_dbs=$1
  local -n out_dbs=$2
  local cluster="$3"
  local item db size
  local inc_str="${SETTINGS[include_databases]:-}"
  local exc_str="${SETTINGS[exclude_databases]:-}"
  local IFS=','
  local -a inc_patterns=() exc_patterns=()
  read -ra inc_patterns <<< "$inc_str"
  read -ra exc_patterns <<< "$exc_str"

  for item in "${in_dbs[@]}"; do
    db="${item%%|*}"
    size="${item##*|}"
    [[ -n "$db" ]] || continue

    if [[ ${#inc_patterns[@]} -gt 0 && -n "${inc_patterns[0]:-}" ]]; then
      local matched_inc=0 pat
      for pat in "${inc_patterns[@]}"; do
        pat="$(echo "$pat" | xargs)"
        if [[ "$db" == $pat ]]; then matched_inc=1; break; fi
      done
      if (( ! matched_inc )); then
        log "Skipping database ${db} (not matching include_databases)" "$DEBUG_VERBOSE" "$cluster"
        continue
      fi
    fi

    if [[ ${#exc_patterns[@]} -gt 0 && -n "${exc_patterns[0]:-}" ]]; then
      local matched_exc=0 pat
      for pat in "${exc_patterns[@]}"; do
        pat="$(echo "$pat" | xargs)"
        if [[ "$db" == $pat ]]; then matched_exc=1; break; fi
      done
      if (( matched_exc )); then
        log "Skipping database ${db} (matching exclude_databases)" "$DEBUG_LOG" "$cluster"
        continue
      fi
    fi

    out_dbs+=("$item")
  done
}

write_manifest() {
  local path="$1" version="$2" cluster="$3" date="$4" start_time="$5" end_time="$6" duration="$7" globals_size="$8"
  shift 8
  local -a db_metrics=("$@")
  local manifest_file="${path}/manifest.json"

  if [[ "${SETTINGS[dry_run]:-0}" == "1" ]]; then
    log "would write ${manifest_file}" "$DEBUG_LOG" "$cluster"
    return 0
  fi

  {
    echo "{"
    echo "  \"version\": \"${VERSION}\","
    echo "  \"cluster\": \"${cluster}\","
    echo "  \"pg_version\": \"${version}\","
    echo "  \"date\": \"${date}\","
    echo "  \"hostname\": \"${SETTINGS[hostname]}\","
    echo "  \"start_time\": \"${start_time}\","
    echo "  \"end_time\": \"${end_time}\","
    echo "  \"duration_seconds\": ${duration},"
    echo "  \"status\": \"ok\","
    echo "  \"databases\": {"
    local i=0 n=${#db_metrics[@]}
    for entry in "${db_metrics[@]}"; do
      # entry format: db:raw_size:backup_size:status
      local d_name="$(cut -d: -f1 <<< "$entry")"
      local d_raw="$(cut -d: -f2 <<< "$entry")"
      local d_bak="$(cut -d: -f3 <<< "$entry")"
      local d_stat="$(cut -d: -f4 <<< "$entry")"
      i=$((i + 1))
      local comma=","
      (( i == n )) && comma=""
      echo "    \"${d_name}\": {"
      echo "      \"raw_size_bytes\": ${d_raw},"
      echo "      \"backup_file\": \"${d_name}.cus\","
      echo "      \"backup_size_bytes\": ${d_bak},"
      echo "      \"status\": \"${d_stat}\""
      echo "    }${comma}"
    done
    echo "  },"
    echo "  \"globals\": {"
    echo "    \"file\": \"globals.sql\","
    echo "    \"size_bytes\": ${globals_size}"
    echo "  }"
    echo "}"
  } > "$manifest_file"
}

backup_cluster() {
  local version="$1" cluster="$2" port="$3" socketdir="$4" date="$5"
  local path="${SETTINGS[backupdir]}/${date}/${version}/${cluster}"
  local start_time start_epoch end_time end_epoch duration
  start_time="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  start_epoch="$(date '+%s')"

  log "Starting backup Cluster: ${cluster}" 0 "$cluster"
  checkdir "$path"
  local clustertemp="${SETTINGS[tempdir]}/${version}_${cluster}"
  checkdir "$clustertemp"

  local sql="SELECT datname || '|' || pg_database_size(datname) FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres'"
  local raw_databases db
  raw_databases="$(sudo -u postgres psql -h "$socketdir" -p "$port" -U postgres --tuples-only -P format=unaligned -c "$sql")" \
    || fatal "Error listing databases for cluster ${cluster}"

  local -a raw_array=() filtered_dbs=()
  while IFS= read -r db; do
    [[ -n "$db" ]] && raw_array+=("$db")
  done <<< "$raw_databases"

  filter_databases raw_array filtered_dbs "$cluster"

  local -a db_manifest_entries=()
  if [[ ${#filtered_dbs[@]} -eq 0 ]]; then
    log 'No databases for backup!' 0 "$cluster"
  else
    backup_databases "$path" "$socketdir" "$port" "$cluster" "$clustertemp" db_manifest_entries "${filtered_dbs[@]}"
  fi

  log "Starting backup globals" "$DEBUG_LOG" "$cluster"
  local globalsfile="${clustertemp}/globals.sql"
  local globals_size=0

  if [[ "${SETTINGS[dry_run]:-0}" == "1" ]]; then
    log "would dump globals to ${path}/globals.sql" "$DEBUG_LOG" "$cluster"
  else
    sudo -u postgres pg_dumpall -g -h "$socketdir" -p "$port" -f "$globalsfile" \
      || fatal "Error dumping globals for cluster ${cluster}"
    move_file "$globalsfile" "${path}/globals.sql"
    [[ -f "${path}/globals.sql" ]] && globals_size="$(stat -c%s "${path}/globals.sql" 2>/dev/null || wc -c < "${path}/globals.sql" | tr -d ' ')"
  fi

  end_time="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  end_epoch="$(date '+%s')"
  duration=$(( end_epoch - start_epoch ))

  write_manifest "$path" "$version" "$cluster" "$date" "$start_time" "$end_time" "$duration" "$globals_size" "${db_manifest_entries[@]}"

  delete_cluster_backups "$version" "$cluster"
  if [[ "${SETTINGS[dry_run]:-0}" != "1" ]]; then
    rmdir "$clustertemp" 2>/dev/null || true
  fi
}

backup_databases() {
  local path="$1" socketdir="$2" port="$3" cluster="$4" clustertemp="$5"
  local -n out_manifest=$6
  shift 6
  local -a queue=("$@")

  if [[ "${SETTINGS[dry_run]:-0}" == "1" ]]; then
    for item in "${queue[@]}"; do
      local db="${item%%|*}"
      local raw="${item##*|}"
      log "would backup Database: ${db} (raw size: $(format_bytes "$raw")) to ${path}/${db}.cus" 0 "$cluster"
      out_manifest+=("${db}:${raw}:0:dry-run")
    done
    return 0
  fi

  local jobs="${SETTINGS[parallel_jobs]:-1}"
  local -A pid_db=() pid_tmp=() pid_raw=()
  local active=0 failed="" item db raw tempfile pid rc
  local -a compress_args=()
  if [[ -n "${SETTINGS[compression]:-}" ]]; then
    if [[ "${SETTINGS[compression]}" =~ ^[0-9]+$ ]]; then
      compress_args=("-Z" "${SETTINGS[compression]}")
    else
      compress_args=("--compress=${SETTINGS[compression]}")
    fi
  fi

  while [[ ( ${#queue[@]} -gt 0 && -z "$failed" ) || $active -gt 0 ]]; do
    while [[ ${#queue[@]} -gt 0 && -z "$failed" && $active -lt $jobs ]]; do
      item="${queue[0]}"
      queue=("${queue[@]:1}")
      db="${item%%|*}"
      raw="${item##*|}"
      log "Starting backup Database: ${db} (raw size: $(format_bytes "$raw"))" 0 "$cluster"
      tempfile="${clustertemp}/${db}.cus"
      sudo -u postgres pg_dump -c -h "$socketdir" -p "$port" "${compress_args[@]}" -F"${SETTINGS[format]}" -f "$tempfile" "$db" &
      pid=$!
      pid_db[$pid]="$db"
      pid_tmp[$pid]="$tempfile"
      pid_raw[$pid]="$raw"
      active=$((active + 1))
    done

    if [[ $active -gt 0 ]]; then
      wait -n 2>/dev/null || true
      for pid in "${!pid_db[@]}"; do
        if ! kill -0 "$pid" 2>/dev/null; then
          wait "$pid"; rc=$?
          db="${pid_db[$pid]}"; tempfile="${pid_tmp[$pid]}"; raw="${pid_raw[$pid]}"
          unset 'pid_db[$pid]' 'pid_tmp[$pid]' 'pid_raw[$pid]'
          active=$((active - 1))
          if [[ $rc -ne 0 ]]; then
            failed="Error dumping database ${db}"
          else
            local final_file="${path}/${db}.cus"
            move_file "$tempfile" "$final_file"
            local b_size=0
            [[ -f "$final_file" ]] && b_size="$(stat -c%s "$final_file" 2>/dev/null || wc -c < "$final_file" | tr -d ' ')"
            out_manifest+=("${db}:${raw}:${b_size}:ok")
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
  ping_webhook "start"

  if [[ "${SETTINGS[dry_run]:-0}" == "1" ]]; then
    log 'Running in DRY-RUN mode — no actual dumps or deletions will be performed.'
  fi

  check_disk_space

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
  if (( cjobs <= 1 || ${#clusters_to_run[@]} <= 1 || "${SETTINGS[dry_run]:-0}" == "1" )); then
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
  ping_webhook ""
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
  SETTINGS[compression]="${CLI_Z:-${SETTINGS[compression]:-}}"
  SETTINGS[exclude_databases]="${CLI_exclude:-${SETTINGS[exclude_databases]:-}}"
  SETTINGS[include_databases]="${CLI_include:-${SETTINGS[include_databases]:-}}"
  SETTINGS[ping_url]="${CLI_ping_url:-${SETTINGS[ping_url]:-}}"
  SETTINGS[min_free_space_gb]="${SETTINGS[min_free_space_gb]:-0}"
  SETTINGS[dry_run]="${CLI_dry_run:-${SETTINGS[dry_run]:-0}}"

  if [[ ${#PGDATA_GLOBS[@]} -eq 0 ]]; then
    PGDATA_GLOBS=('/var/lib/pgsql/data' '/var/lib/pgsql/*/data')
  fi
}

parse_args() {
  CLI_i="" CLI_h="" CLI_D="" CLI_T="" CLI_L="" CLI_F="" CLI_d="" CLI_n="" CLI_j="" CLI_C="" CLI_Z=""
  CLI_exclude="" CLI_include="" CLI_ping_url="" CLI_dry_run=0 CLI_email=""
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
      -Z) CLI_Z="${2:-}"; shift 2 ;;
      --compress=*) CLI_Z="${1#*=}"; shift ;;
      --compress) CLI_Z="${2:-}"; shift 2 ;;
      -N|--dry-run) CLI_dry_run=1; shift ;;
      --exclude=*) CLI_exclude="${1#*=}"; shift ;;
      --exclude) CLI_exclude="${2:-}"; shift 2 ;;
      --include=*) CLI_include="${1#*=}"; shift ;;
      --include) CLI_include="${2:-}"; shift 2 ;;
      --ping-url=*) CLI_ping_url="${1#*=}"; shift ;;
      --ping-url) CLI_ping_url="${2:-}"; shift 2 ;;
      --email=*) CLI_email="${1#*=}"; shift ;;
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
--exclude      comma-separated glob patterns of databases to exclude
--include      comma-separated glob patterns of databases to include
--ping-url     healthcheck ping URL (start/fail/ok)
--compress, -Z compression spec/level for pg_dump (e.g. 6 or zstd:3)
--dry-run, -N  simulate run without dumping or deleting files

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
-Z     compression level/spec for pg_dump
-N     dry-run simulation mode
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
