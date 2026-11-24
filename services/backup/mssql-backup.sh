#!/bin/bash
# SQL Server backups to a Railway Bucket (S3), with retention. Runs once and exits:
# the "SQL Server Backup" service is a Railway cron job.
#
#   mssql-backup backup    every user database -> Bucket, verify, prune (default)
#   mssql-backup list      list the backup runs stored in the Bucket
#   mssql-backup restore   restore RESTORE_DATABASE from RESTORE_RUN into RESTORE_TARGET
#
# SQL Server writes its native .bak (BACKUP DATABASE ... WITH COPY_ONLY, CHECKSUM,
# then RESTORE VERIFYONLY) next to its data and the helper in the SQL Server
# container streams it here over the private network; this job compresses it with
# zstd and uploads it with rclone without touching local disk. Express edition
# has no backup compression and no backup-to-S3, which is why it is done this way.
#
# Bucket layout (one folder per run, UTC timestamp):
#   {BACKUP_PREFIX}/20261124T034500Z/{database}.bak.zst
#   {BACKUP_PREFIX}/20261124T034500Z/MANIFEST.txt    written last; a run without it is incomplete
set -Eeuo pipefail

PREFIX="${BACKUP_PREFIX:-mssql}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
KEEP_MIN="${BACKUP_KEEP_MIN:-3}"
ZSTD_LEVEL="${BACKUP_ZSTD_LEVEL:-3}"
DATABASES="${BACKUP_DATABASES:-}"
WAIT_SECONDS="${BACKUP_WAIT_SECONDS:-600}"
INCOMPLETE_GRACE_DAYS=2
RUN_RE='^[0-9]{8}T[0-9]{6}Z$'
NAME_RE='^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'
REMOTE=""
HELPER=""
WORK="${TMPDIR:-/tmp}/mssql-backup.$$"

