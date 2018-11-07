{ config, lib, pkgs, ... }: let
    secrets = import ./lib/secrets.nix;
    bootstrapPostgres = pkgs: pkgs.writeScriptBin "bootstrap-postgresql" ''
        RETRIES=5

        until ${pkgs.sudo}/bin/sudo -u postgres ${pkgs.postgresql_10}/bin/psql -d postgres -c "" 2> /dev/null || [ $RETRIES -eq 0 ]; do
            echo "Waiting for postgres server, $((RETRIES--)) remaining attempts..."
            sleep 5
        done

        ${pkgs.sudo}/bin/sudo -u postgres ${pkgs.postgresql_10}/bin/createuser nextcloud || echo "Error, probably user already exists";
        ${pkgs.sudo}/bin/sudo -u postgres ${pkgs.postgresql_10}/bin/createdb nextcloud || echo "Error, probably db already exists";

        ${pkgs.sudo}/bin/sudo -u postgres ${pkgs.postgresql_10}/bin/psql -c "ALTER USER nextcloud WITH PASSWORD '${secrets.getBash "postgresql/nextcloud"}'";
        ${pkgs.sudo}/bin/sudo -u postgres ${pkgs.postgresql_10}/bin/psql -c "ALTER DATABASE nextcloud OWNER TO nextcloud";
    '';
in {
    containers.postgresql = {
        autoStart = true;
        privateNetwork = false;
        bindMounts = {
            "/var/lib/postgresql" = {
                hostPath = "/var/lib/postgresql";
                isReadOnly = false;
            };
        }  // (secrets.mountSecrets lib [
            "postgresql"
        ]);
        config = { pkgs, lib, ... }: let
                bootstapScript = bootstrapPostgres pkgs;
            in {
            time.timeZone = config.homeserver.timeZone;
            system.stateVersion = config.system.stateVersion;

            environment.systemPackages = [
                bootstapScript
            ];

            services.postgresql = {
                enable = true;
                package = pkgs.postgresql_10;
                authentication = lib.mkForce ''
                    # Generated file; do not edit!
                    # TYPE  DATABASE        USER            ADDRESS                 METHOD
                    local   all             all                                     trust
                    host    all             all             127.0.0.1/32            password
                    host    all             all             ::1/128                 password
                '';
            };

            systemd.services.postgresql.postStart = ''
                ${bootstapScript}/bin/bootstrap-postgresql
            '';
        };
    };

    system.activationScripts = {
        postgres = {
            text = ''
                mkdir -p /var/lib/postgresql;
            '';
            deps = [];
        };
    };
}