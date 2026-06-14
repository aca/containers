{
  description = "Pinned postgres 18 as an OCI image (pgvector, pg_rational, timescaledb)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/release-26.05";

  outputs = { nixpkgs, ... }:
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
          postgresql = pkgs.postgresql_18.withPackages (ps: [
            ps.pgvector
            ps.pg_rational
            ps.timescaledb
          ]);

          postgresqlConf = pkgs.writeText "postgresql.conf" ''
            shared_preload_libraries = 'timescaledb'
            listen_addresses = '*'
          '';

          pgHbaConf = pkgs.writeText "pg_hba.conf" ''
            local all all trust
            host  all all 0.0.0.0/0 trust
          '';

          entrypoint = pkgs.writeShellApplication {
            name = "entrypoint";
            runtimeInputs = [ postgresql pkgs.coreutils pkgs.su-exec ];
            text = ''
              PGDATA="''${PGDATA:-/var/lib/postgresql/data}"

              mkdir -p "$PGDATA" /run/postgresql
              chown postgres:postgres "$PGDATA" /run/postgresql

              if [ ! -s "$PGDATA/PG_VERSION" ]; then
                su-exec postgres initdb -U postgres --encoding=UTF8 "$PGDATA"
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
            '';
            config = {
              Entrypoint = [ "${entrypoint}/bin/entrypoint" ];
              ExposedPorts = { "5432/tcp" = { }; };
              Volumes = { "/var/lib/postgresql/data" = { }; };
              Env = [ "PGDATA=/var/lib/postgresql/data" ];
            };
          };
        });
    };
}
