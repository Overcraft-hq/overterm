#!/usr/bin/env bash
# The database client's test servers, in Docker: PostgreSQL 16, MySQL 8.4,
# MariaDB 11.4, ClickHouse 24.8, an S3 server (RustFS), an SSH bastion, DynamoDB Local,
# InfluxDB 2.7, 1.11 and 3, and Neo4j 5 on ports nothing else uses,
# user `ot`, password `otpass`, database `shop` (where a server has them). Then:
#   OVERTERM_DB_TESTS=1 swift test --filter DatabaseDriverTests
#   (and DynamoDBTests, InfluxDBTests, Neo4jTests)
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
  docker rm -f ot-pg ot-mysql ot-mariadb ot-ch ot-minio ot-ssh ot-elasticsearch ot-opensearch ot-dynamodb ot-influxdb ot-influxdb1 ot-influxdb3 ot-neo4j >/dev/null 2>&1 || true
  docker network rm ot-net >/dev/null 2>&1 || true
  echo "==> stopped"
  exit 0
fi

docker rm -f ot-pg ot-mysql ot-mariadb ot-ch ot-minio ot-ssh ot-dynamodb ot-influxdb ot-influxdb1 ot-influxdb3 ot-neo4j >/dev/null 2>&1 || true
docker network create ot-net >/dev/null 2>&1 || true
docker run -d --name ot-pg --network ot-net -e POSTGRES_USER=ot -e POSTGRES_PASSWORD=otpass -e POSTGRES_DB=shop -p 55432:5432 postgres:16 >/dev/null
docker run -d --name ot-mysql -e MYSQL_ROOT_PASSWORD=otpass -e MYSQL_DATABASE=shop -e MYSQL_USER=ot -e MYSQL_PASSWORD=otpass \
  -p 53306:3306 mysql:8.4 >/dev/null
docker run -d --name ot-mariadb -e MARIADB_ROOT_PASSWORD=otpass -e MARIADB_DATABASE=shop -e MARIADB_USER=ot -e MARIADB_PASSWORD=otpass \
  -p 53307:3306 mariadb:11.4 >/dev/null
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

# DynamoDB Local, in memory: any credentials sign.
docker run -d --name ot-dynamodb -p 58800:8000 amazon/dynamodb-local:2.5.4 >/dev/null
# InfluxDB 2: org `ot`, bucket `shop`, token `ot-test-token` (its password
# must be 8 long: `otpass1234`); 1.11 with auth, admin `ot`/`otpass`.
docker run -d --name ot-influxdb -e DOCKER_INFLUXDB_INIT_MODE=setup -e DOCKER_INFLUXDB_INIT_USERNAME=ot \
  -e DOCKER_INFLUXDB_INIT_PASSWORD=otpass1234 -e DOCKER_INFLUXDB_INIT_ORG=ot -e DOCKER_INFLUXDB_INIT_BUCKET=shop \
  -e DOCKER_INFLUXDB_INIT_ADMIN_TOKEN=ot-test-token -p 58086:8086 influxdb:2.7-alpine >/dev/null
docker run -d --name ot-influxdb1 -e INFLUXDB_HTTP_AUTH_ENABLED=true -e INFLUXDB_ADMIN_USER=ot -e INFLUXDB_ADMIN_PASSWORD=otpass \
  -e INFLUXDB_DB=shop -p 58087:8086 influxdb:1.11-alpine >/dev/null
# InfluxDB 3 Core, in memory, without auth (its tokens are made by its own CLI).
docker run -d --name ot-influxdb3 -p 58181:8181 influxdb:3-core influxdb3 serve --node-id ot --object-store memory --without-auth >/dev/null
# Neo4j 5: its user is `neo4j`, a password 8 long (`otpass1234`); HTTP :57474, Bolt :57687.
docker run -d --name ot-neo4j -e NEO4J_AUTH=neo4j/otpass1234 -p 57474:7474 -p 57687:7687 neo4j:5-community >/dev/null

# Ready when each answers.
for _ in $(seq 1 120); do
  if docker exec ot-pg pg_isready -U ot >/dev/null 2>&1 \
    && docker exec ot-mysql mysqladmin ping -uot -potpass --silent >/dev/null 2>&1 \
    && docker exec ot-mariadb mariadb -uot -potpass -e 'SELECT 1' shop >/dev/null 2>&1 \
    && curl -sf "http://127.0.0.1:58123/ping" >/dev/null \
    && [[ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:59000/)" == "403" ]] \
    && nc -z 127.0.0.1 52222 >/dev/null 2>&1 && docker exec ot-ssh pgrep sshd >/dev/null 2>&1 \
    && [[ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:58800/)" == "400" ]] \
    && curl -sf "http://127.0.0.1:58086/ping" >/dev/null && curl -sf "http://127.0.0.1:58087/ping" >/dev/null && curl -sf "http://127.0.0.1:58181/health" >/dev/null \
    && curl -sf "http://127.0.0.1:57474/" >/dev/null; then
    echo "==> PostgreSQL :55432, MySQL :53306, MariaDB :53307, ClickHouse :58123, S3 (RustFS) :59000, SSH :52222,"
    echo "    DynamoDB Local :58800, InfluxDB 2 :58086, InfluxDB 1.11 :58087, InfluxDB 3 :58181, Neo4j :57474 (Bolt :57687)"
    exit 0
  fi
  sleep 1
done
echo "error: the servers didn't come up" >&2
exit 1
