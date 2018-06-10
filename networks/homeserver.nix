{
    network.description = "Homeserver";
    homeserver = { lib, pkgs, ... }: {
        imports = [
            ../modules/homeserver.nix
        ];

        homeserver = {
            timeZone = "Europe/Berlin";
            hostnames = {
                "www.schelling30.com" = {
                    acme = true;
                };
                "nas" = {
                    acme = false;
                };
            };
            secondaryHostnames = {
                "schelling30.com" = {
                    acme = true;
                };
            };
        };
    };
}