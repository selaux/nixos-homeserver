{ config, lib, pkgs, ... }: {
    containers.memcached = {
        autoStart = true;
        privateNetwork = false;
        config = { pkgs, lib, ... }: {
            time.timeZone = config.homeserver.timeZone;

            services.memcached = {
                enable = true;
                listen = "127.0.0.1";
                maxMemory = "128";
            };
        };
    };
}