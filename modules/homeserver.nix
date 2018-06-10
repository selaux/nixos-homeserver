{ config, lib, pkgs, ... }: {
    imports = [
        ./load-balancer.nix
        ./nextcloud.nix
    ];

    options = with lib; let
        hostnamesOption = mkOption {
            type = types.attrsOf (types.submodule {
                options = {
                    acme = mkOption {
                        type = types.bool;
                        description = "Get certificate via ACME on startup else use self-signed.";
                    };
                };
            });
        };
    in {
        homeserver = {
            timeZone = mkOption {
                type = types.str;
                description = "Timezone the server is in.";
            };

            hostnames = hostnamesOption;
            secondaryHostnames = hostnamesOption;
        };
    };

    config = {
        time.timeZone = config.homeserver.timeZone;
    };
}