# Microsoft SQL Server 2025 with Backups: Railway template spec

## Listing

| Field | Value |
|---|---|
| Name | **Microsoft SQL Server 2025 with Backups** (38 chars) |
| Description | SQL Server 2025, Express edition by default, with daily Bucket backups. (71 chars) |
| Category | Storage |
| Tags | sql-server, mssql, microsoft, database, sql, t-sql, backups |
| Icon | `https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/microsoft-sql-server.svg` (200, image/svg+xml) |

## Base market templates

| Market template | Topology | Kept | Problems fixed |
|---|---|---|---|
| `wcAazg` "Microsoft SQL Server" (Railway's own, 496 active) | repo `railwayapp-templates/microsoft-sql-server` (`FROM mcr.microsoft.com/mssql/server:2022-latest`), volume `/var/opt/mssql`, TCP proxy 1433, `RAILWAY_RUN_UID=0` | Volume path, TCP proxy, URL variables | **Pre-accepts the EULA** (`ACCEPT_EULA=Y` default), Developer edition by default (not licensed for production), floating `2022-latest`, runs as root, no healthcheck, everything as `sa`, no backups |
| `microsoft-sql-server` (56 active) | `mcr.microsoft.com/mssql/server:2022-latest` image | | Same EULA/edition problems, `secret(32)` sa password can miss SQL Server's complexity classes |
| `GY653h` "Microsoft SQL Server 2022" (65 active) | `dangos-dev/mssql-server-dockerfile` | | Hard-coded sa password in the template, TCP proxy on 5432 (wrong port) |

### Improvements over market templates

1. `ACCEPT_EULA` is a **required deploy input with no default**; the deployer accepts Microsoft's terms. Any other value holds SQL Server back with a passing healthcheck and a log line (8.29).
2. Express edition by default (free incl. production); Developer/Evaluation/licensed editions through `MSSQL_PID`, validated (unknown → Express).
3. SQL Server 2025 CU11 pinned by digest; go-sqlcmd pinned by SHA-256.
4. **Trace flag 1800** in `mssql.conf`: without it SQL Server 2025 crashed on Railway's volume on its first start ("256 misaligned log IOs ... falling back to synchronous IO" followed by a fatal "Stack Overflow"), and its full crash dumps filled the volume. Crash dumps are set to mini.
5. App database + least-privilege login (`db_owner` on that database only), password re-applied each boot; sa passwords are generated with a fixed `Sa1` prefix so they always meet the 3-of-4 character-class policy.
6. Under 2 GB of memory (Trial/Free) or a weak first-boot sa password: SQL Server is held back with a clear log message instead of a crash loop.
7. Private `/healthz` helper on port 8080 (8.34) that also serves a token-protected backup/restore endpoint.
8. Daily native backups (`COPY_ONLY, CHECKSUM` + `RESTORE VERIFYONLY`, sha256 end to end, zstd) to a Railway Bucket with retention, and a tested restore command.

## Pinned versions (checked 2026-11-24)

| Service | Image / build | Version |
|---|---|---|
| SQL Server | repo `services/mssql`, `FROM mcr.microsoft.com/mssql/server:2025-CU11-ubuntu-24.04@sha256:05644dad…` (built 2026-11-05) + Ubuntu `python3` + go-sqlcmd v1.10.0 | SQL Server 2025 RTM-CU11 (KB5129223), 17.0.5065.9 |
| SQL Server Backup | repo `services/backup`, `alpine:3.24.2` + curl/jq/zstd + rclone 1.76.0 | |

## Architecture

```
 Apps on Railway ── MSSQL_CONNECTION_STRING / MSSQL_URL ──► SQL Server :1433 (IPv4 + IPv6)
 SSMS / Azure Data Studio ── TCP proxy ───────────────────►   volume /var/opt/mssql (data, log, mssql.conf)
 Railway healthcheck ── :8080/healthz ─► helper (same container, mssql user)
 SQL Server Backup (cron 03:45 UTC) ── POST :8080/backup/{db} (Bearer MSSQL_BACKUP_TOKEN)
        helper: BACKUP DATABASE ... TO DISK (COPY_ONLY, CHECKSUM) + RESTORE VERIFYONLY → streams .bak, deletes it
        job: sha256 check → zstd → rclone rcat → Bucket mssql/{run}/{db}.bak.zst + MANIFEST.txt
```

## Services

### SQL Server

- Entrypoint `railway-mssql-start` (root): EULA / memory / edition / password checks, `chown` of the volume to `mssql` when needed, `mssql.conf` `[traceflag]` + `[coredump]`, storage facts in the log (ext4, O_DIRECT ok), helper, background app setup, then `setpriv` → `/opt/mssql/bin/launch_sqlservr.sh /opt/mssql/bin/sqlservr` as `mssql`.
- Volume `/var/opt/mssql`; TCP proxy → 1433; healthcheck `/healthz` (PORT 8080), timeout 600 s; restart ON_FAILURE ×10; draining 60 s.
- Listeners verified in the log: 1433 on IPv4 and IPv6.

### SQL Server Backup

Cron `45 3 * * *`, restart NEVER. Commands: `backup` (default), `list`, `restore` (start command `/usr/local/bin/mssql-backup restore`; target `{db}_restored`, overwrite only with `RESTORE_OVERWRITE=true`). The helper needs free volume space equal to the database being backed up.

## Resources and cost

| Service | Idle RAM | Typical | Notes |
|---|---|---|---|
| SQL Server | 1.1 GB (measured, Express, after a backup/restore) | 1–2 GB (Express buffer pool max 1,410 MB) | needs a ≥2 GB memory limit → Hobby or Pro |
| SQL Server Backup | 0 (runs seconds to minutes per day) | | |

Minimum plan: **Hobby**. Estimated $12–25/month for a small Express database at Railway prices (RAM $10/GB-month).

## Verification checklist

- [x] Both services SUCCESS on a fresh pre-publish deploy; `/healthz` passed; log shows app database and login created and 1433 on IPv4+IPv6.
- [x] `sa` login via TCP proxy: 17.0.5065.9 Express Edition; trace flags 1800 active.
- [x] App login created a table and inserted Unicode rows; `CREATE DATABASE` denied to it (least privilege).
- [x] Backup cron run: railway.bak.zst uploaded, sha256 + VERIFYONLY + zstd test, MANIFEST, retention.
- [x] Restore run into `railway_restored` (2 rows, MULTI_USER).
- [x] `ACCEPT_EULA=no`: deploy SUCCESS, SQL Server held back, log explains. 1 GB memory limit (Trial-sized): deploy SUCCESS, held back with the plan hint. Redeploy on the existing volume: data kept, app login works.

## Open questions

- SQL Server 2025's crash on Railway volumes without trace flag 1800 may also affect other SQL Server templates on Railway (Railway's own uses 2022).
- Express has no SQL Server Agent; schedule jobs from an app or a Railway cron service.
