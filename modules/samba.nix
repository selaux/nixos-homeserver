{ config, lib, pkgs, ... }:
{
  networking.firewall.allowedTCPPorts = [ 139 445 ];
  networking.firewall.allowedUDPPorts = [ 137 138 5353 ];

  containers.samba = {
    autoStart = true;
    privateNetwork = false;
    bindMounts = {
      "${config.homeserver.smbShare}" = {
        hostPath = config.homeserver.smbShare;
        isReadOnly = false;
      };
    };
    config = { pkgs, lib, ... }: {
      time.timeZone = config.homeserver.timeZone;
      system.stateVersion = config.system.stateVersion;

      services.samba = {
        enable = true;
        securityType = "user";
        openFirewall = true;
        settings = {
          global = {
            "server string" = "NAS";
            "workgroup" = "WORKGROUP";

            "map to guest" = "bad user";
            "guest account" = "sambaguest";
          };
          nas = {
            "path" = config.homeserver.smbShare;
            "public" = "yes";
            "only guest" = "yes";
            "writable" = "yes";
            "printable" = "no";
            "browseable" = "yes";
            "create mask" = "0664";
            "force create mode" = "0664";
          };
        };
      };

      users.users.sambaguest = {
        createHome = false;
        useDefaultShell = true;
        isNormalUser = true;
        group = "sambaguest";
      };
      users.groups.sambaguest = {};
      systemd.tmpfiles.rules = [
        "d ${config.homeserver.smbShare} 755 sambaguest sambaguest -"
      ];
    };
  };

  system.activationScripts = {
    samba = {
      text = ''
        mkdir -p ${config.homeserver.smbShare};
      '';
      deps = [ ];
    };
  };
}