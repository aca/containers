# pgactive Smoke Test

This runbook verifies that the `postgres-18` image can run a two-node
`pgactive` active-active replication setup.

## Build And Load

```sh
nix build ./postgres-18#container -L
docker load < result
```

Depending on the Docker-compatible runtime, the loaded image may be tagged as
`postgres-18:latest` or `localhost/postgres-18:latest`. The examples below use
`localhost/postgres-18:latest`; override it when needed:

```sh
export PG18_IMAGE="${PG18_IMAGE:-localhost/postgres-18:latest}"
```

## Start Two Nodes

```sh
docker rm -f pgactive-smoke-node1 pgactive-smoke-node2 >/dev/null 2>&1 || true
docker network rm pgactive-smoke-net >/dev/null 2>&1 || true
docker network create pgactive-smoke-net

docker run -d \
  --name pgactive-smoke-node1 \
  --network pgactive-smoke-net \
  "$PG18_IMAGE"

docker run -d \
  --name pgactive-smoke-node2 \
  --network pgactive-smoke-net \
  "$PG18_IMAGE"

for name in pgactive-smoke-node1 pgactive-smoke-node2; do
  for i in $(seq 1 60); do
    if docker exec "$name" pg_isready -U postgres >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  docker exec "$name" pg_isready -U postgres
done
```

Confirm the image has the settings `pgactive` needs:

```sh
docker exec pgactive-smoke-node1 psql -U postgres -Atc \
  "select current_setting('shared_preload_libraries'), current_setting('wal_level'), current_setting('track_commit_timestamp'), current_setting('max_logical_replication_workers');"

docker exec pgactive-smoke-node1 stat -c '%a %n' /tmp
```

Expected output:

```text
timescaledb,pgactive|logical|on|20
1777 /tmp
```

## Create The First Node

```sh
docker exec -i pgactive-smoke-node1 psql -v ON_ERROR_STOP=1 -U postgres -d postgres <<'SQL'
CREATE EXTENSION IF NOT EXISTS pgactive;
CREATE SCHEMA IF NOT EXISTS inventory;
CREATE TABLE inventory.products (
  id text PRIMARY KEY,
  product_name text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);
INSERT INTO inventory.products (id, product_name)
VALUES ('node1-soap', 'soap'), ('node1-shampoo', 'shampoo'), ('node1-conditioner', 'conditioner');

CREATE SERVER pgactive_server_node1
  FOREIGN DATA WRAPPER pgactive_fdw
  OPTIONS (host 'pgactive-smoke-node1', port '5432', dbname 'postgres');
CREATE USER MAPPING FOR postgres
  SERVER pgactive_server_node1
  OPTIONS (user 'postgres');

CREATE SERVER pgactive_server_node2
  FOREIGN DATA WRAPPER pgactive_fdw
  OPTIONS (host 'pgactive-smoke-node2', port '5432', dbname 'postgres');
CREATE USER MAPPING FOR postgres
  SERVER pgactive_server_node2
  OPTIONS (user 'postgres');

SELECT pgactive.pgactive_create_group(
  node_name := 'node1-postgres',
  node_dsn := 'user_mapping=postgres pgactive_foreign_server=pgactive_server_node1'
);
SELECT pgactive.pgactive_wait_for_node_ready();
SELECT node_name, node_status FROM pgactive.pgactive_nodes ORDER BY node_name;
SQL
```

Expected status:

```text
node1-postgres | r
```

## Join The Second Node

```sh
docker exec -i pgactive-smoke-node2 psql -v ON_ERROR_STOP=1 -U postgres -d postgres <<'SQL'
CREATE EXTENSION IF NOT EXISTS pgactive;

CREATE SERVER pgactive_server_node1
  FOREIGN DATA WRAPPER pgactive_fdw
  OPTIONS (host 'pgactive-smoke-node1', port '5432', dbname 'postgres');
CREATE USER MAPPING FOR postgres
  SERVER pgactive_server_node1
  OPTIONS (user 'postgres');

CREATE SERVER pgactive_server_node2
  FOREIGN DATA WRAPPER pgactive_fdw
  OPTIONS (host 'pgactive-smoke-node2', port '5432', dbname 'postgres');
CREATE USER MAPPING FOR postgres
  SERVER pgactive_server_node2
  OPTIONS (user 'postgres');

SELECT pgactive.pgactive_join_group(
  node_name := 'node2-postgres',
  node_dsn := 'user_mapping=postgres pgactive_foreign_server=pgactive_server_node2',
  join_using_dsn := 'user_mapping=postgres pgactive_foreign_server=pgactive_server_node1'
);
SELECT pgactive.pgactive_wait_for_node_ready();
SELECT node_name, node_status FROM pgactive.pgactive_nodes ORDER BY node_name;
SELECT count(*) AS product_count FROM inventory.products;
SQL
```

Expected status:

```text
node1-postgres | r
node2-postgres | r
product_count  | 3
```

## Verify Active-Active Replication

Insert on node2 and verify it appears on node1:

```sh
docker exec pgactive-smoke-node2 psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
  -c "INSERT INTO inventory.products (id, product_name) VALUES ('node2-lotion', 'lotion');" \
  -c "SELECT pgactive.pgactive_wait_for_slots_confirmed_flush_lsn(NULL, NULL);"

docker exec pgactive-smoke-node1 psql -U postgres -d postgres -Atc \
  "SELECT count(*) FROM inventory.products WHERE id = 'node2-lotion';"
```

Insert on node1 and verify it appears on node2:

```sh
docker exec pgactive-smoke-node1 psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
  -c "INSERT INTO inventory.products (id, product_name) VALUES ('node1-serum', 'serum');" \
  -c "SELECT pgactive.pgactive_wait_for_slots_confirmed_flush_lsn(NULL, NULL);"

docker exec pgactive-smoke-node2 psql -U postgres -d postgres -Atc \
  "SELECT count(*) FROM inventory.products WHERE id = 'node1-serum';"
```

Both count queries should return `1`. Both nodes should then report the same row
set:

```sh
docker exec pgactive-smoke-node1 psql -U postgres -d postgres -Atc \
  "SELECT id FROM inventory.products ORDER BY id;"

docker exec pgactive-smoke-node2 psql -U postgres -d postgres -Atc \
  "SELECT id FROM inventory.products ORDER BY id;"
```

Expected rows:

```text
node1-conditioner
node1-serum
node1-shampoo
node1-soap
node2-lotion
```

## Cleanup

```sh
docker rm -f pgactive-smoke-node1 pgactive-smoke-node2
docker network rm pgactive-smoke-net
```
