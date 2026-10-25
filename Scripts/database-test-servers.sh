#!/usr/bin/env bash
# The database client's test servers, in Docker: PostgreSQL 16, MySQL 8.4,
# ClickHouse 24.8 and an S3 server (RustFS) on ports nothing else uses, user `ot`, password
# `otpass`, database `shop`. Then:
#   OVERTERM_DB_TESTS=1 swift test --filter DatabaseDriverTests
# `Scripts/database-test-servers.sh stop` removes them.
set -euo pipefail

if [[ "${1:-}" == "stop" ]]; then
  docker rm -f ot-pg ot-mysql ot-ch ot-minio >/dev/null 2>&1 || true
  echo "==> stopped"
  exit 0
fi

docker rm -f ot-pg ot-mysql ot-ch ot-minio >/dev/null 2>&1 || true
docker run -d --name ot-pg -e POSTGRES_USER=ot -e POSTGRES_PASSWORD=otpass -e POSTGRES_DB=shop -p 55432:5432 postgres:16 >/dev/null
docker run -d --name ot-mysql -e MYSQL_ROOT_PASSWORD=otpass -e MYSQL_DATABASE=shop -e MYSQL_USER=ot -e MYSQL_PASSWORD=otpass \
  -p 53306:3306 mysql:8.4 >/dev/null
docker run -d --name ot-ch -e CLICKHOUSE_USER=ot -e CLICKHOUSE_PASSWORD=otpass -e CLICKHOUSE_DB=shop -p 58123:8123 \
  clickhouse/clickhouse-server:24.8 >/dev/null
# S3, for the storage client: access key `otadmin`, secret `otpass12345`.
# RustFS — MinIO no longer publishes images anyone can pull; this one
# checks signatures as S3 does. Pinned by digest.
docker run -d --name ot-minio -e RUSTFS_ACCESS_KEY=otadmin -e RUSTFS_SECRET_KEY=otpass12345 -p 59000:9000 \
  rustfs/rustfs@sha256:9ca9559533b537d10482fe923288b676ad08f92a7069d9a17327fbae3cab688b >/dev/null

# Ready when each answers.
for _ in $(seq 1 60); do
  if docker exec ot-pg pg_isready -U ot >/dev/null 2>&1 \
    && docker exec ot-mysql mysqladmin ping -uot -potpass --silent >/dev/null 2>&1 \
    && curl -sf "http://127.0.0.1:58123/ping" >/dev/null \
    && [[ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:59000/)" == "403" ]]; then
    echo "==> PostgreSQL :55432, MySQL :53306, ClickHouse :58123, S3 (RustFS) :59000"
    exit 0
  fi
  sleep 1
done
echo "error: the servers didn't come up" >&2
exit 1