log() { printf '[mssql-backup] %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }
cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT

require_uint() {
  [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -ge "$3" ] || die "$1 must be a whole number >= $3 (got '$2')"
}

validate_settings() {
  require_uint BACKUP_RETENTION_DAYS "${RETENTION_DAYS}" 1
  require_uint BACKUP_KEEP_MIN "${KEEP_MIN}" 1
  require_uint BACKUP_WAIT_SECONDS "${WAIT_SECONDS}" 0
  require_uint BACKUP_ZSTD_LEVEL "${ZSTD_LEVEL}" 1
  [ "${ZSTD_LEVEL}" -le 19 ] || die "BACKUP_ZSTD_LEVEL must be 1-19"
  [[ "${PREFIX}" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] && [[ "/${PREFIX}/" != */./* ]] && [[ "/${PREFIX}/" != */../* ]] \
    || die "BACKUP_PREFIX must be a folder path of letters, digits, '.', '_' and '-'"
  [ -n "${MSSQL_HOST:-}" ] || die "MSSQL_HOST is not set (reference \${{SQL Server.RAILWAY_PRIVATE_DOMAIN}})"
  local token="${MSSQL_BACKUP_TOKEN:-}"
  [ "${#token}" -ge 24 ] || die "MSSQL_BACKUP_TOKEN is missing or shorter than 24 characters"
  local port="${MSSQL_HELPER_PORT:-8080}"
  [[ "${port}" =~ ^[0-9]+$ ]] || die "MSSQL_HELPER_PORT must be a port number"
  # IPv6 literal hosts need brackets; private domains are names.
  HELPER="http://${MSSQL_HOST}:${port}"
}

configure_remote() {
  local var missing=()
  for var in BACKUP_S3_BUCKET BACKUP_S3_ENDPOINT BACKUP_S3_ACCESS_KEY_ID BACKUP_S3_SECRET_ACCESS_KEY; do
    [ -n "${!var:-}" ] || missing+=("${var}")
  done
  [ "${#missing[@]}" -eq 0 ] || die "Bucket not configured (missing: ${missing[*]})"
  export RCLONE_CONFIG="${HOME:-/tmp}/rclone.conf"
  : > "${RCLONE_CONFIG}"
  export RCLONE_CONFIG_BUCKET_TYPE=s3
  export RCLONE_CONFIG_BUCKET_PROVIDER=Other
  export RCLONE_CONFIG_BUCKET_ENDPOINT="${BACKUP_S3_ENDPOINT}"
  export RCLONE_CONFIG_BUCKET_REGION="${BACKUP_S3_REGION:-auto}"
  export RCLONE_CONFIG_BUCKET_ACCESS_KEY_ID="${BACKUP_S3_ACCESS_KEY_ID}"
  export RCLONE_CONFIG_BUCKET_SECRET_ACCESS_KEY="${BACKUP_S3_SECRET_ACCESS_KEY}"
  export RCLONE_CONFIG_BUCKET_FORCE_PATH_STYLE="${BACKUP_S3_FORCE_PATH_STYLE:-false}"
  export RCLONE_CONFIG_BUCKET_NO_CHECK_BUCKET=true
  export RCLONE_CONFIG_BUCKET_CHUNK_SIZE=16M
  REMOTE="bucket:${BACKUP_S3_BUCKET}/${PREFIX}"
}

# curl with the token from a file, so it never shows in the process list.
helper_curl() {
  curl -sS --retry 3 --retry-connrefused -H @"${WORK}/auth" "$@"
}

wait_for_helper() {
  local waited=0 code
  mkdir -p "${WORK}"
  chmod 0700 "${WORK}"
  printf 'Authorization: Bearer %s\n' "${MSSQL_BACKUP_TOKEN}" > "${WORK}/auth"
  while true; do
    code="$(curl -s -o "${WORK}/databases.json" -w '%{http_code}' -H @"${WORK}/auth" --max-time 60 "${HELPER}/backup/databases" || true)"
    [ "${code}" = 200 ] && return 0
    case "${code}" in
      401 | 403) die "the SQL Server helper refused the token (HTTP ${code}); MSSQL_BACKUP_TOKEN must reference \${{SQL Server.MSSQL_BACKUP_TOKEN}}" ;;
    esac
    [ "${waited}" -ge "${WAIT_SECONDS}" ] && die "SQL Server at ${HELPER} not ready after ${WAIT_SECONDS}s (last HTTP status ${code:-none}; is the EULA accepted and is SQL Server running?)"
    log "waiting for SQL Server at ${HELPER} (HTTP ${code:-none})"
    sleep 10
    waited=$((waited + 10))
  done
}

list_databases() {
  if [ -n "${DATABASES}" ]; then
    printf '%s\n' ${DATABASES//,/ }
  else
    jq -r '.databases[]' "${WORK}/databases.json"
  fi
}

backup_one() {
  local db="$1" dest="$2" headers="${WORK}/headers" sum="${WORK}/sha256" expected actual size
  rm -f "${headers}" "${sum}"
  helper_curl -f -X POST -D "${headers}" --max-time 86400 "${HELPER}/backup/${db}" \
    | tee >(sha256sum | cut -d ' ' -f 1 > "${sum}") \
    | zstd -q -T0 "-${ZSTD_LEVEL}" \
    | rclone rcat --retries 1 "${dest}" || return 1
  # tee's process substitution may finish a moment after the pipeline.
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "${sum}" ] && break; sleep 1; done
  expected="$(tr -d '\r' < "${headers}" | sed -n 's/^[Xx]-[Bb]ackup-[Ss][Hh][Aa]256: *//p' | tail -n 1)"
  actual="$(cat "${sum}" 2>/dev/null || true)"
  [ -n "${expected}" ] && [ "${expected}" = "${actual}" ] \
    || { log "ERROR: checksum mismatch for ${db} (server ${expected:-none}, received ${actual:-none})"; return 1; }
  rclone cat "${dest}" | zstd -q -t || { log "ERROR: ${dest} does not decompress"; return 1; }
  size="$(rclone size --json "${dest}" 2>/dev/null | sed -nE 's/.*"bytes":[[:space:]]*([0-9]+).*/\1/p')"
  BACKUP_SIZE="${size:-0}"
  BACKUP_SHA="${expected}"
}

run_backup() {
  local run_id dest db failed=0 dumped=() server
  run_id="$(date -u +%Y%m%dT%H%M%SZ)"
  dest="${REMOTE}/${run_id}"
  server="$(jq -r '.server' "${WORK}/databases.json")"
  log "starting run ${run_id} -> ${PREFIX}/${run_id}/ in bucket ${BACKUP_S3_BUCKET} (SQL Server ${server})"
  while IFS= read -r db; do
    [ -n "${db}" ] || continue
    [[ "${db}" =~ ${NAME_RE} ]] || { log "ERROR: skipping database '${db}': name not supported by the helper"; failed=1; continue; }
    log "backing up ${db}"
    if backup_one "${db}" "${dest}/${db}.bak.zst"; then
      log "database ${db} done (${BACKUP_SIZE} bytes compressed, SQL Server checksum + RESTORE VERIFYONLY + sha256 + zstd test)"
      dumped+=("${db}:${db}.bak.zst:${BACKUP_SIZE}:${BACKUP_SHA}")
    else
      log "ERROR: database ${db} failed"
      failed=1
    fi
  done < <(list_databases)
  [ "${#dumped[@]}" -gt 0 ] || { log "ERROR: no database was backed up (are there user databases?)"; failed=1; }
  [ "${failed}" -eq 0 ] || die "run ${run_id} is incomplete (no MANIFEST.txt); older backups were left untouched"
  {
    printf 'run=%s\nserver=%s\nformat=SQL Server native .bak (COPY_ONLY, CHECKSUM), zstd level %s\n' "${run_id}" "${server}" "${ZSTD_LEVEL}"
    printf 'database=%s\n' "${dumped[@]}"
  } | rclone rcat "${dest}/MANIFEST.txt"
  log "run ${run_id} complete: ${#dumped[@]} database(s)"
  CURRENT_RUN="${run_id}"
}

list_runs() {
  rclone lsf --dirs-only "${REMOTE}/" 2>/dev/null | sed 's#/$##' | grep -E "${RUN_RE}" | sort || true
}

list_complete_runs() {
  rclone lsf -R --files-only --max-depth 2 --include 'MANIFEST.txt' "${REMOTE}/" 2>/dev/null \
    | sed 's#/MANIFEST.txt$##' | grep -E "${RUN_RE}" | sort || true
}

prune() {
  local now cutoff incomplete_cutoff complete=() run keep protected=" " total
  now="$(date -u +%s)"
  cutoff="$(date -u -d "@$((now - RETENTION_DAYS * 86400))" +%Y%m%dT%H%M%SZ)"
  incomplete_cutoff="$(date -u -d "@$((now - INCOMPLETE_GRACE_DAYS * 86400))" +%Y%m%dT%H%M%SZ)"
  while IFS= read -r run; do [ -n "${run}" ] && complete+=("${run}"); done < <(list_complete_runs)
  total="${#complete[@]}"
  keep=$((total - KEEP_MIN))
  for run in ${complete[@]+"${complete[@]}"}; do
    if [ "${keep}" -le 0 ]; then protected="${protected}${run} "; fi
    keep=$((keep - 1))
  done
  log "retention: ${total} complete run(s), keep ${RETENTION_DAYS} days, at least ${KEEP_MIN}"
  while IFS= read -r run; do
    [ -n "${run}" ] || continue
    [ "${run}" = "${CURRENT_RUN:-}" ] && continue
    case "${protected}" in *" ${run} "*) continue ;; esac
    if printf '%s\n' ${complete[@]+"${complete[@]}"} | grep -qx "${run}"; then
      [[ "${run}" < "${cutoff}" ]] || continue
      log "deleting expired run ${run}"
    else
      [[ "${run}" < "${incomplete_cutoff}" ]] || continue
      log "deleting incomplete run ${run}"
    fi
    rclone purge "${REMOTE}/${run}" || log "WARNING: could not delete ${run}"
  done < <(list_runs)
}

show_runs() {
  local complete=" " run
  while IFS= read -r run; do complete="${complete}${run} "; done < <(list_complete_runs)
  while IFS= read -r run; do
    [ -n "${run}" ] || continue
    case "${complete}" in *" ${run} "*) printf '%s complete\n' "${run}" ;; *) printf '%s incomplete\n' "${run}" ;; esac
  done < <(list_runs)
}

# Restore never overwrites an existing database unless RESTORE_OVERWRITE=true.
run_restore() {
  local run="${RESTORE_RUN:-latest}" db="${RESTORE_DATABASE:-}" target object code
  [ -n "${db}" ] || db="$(printf '%s' "${MSSQL_DATABASE:-}")"
  [[ "${db}" =~ ${NAME_RE} ]] || die "RESTORE_DATABASE must name the database to restore (got '${db}')"
  target="${RESTORE_TARGET:-${db}_restored}"
  [[ "${target}" =~ ${NAME_RE} ]] || die "RESTORE_TARGET '${target}' is not a supported database name"
  if [ "${run}" = latest ]; then
    run="$(list_complete_runs | tail -n 1)"
    [ -n "${run}" ] || die "no complete backup run in ${PREFIX}/"
  fi
  [[ "${run}" =~ ${RUN_RE} ]] || die "RESTORE_RUN must be 'latest' or a run folder like 20261124T034500Z"
  object="${REMOTE}/${run}/${db}.bak.zst"
  rclone lsf "${REMOTE}/${run}/" | grep -qxF "${db}.bak.zst" || die "${PREFIX}/${run}/${db}.bak.zst does not exist"
  if jq -e --arg t "${target}" '.databases | index($t)' "${WORK}/databases.json" >/dev/null; then
    [ "${RESTORE_OVERWRITE:-false}" = true ] || die "database ${target} exists; set RESTORE_TARGET to a new name or RESTORE_OVERWRITE=true to replace it"
    log "RESTORE_OVERWRITE=true: replacing existing database ${target}"
  fi
  log "restoring ${PREFIX}/${run}/${db}.bak.zst into database ${target}"
  code="$(rclone cat "${object}" | zstd -q -d \
    | helper_curl -X POST -T - -H 'Content-Type: application/octet-stream' --max-time 86400 \
        -o "${WORK}/restore.out" -w '%{http_code}' "${HELPER}/restore/${target}")" || true
  sed 's/^/[mssql-backup] helper: /' "${WORK}/restore.out" 2>/dev/null || true
  [ "${code}" = 200 ] || die "restore failed (HTTP ${code:-none})"
  log "restore of ${db} from ${run} into ${target} finished"
}

main() {
  # A Railway start command such as "/usr/local/bin/mssql-backup restore" arrives as
  # arguments of the entrypoint; drop the repeated program name.
  case "${1:-}" in */mssql-backup | mssql-backup) shift ;; esac
  local cmd="${1:-backup}"
  case "${cmd}" in
    backup)
      validate_settings
      configure_remote
      wait_for_helper
      run_backup
      prune
      log "done"
      ;;
    list)
      configure_remote
      show_runs
      ;;
    restore)
      validate_settings
      configure_remote
      wait_for_helper
      run_restore
      ;;
    *) die "unknown command '${cmd}' (use: backup, list, restore)" ;;
  esac
}

main "$@"
