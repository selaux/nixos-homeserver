{
    network.description = "Homeserver";
    homeserver = { lib, pkgs, ... }: {
        imports = [
            ../modules/homeserver.nix
        ];

        homeserver = {
            timeZone = "Europe/Berlin";
            hostnames = {
                "homeserver-test" = {
                    acme = false;
                };
            };
            secondaryHostnames = {};
        };
    };
}