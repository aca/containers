{
  description = "Pinned ClickHouse 26.8 as an OCI image";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));
    in {
      packages = forAllSystems (pkgs:
        let
          users = pkgs.writeText "users.xml" ''
            <clickhouse>
              <profiles>
                <default />
              </profiles>
              <users>
                <default>
                  <password></password>
                  <networks><ip>::/0</ip></networks>
                  <profile>default</profile>
                  <quota>default</quota>
                  <access_management>1</access_management>
                </default>
              </users>
              <quotas>
                <default />
              </quotas>
            </clickhouse>
          '';

          config = pkgs.writeText "config.xml" ''
            <clickhouse>
              <logger>
                <level>warning</level>
                <console>1</console>
              </logger>
              <listen_host>0.0.0.0</listen_host>
              <http_port>8123</http_port>
              <tcp_port>9000</tcp_port>
              <path>/var/lib/clickhouse/</path>
              <tmp_path>/var/lib/clickhouse/tmp/</tmp_path>
              <user_files_path>/var/lib/clickhouse/user_files/</user_files_path>
              <format_schema_path>/var/lib/clickhouse/format_schemas/</format_schema_path>
              <access_control_path>/var/lib/clickhouse/access/</access_control_path>
              <users_config>${users}</users_config>
              <default_profile>default</default_profile>
              <default_database>default</default_database>
              <!-- Keep startup thread counts independent of the host's CPU count. -->
              <background_schedule_pool_size>16</background_schedule_pool_size>
            </clickhouse>
          '';

          entrypoint = pkgs.writeShellApplication {
            name = "entrypoint";
            runtimeInputs = [ pkgs.clickhouse-lts pkgs.coreutils pkgs.su-exec ];
            text = ''
              mkdir -p /var/lib/clickhouse
              chown clickhouse:clickhouse /var/lib/clickhouse
              exec su-exec clickhouse clickhouse server --config-file=${config} "$@"
            '';
          };
        in {
          container = pkgs.dockerTools.buildLayeredImage {
            name = "clickhouse-26.8";
            tag = "latest";
            contents = [ pkgs.clickhouse-lts pkgs.cacert pkgs.bashInteractive pkgs.coreutils ];
            enableFakechroot = true;
            fakeRootCommands = ''
              ${pkgs.dockerTools.shadowSetup}
              groupadd -r clickhouse
              useradd -r -g clickhouse -d /var/lib/clickhouse -M clickhouse
              mkdir -p /var/lib/clickhouse /tmp
              chown clickhouse:clickhouse /var/lib/clickhouse
              chmod 1777 /tmp
            '';
            config = {
              Entrypoint = [ "${entrypoint}/bin/entrypoint" ];
              ExposedPorts = { "8123/tcp" = { }; "9000/tcp" = { }; };
              Volumes = { "/var/lib/clickhouse" = { }; };
              Env = [ "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" ];
            };
          };
        });
    };
}
