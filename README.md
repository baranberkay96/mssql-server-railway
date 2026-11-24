# Deploy and Host Microsoft SQL Server with Railway

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/microsoft-sql-server-2025-with-backups?referralCode=20H68q)

Microsoft SQL Server is the relational database behind countless .NET, Java and enterprise applications. This community template runs SQL Server 2025 on Linux from Microsoft's official container image, with the free Express edition by default, an app database and login created for you, TCP access for SSMS and other tools, and daily backups to a Railway Bucket.

## About Hosting Microsoft SQL Server

SQL Server in a container needs a few things done right: the licence terms must be accepted, the edition must fit how you use it, the volume must belong to the `mssql` user, and the transaction log must be written in a way the storage supports. On Railway's volumes SQL Server 2025 crashed during its first start until trace flag 1800 (4 KB-aligned log writes) was set; this template sets it. It also creates `MSSQL_DATABASE` with a least-privilege login, keeps that login's password in sync with the variable, exposes a private healthcheck, and backs up every user database with SQL Server's own `BACKUP DATABASE ... WITH CHECKSUM`, verified and compressed, to a Bucket.

## Common Use Cases

- Hosting the database for ASP.NET Core, Entity Framework or Java/Spring applications that target SQL Server
- Moving a small line-of-business database off a Windows server to a managed platform
- Development and test databases (switch to the free Developer editions) that match production SQL Server
- Reporting and integration targets for Power BI, SSIS-style ETL tools or Python data pipelines
- Learning T-SQL with a real server you can reach from SSMS, Azure Data Studio or VS Code

## Dependencies for Microsoft SQL Server Hosting

- Microsoft SQL Server 2025 container image (pulled from `mcr.microsoft.com` at build time)
- A Railway Bucket for backups (included, created by the template)
- **At least 2 GB of memory for the SQL Server service: use the Hobby plan or higher.** SQL Server refuses to start below 2,000 MB, so Railway's Trial and Free plans cannot run it; on those plans the service stays up but holds SQL Server back and says so in its log.

### Deployment Dependencies

- SQL Server on Linux containers: https://learn.microsoft.com/sql/linux/sql-server-linux-docker-container-deployment
- Environment variables: https://learn.microsoft.com/sql/linux/sql-server-linux-configure-environment-variables
- SQL Server 2025 editions and limits: https://learn.microsoft.com/sql/sql-server/editions-and-components-of-sql-server-2025
- Licence terms (EULA): https://go.microsoft.com/fwlink/?LinkId=746388
- Railway Storage Buckets: https://docs.railway.com/storage-buckets

### Implementation Details

| Service | Source | Purpose |
|---|---|---|
| SQL Server | built from this repo (`services/mssql`, `FROM mcr.microsoft.com/mssql/server:2025-CU11-ubuntu-24.04`) | SQL Server 2025 CU11, volume at `/var/opt/mssql`, TCP proxy to 1433, private healthcheck/backup helper on port 8080 |
| SQL Server Backup | built from this repo (`services/backup`) | Daily cron (03:45 UTC): native `.bak` of every user database, `RESTORE VERIFYONLY`, sha256, zstd, 14-day retention (at least 3 runs kept) |
| Bucket | Railway Bucket | Private S3 storage for the backups |

**Licence acceptance**: the deploy form asks for `ACCEPT_EULA`. Typing `Y` accepts Microsoft's licence terms for SQL Server; the template never accepts them for you. Any other value keeps SQL Server stopped (the deploy still succeeds and the log explains what to change).

**Editions** (`MSSQL_PID`): `Express` (default) is free and licensed for production, limited to 50 GB per database, 1,410 MB of buffer pool and 4 cores, and has no SQL Server Agent. `EnterpriseDeveloper` and `StandardDeveloper` are free with all features but licensed for development and test only. `Evaluation` runs 180 days. `Standard`, `EnterpriseCore` or a product key need a licence you own.

**Connection strings** (on the SQL Server service; reference them as `${{SQL Server.NAME}}`):

- `MSSQL_CONNECTION_STRING` (ADO.NET), `MSSQL_JDBC_URL`, `MSSQL_URL` (`sqlserver://` URL): private network, as the app login
- `MSSQL_PUBLIC_CONNECTION_STRING`, `MSSQL_PUBLIC_URL`: through the TCP proxy for SSMS, Azure Data Studio or `sqlcmd`
- Server address for desktop tools: `{RAILWAY_TCP_PROXY_DOMAIN},{RAILWAY_TCP_PROXY_PORT}` with SQL authentication; enable "Trust server certificate" (the certificate is self-signed)

**First steps**

1. Wait for the deploy log line `app database 'railway' and login 'railway' are in place`.
2. Connect with `MSSQL_PUBLIC_CONNECTION_STRING` (or the server address above, user `railway`, password from `MSSQL_APP_PASSWORD`).
3. Create your tables, or point your ORM migrations at `MSSQL_CONNECTION_STRING`.
4. Use `sa` (`MSSQL_SA_PASSWORD`) only for administration. Its password is set on the first boot; change it later with `ALTER LOGIN sa WITH PASSWORD = '...'` and update the variable so backups keep working.

**Backups and restore**: backups land in the Bucket under `mssql/{timestamp}/{database}.bak.zst` with a `MANIFEST.txt`. Trigger one now with `railway cron run --service "SQL Server Backup"`. SQL Server writes the backup next to its data first, so keep free volume space at least the size of your largest database. To restore, set the backup service's start command to `/usr/local/bin/mssql-backup restore`, optionally set `RESTORE_RUN`, `RESTORE_DATABASE` and `RESTORE_TARGET`, run it once, then clear the start command. It restores into `{database}_restored` and only replaces an existing database with `RESTORE_OVERWRITE=true`. You can also download a `.bak.zst`, decompress it with `zstd -d` and restore it on any SQL Server 2025.

**Scaling and memory**: SQL Server Express idled at about 1.1 GB on Railway in our test (roughly $11 per month of RAM at Railway's usage prices, plus volume and bucket storage). Express caps its buffer pool at 1,410 MB, other editions use up to 80% of the service limit unless `MSSQL_MEMORY_LIMIT_MB` is set. Raise the service's memory and CPU in its settings for larger workloads; volumes start at 5 GB on Hobby and 50 GB on Pro.

**Versions and upgrades**: the image is pinned to SQL Server 2025 CU11. To move to a newer cumulative update, change the tag and digest in `services/mssql/Dockerfile` and redeploy; SQL Server upgrades the system and user databases on the next start. Take a backup first.

### Why Deploy Microsoft SQL Server on Railway?

Railway gives SQL Server a persistent volume, a private network for your apps, a TCP proxy for your tools and a managed bucket for backups, so a working server is ready a few minutes after you accept the licence. Your .NET or Java services in the same project connect by reference, and you scale by raising the service limits instead of managing a VM.
