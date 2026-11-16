#!/usr/bin/env bash
# The database client's test servers, in Docker: PostgreSQL 16, MySQL 8.4,
# ClickHouse 24.8, an S3 server (RustFS) and an SSH bastion on ports nothing else uses,
# user `ot`, password `otpass`, database `shop`. Then:
#   OVERTERM_DB_TESTS=1 swift test --filter DatabaseDriverTests
# `Scripts/database-test-servers.sh stop` removes them.
#
# The search engines are large (~1.3 GB each) and apart:
#   Scripts/database-test-servers.sh search [elasticsearch|opensearch]
# Elasticsearch 8 on :59200 — security on, TLS with its own certificate,
# user `ot` / `otpass` (a superuser made through `elastic`); OpenSearch 2 on
# :59210, its security plugin off (plain http, no user: its admin password
# must pass a policy `otpass` doesn't). Then:
#   OVERTERM_DB_TESTS=1 swift test --filter SearchDriverTests
# `… search stop` removes them; `docker rmi` the images when done.
set -euo pipefail

if [[ "${1:-}" == "search" ]]; then
  which="${2:-both}"
  if [[ "$which" == "stop" ]]; then
    docker rm -f ot-elasticsearch ot-opensearch >/dev/null 2>&1 || true
    echo "==> stopped"
    exit 0
  fi
  if [[ "$which" == "both" || "$which" == "elasticsearch" ]]; then
    docker rm -f ot-elasticsearch >/dev/null 2>&1 || true
    docker run -d --name ot-elasticsearch -e discovery.type=single-node -e ELASTIC_PASSWORD=otpass \
      -e ES_JAVA_OPTS="-Xms512m -Xmx512m" -e xpack.ml.enabled=false -p 59200:9200 elasticsearch:8.15.3 >/dev/null
    for _ in $(seq 1 120); do
      if curl -sfk -u elastic:otpass "https://127.0.0.1:59200/_cluster/health" >/dev/null 2>&1; then break; fi
      sleep 1
    done
    curl -sfk -u elastic:otpass -X POST "https://127.0.0.1:59200/_security/user/ot" -H 'Content-Type: application/json' \
      -d '{"password": "otpass", "roles": ["superuser"]}' >/dev/null
    echo "==> Elasticsearch :59200 (https, ot/otpass)"
  fi
  if [[ "$which" == "both" || "$which" == "opensearch" ]]; then
    docker rm -f ot-opensearch >/dev/null 2>&1 || true
    docker run -d --name ot-opensearch -e discovery.type=single-node -e DISABLE_SECURITY_PLUGIN=true \
      -e DISABLE_INSTALL_DEMO_CONFIG=true -e OPENSEARCH_JAVA_OPTS="-Xms512m -Xmx512m" -p 59210:9200 \
      opensearchproject/opensearch:2.18.0 >/dev/null
    for _ in $(seq 1 120); do
      if curl -sf "http://127.0.0.1:59210/_cluster/health" >/dev/null 2>&1; then break; fi
      sleep 1
    done
    curl -sf "http://127.0.0.1:59210/_cluster/health" >/dev/null || { echo "error: OpenSearch didn't come up" >&2; exit 1; }
    echo "==> OpenSearch :59210 (http)"
  fi
  exit 0
fi

if [[ "${1:-}" == "stop" ]]; then
  docker rm -f ot-pg ot-mysql ot-ch ot-minio ot-ssh ot-elasticsearch ot-opensearch >/dev/null 2>&1 || true
  docker network rm ot-net >/dev/null 2>&1 || true
  echo "==> stopped"
  exit 0
fi

docker rm -f ot-pg ot-mysql ot-ch ot-minio ot-ssh >/dev/null 2>&1 || true
docker network create ot-net >/dev/null 2>&1 || true
docker run -d --name ot-pg --network ot-net -e POSTGRES_USER=ot -e POSTGRES_PASSWORD=otpass -e POSTGRES_DB=shop -p 55432:5432 postgres:16 >/dev/null
docker run -d --name ot-mysql -e MYSQL_ROOT_PASSWORD=otpass -e MYSQL_DATABASE=shop -e MYSQL_USER=ot -e MYSQL_PASSWORD=otpass \
  -p 53306:3306 mysql:8.4 >/dev/null
docker run -d --name ot-ch -e CLICKHOUSE_USER=ot -e CLICKHOUSE_PASSWORD=otpass -e CLICKHOUSE_DB=shop -p 58123:8123 \
  clickhouse/clickhouse-server:24.8 >/dev/null
# S3, for the storage client: access key `otadmin`, secret `otpass12345`.
# RustFS — MinIO no longer publishes images anyone can pull; this one
# checks signatures as S3 does. Pinned by digest.
docker run -d --name ot-minio -e RUSTFS_ACCESS_KEY=otadmin -e RUSTFS_SECRET_KEY=otpass12345 -p 59000:9000 \
  rustfs/rustfs@sha256:9ca9559533b537d10482fe923288b676ad08f92a7069d9a17327fbae3cab688b >/dev/null
# An SSH bastion for the tunnel (:52222, user `tunnel`, password `tunnelpass`),
# on the same network as PostgreSQL: through it, the database is `ot-pg:5432`.
docker run -d --name ot-ssh --network ot-net -p 52222:22 alpine:3.20 sh -c '
  apk add --no-cache openssh >/dev/null && ssh-keygen -A >/dev/null &&
  adduser -D -s /bin/sh tunnel && echo "tunnel:tunnelpass" | chpasswd &&
  exec /usr/sbin/sshd -D -e -o PasswordAuthentication=yes -o AllowTcpForwarding=yes' >/dev/null

# Ready when each answers.
for _ in $(seq 1 60); do
  if docker exec ot-pg pg_isready -U ot >/dev/null 2>&1 \
    && docker exec ot-mysql mysqladmin ping -uot -potpass --silent >/dev/null 2>&1 \
    && curl -sf "http://127.0.0.1:58123/ping" >/dev/null \
    && [[ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:59000/)" == "403" ]] \
    && nc -z 127.0.0.1 52222 >/dev/null 2>&1 && docker exec ot-ssh pgrep sshd >/dev/null 2>&1; then
    echo "==> PostgreSQL :55432, MySQL :53306, ClickHouse :58123, S3 (RustFS) :59000, SSH :52222"
    exit 0
  fi
  sleep 1
done
echo "error: the servers didn't come up" >&2
exit 1
