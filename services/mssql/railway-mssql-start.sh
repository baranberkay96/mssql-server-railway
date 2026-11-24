#!/bin/bash
# railway-mssql-start: boots Microsoft SQL Server 2025 on Railway (runs as root, PID 2
# under Railway's init).
#
#   1. Checks the deploy-form values. Nothing here exits with an error: a value
#      that cannot work (EULA not accepted, under 2 GB of memory, a first-boot sa
#      password that breaks SQL Server's policy) holds SQL Server back, keeps the
#      healthcheck answering 200 and says in this log what to change (STANDARD 8.29).
#   2. Gives the volume to the mssql user and starts the helper (healthcheck and
#      backup endpoint) on $PORT.
#   3. Starts a background job that creates MSSQL_DATABASE and the app login once
#      SQL Server answers, and keeps the login's password in sync with the variable.
#   4. Execs the image's own launcher (launch_sqlservr.sh sqlservr) as mssql.
set -uo pipefail
export LC_ALL=C

STATE=/tmp/railway-mssql-state
DATA=/var/opt/mssql
HELPER=/usr/local/lib/railway-mssql/railway-mssql-helper.py
MIN_MEMORY_MB=2000
APP_NAME_RE='^[A-Za-z_][A-Za-z0-9_]{0,127}$'

log() { printf 'railway-mssql: %s\n' "$*"; }
set_state() { printf '%s\n' "$1" > "$STATE"; chmod 0644 "$STATE"; }
as_mssql() { setpriv --reuid=mssql --regid="$(id -g mssql)" --init-groups -- env HOME="$DATA" "$@"; }

# Keep the container up with a passing healthcheck, but without SQL Server.
hold() {
  log "SQL Server is NOT started: $1"
  log "Change the variable named above on the SQL Server service and redeploy."
  set_state "hold: $1"
  exec setpriv --reuid=mssql --regid="$(id -g mssql)" --init-groups -- python3 "$HELPER"
}

# SQL Server's default policy: 8-128 characters from at least 3 of the 4 classes.
password_ok() {
  local p="$1" classes=0
  [ "${#p}" -ge 8 ] && [ "${#p}" -le 128 ] || return 1
  [[ "$p" =~ [A-Z] ]] && classes=$((classes + 1))
  [[ "$p" =~ [a-z] ]] && classes=$((classes + 1))
  [[ "$p" =~ [0-9] ]] && classes=$((classes + 1))
  [[ "$p" =~ [^A-Za-z0-9] ]] && classes=$((classes + 1))
  [ "$classes" -ge 3 ]
}

set_state "starting"
FIRST_BOOT=false
[ -f "$DATA/data/master.mdf" ] || FIRST_BOOT=true

# --- 1. deploy-form values ------------------------------------------------------
case "${ACCEPT_EULA:-}" in
  [Yy] | [Yy][Ee][Ss] | [Tt][Rr][Uu][Ee] | [Aa][Cc][Cc][Ee][Pp][Tt]) export ACCEPT_EULA=Y ;;
  *) hold "ACCEPT_EULA is '${ACCEPT_EULA:-}'. Set it to Y to accept the SQL Server licence terms (https://go.microsoft.com/fwlink/?LinkId=746388)." ;;
esac

LIMIT=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo max)
if [[ "$LIMIT" =~ ^[0-9]+$ ]]; then
  LIMIT_MB=$((LIMIT / 1048576))
  log "container memory limit ${LIMIT_MB} MB"
  if [ "$LIMIT_MB" -lt "$MIN_MEMORY_MB" ]; then
    hold "SQL Server needs at least 2 GB of memory and this service has ${LIMIT_MB} MB. Railway's Trial and Free plans cap a service below that; use the Hobby plan or higher."
  fi
fi

