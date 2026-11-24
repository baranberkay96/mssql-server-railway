#!/usr/bin/env python3
"""railway-mssql-helper: healthcheck plus backup/restore endpoint for SQL Server on Railway.

Runs next to sqlservr in the same container, as the mssql user, on $PORT
(private network only: the service has no public HTTP domain).

  GET  /healthz                 200 while SQL Server accepts TCP on 1433, 503 before.
                                Also 200 when the start script holds SQL Server back on
                                purpose (EULA not accepted, too little memory, weak sa
                                password): the body says why, the deploy log says how
                                to fix it (STANDARD 8.29: a deploy-form value must not
                                fail the deploy).
  GET  /backup/databases        JSON list of online user databases.            (token)
  POST /backup/{database}       BACKUP DATABASE ... WITH COPY_ONLY, CHECKSUM to a temp
                                file on the volume, RESTORE VERIFYONLY, then streams
                                the .bak (X-Backup-SHA256 header) and deletes it.  (token)
  POST /restore/{database}      Request body = a .bak file (Content-Length or chunked).
                                Restores it under that name WITH REPLACE, then deletes
                                the upload and the replaced database's old files. (token)

The token is MSSQL_BACKUP_TOKEN (Authorization: Bearer ...). With no token of at
least 24 characters the backup endpoints are disabled. sqlcmd reads the sa
password from SQLCMDPASSWORD, never from the command line.
"""
import hashlib
import hmac
import http.server
import json
import os
import re
import socket
import subprocess
import sys
import threading
import urllib.parse
import uuid

STATE_FILE = "/tmp/railway-mssql-state"
SQLCMD = "/usr/local/bin/sqlcmd"
BACKUP_DIR = "/var/opt/mssql/railway-backup"
DATA_DIR = "/var/opt/mssql/data"
SQL_ADDR = ("127.0.0.1", 1433)
DEFAULT_PORT = 8080
MIN_TOKEN_LENGTH = 24
CHUNK = 1024 * 1024
# Database names this endpoint accepts (SQL Server allows more; keep it simple and safe).
NAME_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$")
SYSTEM_DATABASES = {"master", "model", "msdb", "tempdb"}
JOB_LOCK = threading.Lock()  # one backup or restore at a time


def log(message: str) -> None:
    print(f"railway-mssql-helper: {message}", file=sys.stderr, flush=True)


def port() -> int:
    value = os.environ.get("PORT", "")
    if value.isdigit() and 1 <= int(value) <= 65535:
        return int(value)
    return DEFAULT_PORT


def state() -> str:
    try:
        with open(STATE_FILE, encoding="utf-8") as handle:
            return handle.read(300).strip() or "starting"
    except OSError:
        return "starting"


def sql_accepts_tcp() -> bool:
    try:
        with socket.create_connection(SQL_ADDR, timeout=2):
            return True
    except OSError:
        return False


def quote_ident(name: str) -> str:
    return "[" + name.replace("]", "]]") + "]"


def quote_literal(value: str) -> str:
    return "N'" + value.replace("'", "''") + "'"


class SqlError(Exception):
    pass


def sqlcmd(query: str, timeout: int) -> list[list[str]]:
    """Run T-SQL as sa on the local server; return result rows split on tabs."""
    env = dict(os.environ, SQLCMDPASSWORD=os.environ.get("MSSQL_SA_PASSWORD", ""))
    try:
        result = subprocess.run(
            [SQLCMD, "-S", "tcp:127.0.0.1,1433", "-U", "sa", "-C", "-b", "-h", "-1", "-W", "-s", "\t",
             "-Q", "SET NOCOUNT ON; " + query],
            capture_output=True, text=True, env=env, timeout=timeout, check=False)
    except subprocess.TimeoutExpired as err:
        raise SqlError(f"sqlcmd timed out after {timeout}s") from err
    if result.returncode != 0:
        message = (result.stderr.strip() or result.stdout.strip())[-1500:]
        raise SqlError(message or f"sqlcmd exited {result.returncode}")
    return [line.split("\t") for line in result.stdout.splitlines() if line.strip()]


def user_databases() -> list[str]:
    rows = sqlcmd("SELECT name FROM sys.databases WHERE database_id > 4 AND state_desc = 'ONLINE' ORDER BY name", 60)
    return [row[0] for row in rows if row and row[0] not in SYSTEM_DATABASES]


def server_version() -> str:
    rows = sqlcmd("SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(64)) + ' ' "
                  "+ CAST(SERVERPROPERTY('Edition') AS nvarchar(128))", 60)
    return rows[0][0] if rows else "unknown"


def job_timeout() -> int:
    value = os.environ.get("MSSQL_BACKUP_TIMEOUT_SECONDS", "")
    return int(value) if value.isdigit() and int(value) >= 60 else 6 * 3600


