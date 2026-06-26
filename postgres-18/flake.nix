{
  description = "Pinned postgres 18 as an OCI image (pgvector, pg_rational, timescaledb, pgactive)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/release-26.05";
  inputs.pgactiveSrc = {
    url = "github:aws/pgactive";
    flake = false;
  };

  outputs = { nixpkgs, pgactiveSrc, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs {
        inherit system;
        config.allowUnfree = true; # timescaledb (TSL)
      }));
    in {
      # `nix build .#container` builds for the current system; the CI matrix
      # builds one per arch and pushes :latest-amd64 / :latest-arm64.
      packages = forAllSystems (pkgs:
        let
          postgresql = pkgs.postgresql_18.withPackages (ps:
            let
              pgactive = ps.callPackage (
                {
                  autoconf,
                  lib,
                  libkrb5,
                  libxslt,
                  lz4,
                  numactl,
                  pam,
                  pkg-config,
                  postgresql,
                  postgresqlBuildExtension,
                  readline,
                  zlib,
                  zstd,
                }:
                postgresqlBuildExtension {
                  pname = "pgactive";
                  version = "2.1.8";

                  src = pgactiveSrc;

                  nativeBuildInputs = [
                    autoconf
                    pkg-config
                  ];

                  buildInputs = postgresql.buildInputs ++ [
                    libkrb5
                    libxslt
                    lz4
                    numactl
                    pam
                    readline
                    zlib
                    zstd
                  ];

                  preConfigure = ''
                    echo "${pgactiveSrc.shortRev}" > .distgitrev
                  '';

                  configureFlags = [
                    "PG_CONFIG=${postgresql.pg_config}/bin/pg_config"
                  ];

                  makeFlags = [
                    "LIBRARY_PATH=${postgresql}/lib"
                  ];

                  meta = {
                    description = "Active-active replication extension for PostgreSQL";
                    homepage = "https://github.com/aws/pgactive";
                    platforms = postgresql.meta.platforms;
                    license = lib.licenses.postgresql;
                  };
                }
              ) { };
            in [
              ps.pgvector
              ps.pg_rational
              ps.timescaledb
              pgactive
            ]);

          # Minimal glibc locale archive (just en_US.UTF-8) — the scratch image
          # has no system locales, so initdb would otherwise fall back to "C".
          locales = pkgs.glibcLocales.override {
            allLocales = false;
            locales = [ "en_US.UTF-8/UTF-8" ];
          };

          postgresqlConf = pkgs.writeText "postgresql.conf" ''
            shared_preload_libraries = 'timescaledb,pgactive'
            listen_addresses = '*'
            wal_level = logical
            track_commit_timestamp = on
            max_worker_processes = 20
            max_wal_senders = 20
            max_replication_slots = 20
            max_logical_replication_workers = 20
            # Enable pgactive DDL replication. Must be identical on every node in
            # the group, otherwise a node can't join / pgactive workers won't start.
            pgactive.skip_ddl_replication = false
          '';

          pgHbaConf = pkgs.writeText "pg_hba.conf" ''
            local all all trust
            host  all all 0.0.0.0/0 trust
            local replication all         trust
            host  replication all 0.0.0.0/0 trust
          '';

          entrypoint = pkgs.writeShellApplication {
            name = "entrypoint";
            runtimeInputs = [ postgresql pkgs.coreutils pkgs.su-exec ];
            text = ''
              PGDATA="''${PGDATA:-/var/lib/postgresql/data}"

              mkdir -p "$PGDATA" /run/postgresql
              chown postgres:postgres "$PGDATA" /run/postgresql

              if [ ! -s "$PGDATA/PG_VERSION" ]; then
                su-exec postgres initdb -U postgres --locale=en_US.utf8 "$PGDATA"
              fi

              install -m 600 -o postgres -g postgres ${postgresqlConf} "$PGDATA/postgresql.conf"
              install -m 600 -o postgres -g postgres ${pgHbaConf} "$PGDATA/pg_hba.conf"

              exec su-exec postgres postgres -D "$PGDATA"
            '';
          };
        in {
          container = pkgs.dockerTools.buildLayeredImage {
            name = "postgres-18";
            tag = "latest";
            contents = [ postgresql pkgs.bashInteractive pkgs.coreutils ];
            enableFakechroot = true;
            fakeRootCommands = ''
              ${pkgs.dockerTools.shadowSetup}
              groupadd -r postgres
              useradd -r -g postgres -d /var/lib/postgresql -M postgres
              mkdir -p /var/lib/postgresql/data
              chown -R postgres:postgres /var/lib/postgresql
              mkdir -p /tmp
              chmod 1777 /tmp
            '';
            config = {
              Entrypoint = [ "${entrypoint}/bin/entrypoint" ];
              ExposedPorts = { "5432/tcp" = { }; };
              Volumes = { "/var/lib/postgresql/data" = { }; };
              Env = [
                "PGDATA=/var/lib/postgresql/data"
                "LANG=en_US.utf8"
                "LOCALE_ARCHIVE=${locales}/lib/locale/locale-archive"
              ];
            };
          };
        });
    };
}
