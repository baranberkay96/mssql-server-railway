# Microsoft SQL Server 2025 for Railway.
#
# Base: Microsoft's own image (mcr.microsoft.com/mssql/server), pinned to the
# cumulative update and digest below. This repository only adds a start script
# and a small helper; SQL Server itself is not redistributed here, the image is
# pulled from Microsoft's registry and runs under Microsoft's licence terms,
# which the deployer accepts with ACCEPT_EULA=Y.
#
# Upgrade: change MSSQL_IMAGE to a newer 2025-CUxx tag (+ digest). Cumulative
# updates upgrade the databases on the volume in place at the next boot.
ARG MSSQL_IMAGE=mcr.microsoft.com/mssql/server:2025-CU11-ubuntu-24.04@sha256:05644dad1266ca3d445d1e8f6d2ebb9a6a03df9a39376e0f7b48917356dca9d9

# go-sqlcmd (MIT, static binary) from its GitHub release, checked by SHA-256.
FROM alpine:3.24.2 AS sqlcmd
ARG SQLCMD_VERSION=v1.10.0
ARG SQLCMD_SHA256=92516d98c63d99b0994de5b61350c91f6915f9b76f139a59039fbcb225c2e987
RUN apk add --no-cache curl \
 && curl -fsSL --retry 5 --retry-all-errors -o /tmp/sqlcmd.tar.bz2 \
      "https://github.com/microsoft/go-sqlcmd/releases/download/${SQLCMD_VERSION}/sqlcmd-linux-amd64.tar.bz2" \
 && echo "${SQLCMD_SHA256}  /tmp/sqlcmd.tar.bz2" | sha256sum -c - \
 && mkdir /out && tar -xjf /tmp/sqlcmd.tar.bz2 -C /out \
 && test -x /out/sqlcmd

FROM ${MSSQL_IMAGE}

USER root

# python3 runs the helper (healthcheck + backup endpoint); setpriv (util-linux)
# drops to the mssql user. Ubuntu packages, not pinned (STANDARD 8.27).
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && command -v setpriv \
 && id mssql \
 && test -x /opt/mssql/bin/launch_sqlservr.sh \
 && test -x /opt/mssql/bin/sqlservr

COPY --from=sqlcmd /out/sqlcmd /usr/local/bin/sqlcmd
COPY --chmod=0755 railway-mssql-start.sh /usr/local/bin/railway-mssql-start
COPY --chmod=0755 railway-mssql-helper.py /usr/local/lib/railway-mssql/railway-mssql-helper.py

RUN sqlcmd --version \
 && bash -n /usr/local/bin/railway-mssql-start \
 && python3 -m py_compile /usr/local/lib/railway-mssql/railway-mssql-helper.py

# Runs as root only long enough to fix volume ownership; SQL Server and the
# helper run as mssql (uid 10001).
ENTRYPOINT ["/usr/local/bin/railway-mssql-start"]
