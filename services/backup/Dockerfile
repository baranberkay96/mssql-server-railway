# SQL Server Backup (Railway cron job): curl + zstd + jq on Alpine, rclone from
# the official rclone image. The SQL Server container makes and verifies the
# native .bak; this job only streams, compresses, checks and uploads it.
FROM rclone/rclone:1.76.0@sha256:7cbeec24a44f206067597c0368be4de90ae19a64d5113c7d1938bd737a81e466 AS rclone

FROM alpine:3.24.2@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6

RUN apk add --no-cache bash coreutils ca-certificates curl jq zstd \
 && addgroup -S backup \
 && adduser -S -D -H -h /tmp -G backup backup

# rclone is a static Go binary (CGO disabled upstream).
COPY --from=rclone /usr/local/bin/rclone /usr/local/bin/rclone
COPY --chmod=0755 mssql-backup.sh /usr/local/bin/mssql-backup

ENV HOME=/tmp

# Fail the build early if a tool is missing or the script does not parse.
RUN rclone version >/dev/null \
 && curl --version >/dev/null \
 && zstd --version >/dev/null \
 && jq --version >/dev/null \
 && date -u -d @0 +%Y >/dev/null \
 && bash -n /usr/local/bin/mssql-backup

USER backup
WORKDIR /tmp

ENTRYPOINT ["/usr/local/bin/mssql-backup"]
CMD ["backup"]
