{ config, lib, pkgs, ... }: {
    imports = [
        ./load-balancer.nix
        ./nextcloud.nix
    ];

    options = with lib; {
        homeserver = {
            timeZone = mkOption {
                type = types.str;
                description = "Timezone the server is in.";
            };

            hostnames = mkOption {
                type = types.listOf types.str;
            };
        };
    };

    config = {
        time.timeZone = config.homeserver.timeZone;
    };
}