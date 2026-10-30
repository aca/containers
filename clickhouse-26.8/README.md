# clickhouse-26.8

A pinned ClickHouse OCI image built with `dockerTools.buildLayeredImage`, for
Docker, Podman, and NixOS `oci-containers`.

- ClickHouse 26.8 LTS (currently `26.8.30.8-lts`) from `nixos-unstable` nixpkgs (`clickhouse-lts`), pinned by `flake.lock`
- HTTP interface: `8123`; native protocol: `9000`
- Persistent data: `/var/lib/clickhouse`
- Logs go to the container console
- The entrypoint creates the data directory, sets its ownership, and drops
  privileges to the `clickhouse` user before starting the server
- The `default` user has no password and accepts network connections, matching
  the PostgreSQL images' trusted private network setup

> Authentication is disabled by default. Use only on trusted private networks.

## Published tags

```text
ghcr.io/aca/containers/clickhouse-26.8:latest-amd64
ghcr.io/aca/containers/clickhouse-26.8:latest-arm64
```

`.github/workflows/clickhouse-26.8.yml` builds on native `ubuntu-24.04` and
`ubuntu-24.04-arm` runners when `clickhouse-26.8/**` or the workflow changes on `main`,
or on manual dispatch. There is no combined `latest` manifest.

## Docker / Podman

```sh
docker run -d --name clickhouse \
  -p 127.0.0.1:8123:8123 -p 127.0.0.1:9000:9000 \
  -v clickhouse-data:/var/lib/clickhouse \
  ghcr.io/aca/containers/clickhouse-26.8:latest-amd64

docker exec clickhouse clickhouse client --query 'SELECT version()'
curl --fail 'http://localhost:8123/?query=SELECT%201'
```

Use `latest-arm64` on ARM hosts. A host directory such as
`/mnt/clickhouse:/var/lib/clickhouse` can replace the named volume.

## NixOS

```nix
{
  virtualisation.oci-containers.containers.clickhouse = {
    image = "ghcr.io/aca/containers/clickhouse-26.8:latest-amd64";
    ports = [ "127.0.0.1:8123:8123" "127.0.0.1:9000:9000" ];
    volumes = [ "/mnt/clickhouse:/var/lib/clickhouse" ];
  };
}
```

Mount any dedicated data disk on the host before starting the container.
Pin the image by digest for reproducible deployments.

## Query from PostgreSQL

Both PostgreSQL images include `pg_clickhouse`. Connect the containers to the
same Docker network so PostgreSQL can resolve the `clickhouse` hostname:

```sh
docker network create analytics
docker network connect analytics clickhouse
docker run -d --name postgres-clickhouse --network analytics \
  -v postgres-clickhouse-data:/var/lib/postgresql/data \
  ghcr.io/aca/containers/postgres-18:latest-amd64

docker exec clickhouse clickhouse client --multiquery --query "
  CREATE TABLE IF NOT EXISTS default.example (id Int32, name String)
  ENGINE = MergeTree ORDER BY id;
  INSERT INTO default.example VALUES (1, 'hello');"

docker exec -i postgres-clickhouse psql -U postgres -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION pg_clickhouse;
CREATE SERVER clickhouse FOREIGN DATA WRAPPER clickhouse_fdw
  OPTIONS (driver 'http', host 'clickhouse', port '8123', dbname 'default');
CREATE USER MAPPING FOR CURRENT_USER SERVER clickhouse
  OPTIONS (user 'default', password '');
CREATE FOREIGN TABLE clickhouse_example (id integer, name text)
  SERVER clickhouse OPTIONS (table_name 'example');
SELECT * FROM clickhouse_example;
SQL
```

The same SQL works with `postgres-19`. This queries data already in ClickHouse;
it does not automatically replicate PostgreSQL tables.

## Local build / test

```sh
nix build ./clickhouse-26.8#container
docker load < result
docker run -d --name clickhouse-local clickhouse-26.8:latest
docker exec clickhouse-local clickhouse client --query 'SELECT 1'
```
