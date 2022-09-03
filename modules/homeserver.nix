{ config, lib, pkgs, ... }: {
  imports = [
    ./load-balancer.nix
    ./nextcloud.nix
    ./samba.nix
  ];

  options = with lib; let
    hostnamesOption = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          acme = mkOption {
            type = types.bool;
            description = "Get certificate via ACME on startup else use self-signed.";
          };
          primary = mkOption {
            type = types.bool;
            description = "Is this the primary hostname that secondary hostnames should be redirected to?";
            default = false;
          };
        };
      });
    };
  in
  {
    homeserver = {
      timeZone = mkOption {
        type = types.str;
        description = "Timezone the server is in.";
      };

      hostnames = hostnamesOption;
      secondaryHostnames = hostnamesOption;
      smbShare = mkOption {
        type = types.str;
        description = "A smb share directory provided within the local network";
      };

      borgRepo = mkOption {
        type = types.str;
        description = "Borg repository where backups are stored.";
      };
    };
  };

  config = {
    time.timeZone = config.homeserver.timeZone;
  };
}