def file_sha256(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(CHUNK), b""):
            digest.update(block)
    return digest.hexdigest()


def remove_quietly(path: str) -> None:
    try:
        os.remove(path)
    except OSError:
        pass


def database_files(name: str) -> list[str]:
    rows = sqlcmd("SELECT physical_name FROM sys.master_files WHERE database_id = DB_ID("
                  + quote_literal(name) + ")", 60)
    return [row[0] for row in rows if row]


def restore_moves(name: str, upload: str) -> str:
    """MOVE clauses that put every file of the backup under a fresh, unique name."""
    rows = sqlcmd("RESTORE FILELISTONLY FROM DISK = " + quote_literal(upload), 600)
    tag = uuid.uuid4().hex[:8]
    moves, data_files = [], 0
    for index, row in enumerate(rows):
        if len(row) < 3:
            continue
        logical, kind = row[0], row[2].strip().upper()
        if kind == "L":
            suffix = ".ldf"
        elif kind == "D":
            suffix = ".mdf" if data_files == 0 else ".ndf"
            data_files += 1
        else:  # FILESTREAM / full-text containers are directories
            suffix = ""
        target = f"{DATA_DIR}/{name}_{tag}_{index}{suffix}"
        moves.append(f"MOVE {quote_literal(logical)} TO {quote_literal(target)}")
    if not moves:
        raise SqlError("RESTORE FILELISTONLY returned no files; is the upload a SQL Server backup?")
    return ", ".join(moves)


