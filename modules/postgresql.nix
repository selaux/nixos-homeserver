{ config, lib, pkgs, ... }:
let
  secrets = import ./lib/secrets.nix;
in
{
  containers.postgresql = {
    autoStart = true;
    privateNetwork = false;
    bindMounts = {
      "/var/lib/postgresql" = {
        hostPath = "/var/lib/postgresql";
        isReadOnly = false;
      };
    } // (secrets.mountSecrets lib [
      "postgresql"
    ]);
    config = { pkgs, lib, ... }: {
      time.timeZone = config.homeserver.timeZone;
      system.stateVersion = config.system.stateVersion;

      services.postgresql = {
        enable = true;
        package = pkgs.postgresql_13;
        settings = {
          shared_buffers = "1024MB";
        };
        authentication = lib.mkForce ''
          # Generated file; do not edit!
          # TYPE  DATABASE        USER            ADDRESS                 METHOD
          local   all             all                                     trust
          host    all             all             127.0.0.1/32            password
          host    all             all             ::1/128                 password
        '';
        ensureDatabases = [ "nextcloud" ];
        ensureUsers = [
          {
            name = "nextcloud";
            ensurePermissions = {
              "DATABASE nextcloud" = "ALL PRIVILEGES";
            };
          }
        ];
      };
    };
  };

  system.activationScripts = {
    postgres = {
      text = ''
        mkdir -p /var/lib/postgresql;
      '';
      deps = [ ];
    };
  };
}
