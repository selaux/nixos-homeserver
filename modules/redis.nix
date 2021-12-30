{ config, lib, pkgs, ... }: {
  containers.redis = {
    autoStart = true;
    privateNetwork = false;
    bindMounts = {
      "/etc/resolv.conf" = {
        hostPath = "/etc/resolv.conf";
        isReadOnly = true;
      };
    };
    config = { pkgs, lib, ... }: {
      system.stateVersion = config.system.stateVersion;
      time.timeZone = config.homeserver.timeZone;

      services.redis = {
        enable = true;
        bind = "127.0.0.1";
      };
    };
  };
}
