# postgres-18

A pinned PostgreSQL 18 OCI image. **One image** to run the same postgres on both
NixOS (`oci-containers`) and non-NixOS (docker/podman).

- PostgreSQL 18 (pinned to `release-26.05` nixpkgs via `flake.lock`)
- Extensions: `pgvector`, `pg_rational`, `timescaledb` (TimescaleDB is preloaded via `shared_preload_libraries`)
- Connection settings: `listen_addresses = '*'`, `host all all 0.0.0.0/0 trust`

> ⚠️ Authentication defaults to `trust` (no password). For trusted private networks only. Do not expose to the internet.

## Files

| File | Purpose |
|---|---|
| `flake.nix` | OCI image definition (`packages.<system>.container`) — postgres package + entrypoint. |
| `.github/workflows/postgres-18.yml` | Build per-arch images and push to GHCR. |

## Image

- Lightweight image based on `dockerTools.buildLayeredImage` (no systemd required)
- On first start the entrypoint runs `initdb`, applies `postgresql.conf`/`pg_hba.conf`,
  then drops privileges to the `postgres` user before exec'ing the server
- Data directory: `/var/lib/postgresql/data` (overridable via the `PGDATA` env var)
- Locale: the cluster is initialized with `en_US.utf8` (matching the official postgres image; a minimal glibc locale archive is bundled)
- Exposed port: `5432`

### Published tags

Images are published to GHCR with a per-architecture tag. (No combined `latest` manifest.)

```
ghcr.io/aca/containers/postgres-18:latest-amd64
ghcr.io/aca/containers/postgres-18:latest-arm64
```

On a push to `main` touching `postgres-18/**` (or a manual `workflow_dispatch`),
`amd64` builds on `ubuntu-24.04` and `arm64` on `ubuntu-24.04-arm` — **native runners**.

> The package is created private on the first push. To make it public, change the
> visibility in the GitHub package settings. Free `arm64` runners are only free on public repos.

## Usage

### 1. non-NixOS (docker / podman)

Mount `/var/lib/postgresql/data` as a volume to persist data.

```sh
docker run -d --name postgres-18 \
  -p 5432:5432 \
  -v pgdata:/var/lib/postgresql/data \
  ghcr.io/aca/containers/postgres-18:latest-amd64
```

To use a host directory (e.g. a dedicated disk):

```sh
docker run -d --name postgres-18 \
  -p 5432:5432 \
  -v /mnt/pgdata:/var/lib/postgresql/data \
  ghcr.io/aca/containers/postgres-18:latest-amd64
```

No `privileged` needed. Runs as-is on plain docker/podman.

### 2. NixOS — run the GHCR image as a service (`oci-containers`, recommended)

Instead of importing this repo as a flake, **pull the published image** and run it as a
service. `virtualisation.oci-containers` turns the container into a systemd service
(`podman-postgres-18.service`) that starts/restarts automatically on boot.

```nix
{ ... }:
{
  virtualisation.oci-containers = {
    # backend = "podman"; # or "docker"
    containers.postgres-18 = {
      image = "ghcr.io/aca/containers/postgres-18:latest-amd64";
      ports = [ "5432:5432" ];
      volumes = [ "/mnt/pgdata:/var/lib/postgresql/data" ]; # disk mount
    };
  };

  # Open the firewall if external clients need to connect (private network only)
  networking.firewall.allowedTCPPorts = [ 5432 ];
}
```

Running `nixos-rebuild switch` makes podman pull the image and start the service.

#### Disk mount (data persistence)

`volumes` bind-mounts the host path `/mnt/pgdata` to the container's data directory
`/var/lib/postgresql/data`. To use a **dedicated disk**, mount it on the host first.

```nix
{
  # Mount the dedicated disk on the host first
  fileSystems."/mnt/pgdata" = {
    device = "/dev/disk/by-label/pgdata";
    fsType = "ext4";
  };
}
```

You don't need to worry about the mount directory's ownership — the container entrypoint
starts as root, `chown`s `PGDATA` to the `postgres` user, then drops privileges.

#### Pinning a version (optional)

The `latest-amd64` tag is not automatically re-pulled by podman when its contents change.
For reproducible deployments, pin by digest.

```nix
image = "ghcr.io/aca/containers/postgres-18@sha256:<digest>";
```

> Find the digest with `docker buildx imagetools inspect ghcr.io/aca/containers/postgres-18:latest-amd64`
> or `skopeo inspect docker://...`.

## Local build / test

```sh
# Build the image for the current arch (output is ./result, a gzipped OCI tar)
nix build ./postgres-18#container

# Load and run
docker load < result
docker run -d --name pg -p 5432:5432 postgres-18:latest

# Verify extensions
docker exec pg psql -U postgres -c \
  "create extension vector; create extension timescaledb; create extension pg_rational;"
```
