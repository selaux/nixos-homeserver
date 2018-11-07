{
    network.description = "Homeserver";
    homeserver = { lib, pkgs, ... }: {
        imports = [
            ../modules/homeserver.nix
        ];

        system.stateVersion = "18.09";
        homeserver = {
            timeZone = "Europe/Berlin";
            hostnames = {
                "homeserver-test" = {
                    acme = false;
                };
            };
            secondaryHostnames = {};
            borgRepo = "ssh://u178698@u178698.your-storagebox.de:23/./backup/nextcloud";
        };
    };
}