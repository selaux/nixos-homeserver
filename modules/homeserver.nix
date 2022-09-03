{ config, lib, pkgs, ... }: {
  imports = [
    ./load-balancer.nix
    ./nextcloud.nix
    ./samba.nix
    ./jellyfin.nix
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
          proxyTo = mkOption {
            type = types.enum [
              "nextcloud"
              "jellyfin"
            ];
            description = "Where to proxy the hostname to.";
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

      jellyfin = mkOption {
        type = types.submodule {
          options = {
            clientID = mkOption {
              type = types.str;
              description = "OIDC client id to use for OIDC proxy for jellyfin";
            };
            clientSecret = mkOption {
              type = types.str;
              description = "OIDC client secret to use for OIDC proxy for jellyfin";
            };
            cookieSecret = mkOption {
              type = types.str;
              description = "Cookie secret to use for OIDC proxy for jellyfin";
            };
            mediaDirs = mkOption {
              type = types.listOf types.str;
              description = "Media directories for jellyfin";
            };
          };
        };
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