def fix_app_user(name: str) -> None:
    """After restoring the app database, map its user to the server login again."""
    user = os.environ.get("MSSQL_APP_USER", "")
    if name != os.environ.get("MSSQL_DATABASE") or not NAME_RE.match(user):
        return
    sqlcmd(f"USE {quote_ident(name)}; "
           f"IF SUSER_ID({quote_literal(user)}) IS NOT NULL BEGIN "
           f"IF USER_ID({quote_literal(user)}) IS NULL CREATE USER {quote_ident(user)} FOR LOGIN {quote_ident(user)}; "
           f"ELSE ALTER USER {quote_ident(user)} WITH LOGIN = {quote_ident(user)}; "
           f"ALTER ROLE db_owner ADD MEMBER {quote_ident(user)}; END", 120)


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "railway-mssql-helper"
    sys_version = ""

    # -- plumbing -------------------------------------------------------------
    def reply(self, code: int, body: str, content_type: str = "text/plain; charset=utf-8") -> None:
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def authorized(self) -> bool:
        token = os.environ.get("MSSQL_BACKUP_TOKEN", "")
        if len(token) < MIN_TOKEN_LENGTH:
            self.reply(403, "backup endpoints disabled: MSSQL_BACKUP_TOKEN is unset or shorter than 24 characters\n")
            return False
        header = self.headers.get("Authorization", "")
        if not hmac.compare_digest(header.encode(), f"Bearer {token}".encode()):
            self.reply(401, "unauthorized\n")
            return False
        if not sql_accepts_tcp():
            self.reply(503, f"SQL Server is not accepting connections ({state()})\n")
            return False
        return True

    def database_arg(self, prefix: str) -> str | None:
        name = urllib.parse.unquote(self.path.split("?", 1)[0][len(prefix):])
        if not NAME_RE.match(name) or name in SYSTEM_DATABASES:
            self.reply(400, "database name must match [A-Za-z0-9_][A-Za-z0-9_.-]* and not be a system database\n")
            return None
        return name

    def log_message(self, *args) -> None:  # healthchecks would flood the deploy log
        return

    # -- routes ---------------------------------------------------------------
    def do_GET(self) -> None:  # noqa: N802 (http.server naming)
        path = self.path.split("?", 1)[0]
        if path in ("/healthz", "/"):
            current = state()
            if current.startswith("hold"):
                self.reply(200, f"ok {current}\n")
            elif sql_accepts_tcp():
                self.reply(200, f"ok {current}\n")
            else:
                self.reply(503, f"starting: SQL Server is not accepting connections yet ({current})\n")
        elif path == "/backup/databases":
            if self.authorized():
                try:
                    self.reply(200, json.dumps({"server": server_version(), "databases": user_databases()}) + "\n",
                               "application/json")
                except SqlError as err:
                    self.reply(500, f"listing databases failed: {err}\n")
        else:
            self.reply(404, "not found\n")

    do_HEAD = do_GET

    def do_POST(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        if path.startswith("/backup/"):
            handler, prefix = self.backup, "/backup/"
        elif path.startswith("/restore/"):
            handler, prefix = self.restore, "/restore/"
        else:
            self.reply(404, "not found\n")
            return
        if not self.authorized():
            return
        name = self.database_arg(prefix)
        if name is None:
            return
        if not JOB_LOCK.acquire(blocking=False):
            self.reply(409, "another backup or restore is running\n")
            return
        try:
            handler(name)
        finally:
            JOB_LOCK.release()

    def backup(self, name: str) -> None:
        if name not in user_databases():
            self.reply(404, f"database {name} not found or not online\n")
            return
        os.makedirs(BACKUP_DIR, exist_ok=True)
        target = f"{BACKUP_DIR}/{uuid.uuid4().hex}.bak"
        try:
            log(f"backup of {name} started")
            sqlcmd(f"BACKUP DATABASE {quote_ident(name)} TO DISK = {quote_literal(target)} "
                   f"WITH COPY_ONLY, CHECKSUM, INIT, FORMAT; "
                   f"RESTORE VERIFYONLY FROM DISK = {quote_literal(target)} WITH CHECKSUM;", job_timeout())
            size, digest = os.path.getsize(target), file_sha256(target)
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(size))
            self.send_header("X-Backup-SHA256", digest)
            self.send_header("X-Backup-Server", server_version())
            self.end_headers()
            with open(target, "rb") as handle:
                for block in iter(lambda: handle.read(CHUNK), b""):
                    self.wfile.write(block)
            log(f"backup of {name} streamed ({size} bytes, sha256 {digest[:12]}...)")
        except SqlError as err:
            log(f"backup of {name} failed: {err}")
            self.reply(500, f"backup failed: {err}\n")
        except (BrokenPipeError, ConnectionResetError):
            log(f"backup of {name}: client disconnected")
        finally:
            remove_quietly(target)

    def read_body(self, out) -> int:
        """Copy the request body (Content-Length or chunked) to out; return its size."""
        total = 0
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            while True:
                size = int(self.rfile.readline().split(b";", 1)[0].strip() or b"0", 16)
                if size == 0:
                    while self.rfile.readline() not in (b"\r\n", b"\n", b""):
                        pass
                    return total
                remaining = size
                while remaining:
                    block = self.rfile.read(min(CHUNK, remaining))
                    if not block:
                        raise ValueError("body ended early")
                    out.write(block)
                    remaining -= len(block)
                total += size
                self.rfile.readline()
        length = self.headers.get("Content-Length", "")
        if not length.isdigit():
            raise ValueError("send the backup with Content-Length or chunked transfer encoding")
        remaining = int(length)
        while remaining:
            block = self.rfile.read(min(CHUNK, remaining))
            if not block:
                raise ValueError("body ended early")
            out.write(block)
            remaining -= len(block)
            total += len(block)
        return total

    def restore(self, name: str) -> None:
        os.makedirs(BACKUP_DIR, exist_ok=True)
        upload = f"{BACKUP_DIR}/{uuid.uuid4().hex}.restore.bak"
        try:
            with open(upload, "wb") as handle:
                size = self.read_body(handle)
            log(f"restore of {name} started ({size} bytes uploaded)")
            moves = restore_moves(name, upload)
            old_files = database_files(name) if name in user_databases() else []
            if old_files:
                sqlcmd(f"ALTER DATABASE {quote_ident(name)} SET SINGLE_USER WITH ROLLBACK IMMEDIATE", 600)
            try:
                sqlcmd(f"RESTORE DATABASE {quote_ident(name)} FROM DISK = {quote_literal(upload)} "
                       f"WITH REPLACE, RECOVERY, CHECKSUM, {moves}", job_timeout())
            finally:
                if old_files:  # back to normal also when the restore failed
                    try:
                        sqlcmd(f"IF DB_ID({quote_literal(name)}) IS NOT NULL "
                               f"ALTER DATABASE {quote_ident(name)} SET MULTI_USER", 600)
                    except SqlError as err:
                        log(f"could not set {name} back to MULTI_USER: {err}")
            fix_app_user(name)
            kept = set(database_files(name))
            for path in old_files:
                if path not in kept and path.startswith(DATA_DIR + "/"):
                    remove_quietly(path)
            log(f"restore of {name} finished")
            self.reply(200, f"restored {name} ({size} bytes)\n")
        except (SqlError, ValueError) as err:
            log(f"restore of {name} failed: {err}")
            self.reply(500, f"restore failed: {err}\n")
        finally:
            remove_quietly(upload)


class DualStackServer(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6
    daemon_threads = True

    def server_bind(self) -> None:
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()


def main() -> None:
    try:
        server = DualStackServer(("::", port()), Handler)
    except OSError:  # no IPv6 in this container
        server = http.server.ThreadingHTTPServer(("0.0.0.0", port()), Handler)
        server.daemon_threads = True
    log(f"listening on port {port()}")
    server.serve_forever()


if __name__ == "__main__":
    main()
