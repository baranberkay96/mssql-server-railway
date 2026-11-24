# NOTICE

This Railway template is a community package. It is not affiliated with or endorsed by Microsoft or Railway. "Microsoft" and "SQL Server" are trademarks of the Microsoft group of companies.

## What this template runs

| Component | Source | License |
|---|---|---|
| Microsoft SQL Server 2025 (CU11, 17.0.5065.9) | `mcr.microsoft.com/mssql/server:2025-CU11-ubuntu-24.04` (digest `sha256:05644dad…`), pulled from Microsoft's registry when Railway builds the service. **Not redistributed by this repository.** | Microsoft Software License Terms for SQL Server (https://go.microsoft.com/fwlink/?LinkId=746388). The deployer accepts them by setting `ACCEPT_EULA=Y`; edition rights depend on `MSSQL_PID` (Express: free incl. production; Developer editions: development and test only; Standard/Enterprise: your own licence). |
| go-sqlcmd v1.10.0 | release asset `sqlcmd-linux-amd64.tar.bz2` from https://github.com/microsoft/go-sqlcmd, checked by SHA-256 | MIT, Copyright (c) Microsoft Corporation |
| Ubuntu packages added at build time | `python3`, `ca-certificates` | PSF / per package |
| Backup image | `alpine:3.24.2` + `bash`, `coreutils`, `curl`, `jq`, `zstd`, `ca-certificates`; rclone 1.76.0 from `rclone/rclone:1.76.0` | per package (GPL-3.0-or-later, MIT, BSD), rclone MIT |

## Files written for this template

- `services/mssql/Dockerfile`, `railway-mssql-start.sh` (deploy-form checks, volume ownership, trace flag 1800 and mini dumps in `mssql.conf`, app database/login) and `railway-mssql-helper.py` (healthcheck and token-protected backup/restore endpoint; the HTTP server skeleton is adapted from our own `153-github-runner` healthz helper).
- `services/backup/Dockerfile` and `mssql-backup.sh` (retention logic adapted from our own `56-pgvector` backup job).
- `TEMPLATE.md`, `README.md`, `template.json`, this file.

## Reused or not reused

- The marketplace templates in `../_market/` (`wcAazg` → `railwayapp-templates/microsoft-sql-server`, `microsoft-sql-server`, `GY653h` → `dangos-dev/mssql-server-dockerfile`) were read for settings only (volume path, TCP proxy, `RAILWAY_RUN_UID`). Their repositories have no licence; nothing was copied. All three pre-accept the EULA with a default of `Y`; this template does not.

## Upstream material checked (2026-11-24)

- MCR tag list for `mssql/server` (newest: `2025-CU11-ubuntu-24.04`) and its image config (entrypoint `/opt/mssql/bin/launch_sqlservr.sh`, user `mssql`).
- Microsoft Learn: SQL Server on Linux environment variables (`MSSQL_PID` values for 2025, password policy), editions and limits of SQL Server 2025 (Express: 50 GB, 1,410 MB buffer pool, 4 cores, no backup compression, no S3 backup), trace flag 1800 for log I/O alignment.