PID_IN="${MSSQL_PID:-Express}"
case "${PID_IN,,}" in
  express) PID_OUT=Express ;;
  evaluation) PID_OUT=Evaluation ;;
  developer | enterprisedeveloper) PID_OUT=EnterpriseDeveloper ;;
  standarddeveloper) PID_OUT=StandardDeveloper ;;
  standard) PID_OUT=Standard ;;
  enterprise) PID_OUT=Enterprise ;;
  enterprisecore) PID_OUT=EnterpriseCore ;;
  *)
    if [[ "$PID_IN" =~ ^[A-Za-z0-9]{5}(-[A-Za-z0-9]{5}){4}$ ]]; then
      PID_OUT="$PID_IN"
    else
      log "WARNING: MSSQL_PID='${PID_IN}' is not an edition name or product key; using Express"
      PID_OUT=Express
    fi
    ;;
esac
export MSSQL_PID="$PID_OUT"
case "$PID_OUT" in
  Express) log "edition: Express (free, licensed for production; 50 GB per database, 1,410 MB buffer pool, 4 cores)" ;;
  EnterpriseDeveloper | StandardDeveloper) log "edition: ${PID_OUT} (free, development and test only, NOT licensed for production)" ;;
  Evaluation) log "edition: Evaluation (expires 180 days after the first boot of this volume)" ;;
  [A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]-*) log "edition: from the product key in MSSQL_PID" ;;
  *) log "edition: ${PID_OUT} (needs a SQL Server licence you own)" ;;
esac

if ! password_ok "${MSSQL_SA_PASSWORD:-}"; then
  if [ "$FIRST_BOOT" = true ]; then
    hold "MSSQL_SA_PASSWORD does not meet SQL Server's password policy (8-128 characters from 3 of: upper case, lower case, digits, symbols)."
  fi
  log "WARNING: MSSQL_SA_PASSWORD does not meet the password policy; SQL Server keeps the sa password it was first set up with"
fi

if [ -n "${MSSQL_MEMORY_LIMIT_MB:-}" ]; then
  if [[ "$MSSQL_MEMORY_LIMIT_MB" =~ ^[0-9]+$ ]] && [ "$MSSQL_MEMORY_LIMIT_MB" -ge 2048 ]; then
    log "memory limit for SQL Server: ${MSSQL_MEMORY_LIMIT_MB} MB"
  else
    log "WARNING: MSSQL_MEMORY_LIMIT_MB='${MSSQL_MEMORY_LIMIT_MB}' is not a whole number >= 2048; using SQL Server's default (80% of the container limit)"
    unset MSSQL_MEMORY_LIMIT_MB
  fi
fi
[ -n "${MSSQL_COLLATION:-}" ] || unset MSSQL_COLLATION

# --- 2. volume ownership, helper --------------------------------------------------
MSSQL_UID=$(id -u mssql)
if [ "$(stat -c %u "$DATA")" != "$MSSQL_UID" ] || [ -n "$(find "$DATA" -maxdepth 2 ! -user mssql -print -quit 2>/dev/null)" ]; then
  log "giving ${DATA} to the mssql user (first boot or a volume written by another image)"
  chown -R mssql:"$(id -g mssql)" "$DATA"
fi
install -d -o mssql -g "$(id -g mssql)" -m 0750 "$DATA/railway-backup"

# Startup trace flags live in mssql.conf ([traceflag] section, managed here).
# 1800 makes SQL Server write its log in 4 KB-aligned blocks; Railway volumes
# otherwise trigger "misaligned log IOs" fallbacks during setup.
FLAGS="${MSSQL_TRACE_FLAGS-1800}"
if ! [[ "$FLAGS" =~ ^([0-9]{1,5}(,[0-9]{1,5})*)?$ ]]; then
  log "WARNING: MSSQL_TRACE_FLAGS='${FLAGS}' is not a comma-separated list of numbers; using 1800"
  FLAGS=1800
fi
python3 - "$DATA/mssql.conf" "$FLAGS" <<'PY'
import configparser, os, sys
path, flags = sys.argv[1], [f for f in sys.argv[2].split(",") if f]
conf = configparser.ConfigParser()
conf.optionxform = str
conf.read(path)
if conf.has_section("traceflag"):
    conf.remove_section("traceflag")
if flags:
    conf.add_section("traceflag")
    for i, flag in enumerate(flags):
        conf.set("traceflag", f"traceflag{i}", flag)
with open(path + ".tmp", "w") as handle:
    conf.write(handle)
