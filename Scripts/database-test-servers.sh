#!/usr/bin/env bash
# The database client's test servers, in Docker: PostgreSQL 16, MySQL 8.4
# and ClickHouse 24.8 on ports nothing else uses, user `ot`, password
# `otpass`, database `shop`. Then:
#   OVERTERM_DB_TESTS=1 swift test --filter DatabaseDriverTests
# `Scripts/database-test-servers.sh stop` removes them.
set -euo pipefail

if [[ "${1:-}" == "stop" ]]; then
  docker rm -f ot-pg ot-mysql ot-ch >/dev/null 2>&1 || true
  echo "==> stopped"
  exit 0
fi

docker rm -f ot-pg ot-mysql ot-ch >/dev/null 2>&1 || true
docker run -d --name ot-pg -e POSTGRES_USER=ot -e POSTGRES_PASSWORD=otpass -e POSTGRES_DB=shop -p 55432:5432 postgres:16 >/dev/null
docker run -d --name ot-mysql -e MYSQL_ROOT_PASSWORD=otpass -e MYSQL_DATABASE=shop -e MYSQL_USER=ot -e MYSQL_PASSWORD=otpass \
  -p 53306:3306 mysql:8.4 >/dev/null
docker run -d --name ot-ch -e CLICKHOUSE_USER=ot -e CLICKHOUSE_PASSWORD=otpass -e CLICKHOUSE_DB=shop -p 58123:8123 \
  clickhouse/clickhouse-server:24.8 >/dev/null

# Ready when each answers.
for _ in $(seq 1 60); do
  if docker exec ot-pg pg_isready -U ot >/dev/null 2>&1 \
    && docker exec ot-mysql mysqladmin ping -uot -potpass --silent >/dev/null 2>&1 \
    && curl -sf "http://127.0.0.1:58123/ping" >/dev/null; then
    echo "==> PostgreSQL :55432, MySQL :53306, ClickHouse :58123"
    exit 0
  fi
  sleep 1
done
echo "error: the servers didn't come up" >&2
exit 1