os.replace(path + ".tmp", path)
PY
chown mssql:"$(id -g mssql)" "$DATA/mssql.conf"
log "startup trace flags: ${FLAGS:-none}"
find "$DATA/railway-backup" -type f -name '*.bak' -mmin +60 -delete 2>/dev/null || true

as_mssql python3 "$HELPER" &

# --- 3. app database and login (background) ---------------------------------------
app_setup() {
  local db="${MSSQL_DATABASE:-}" user="${MSSQL_APP_USER:-}" pass="${MSSQL_APP_PASSWORD:-}" sql waited=0
  if [ -n "$db" ] && ! [[ "$db" =~ $APP_NAME_RE ]]; then
    log "WARNING: MSSQL_DATABASE='${db}' is not a plain identifier (letters, digits, _); using 'railway'"
    db=railway
  fi
  if [ -n "$user" ] && ! [[ "$user" =~ $APP_NAME_RE ]]; then
    log "WARNING: MSSQL_APP_USER='${user}' is not a plain identifier; using 'railway'"
    user=railway
  fi
  until /usr/local/bin/sqlcmd -S tcp:127.0.0.1,1433 -U sa -C -l 5 -b -Q "SELECT 1" >/dev/null 2>&1; do
    sleep 5
    waited=$((waited + 5))
    if [ "$waited" -ge 900 ]; then
      log "WARNING: could not log in as sa within 15 minutes; app database and login not checked"
      set_state "running (app setup skipped: sa login failed)"
      return
    fi
  done
  if [ -z "$db" ]; then
    set_state "ready"
    return
  fi
  sql=$(mktemp)
  chmod 0600 "$sql"
  {
    printf 'SET NOCOUNT ON;\n'
    printf "IF DB_ID(N'%s') IS NULL BEGIN CREATE DATABASE [%s]; PRINT 'created database %s'; END;\n" "$db" "$db" "$db"
    if [ -n "$user" ] && password_ok "$pass"; then
      printf "IF SUSER_ID(N'%s') IS NULL BEGIN CREATE LOGIN [%s] WITH PASSWORD = N'%s', DEFAULT_DATABASE = [%s]; PRINT 'created login %s'; END\n" \
        "$user" "$user" "${pass//\'/\'\'}" "$db" "$user"
      printf "ELSE ALTER LOGIN [%s] WITH PASSWORD = N'%s';\n" "$user" "${pass//\'/\'\'}"
      printf "EXEC (N'USE [%s]; IF USER_ID(N''%s'') IS NULL CREATE USER [%s] FOR LOGIN [%s]; ELSE ALTER USER [%s] WITH LOGIN = [%s]; ALTER ROLE db_owner ADD MEMBER [%s];');\n" \
        "$db" "$user" "$user" "$user" "$user" "$user" "$user"
    elif [ -n "$user" ]; then
      log "WARNING: MSSQL_APP_PASSWORD does not meet the password policy; the app login was not created or updated"
    fi
  } > "$sql"
  if /usr/local/bin/sqlcmd -S tcp:127.0.0.1,1433 -U sa -C -b -i "$sql" 2>&1 | sed 's/^/railway-mssql: /'; then
    log "app database '${db}' and login '${user}' are in place"
    set_state "ready"
  else
    log "WARNING: app database/login setup failed (see above); SQL Server itself is running"
    set_state "running (app setup failed)"
  fi
  rm -f "$sql"
  if grep -q ':0599 ' /proc/net/tcp6 2>/dev/null; then
    log "listening on port 1433 over IPv4 and IPv6"
  else
    log "listening on port 1433 over IPv4 only (IPv6 private-network clients must fall back to IPv4)"
  fi
}
export SQLCMDPASSWORD="${MSSQL_SA_PASSWORD:-}"
app_setup &

# --- 4. SQL Server ------------------------------------------------------------------
log "starting SQL Server (first boot: ${FIRST_BOOT})"
cd "$DATA" || true
exec setpriv --reuid=mssql --regid="$(id -g mssql)" --init-groups -- \
  env HOME="$DATA" /opt/mssql/bin/launch_sqlservr.sh /opt/mssql/bin/sqlservr
