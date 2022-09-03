{ config, lib, pkgs, ... }:
let
  domains = builtins.attrNames config.homeserver.hostnames;
  isPrimaryNextcloudDomain = d: config.homeserver.hostnames.${d}.primary && config.homeserver.hostnames.${d}.proxyTo == "nextcloud";
  primaryDomain = lib.findFirst isPrimaryNextcloudDomain null domains;
in
{
  containers.jellyfin = {
    autoStart = true;
    privateNetwork = false;
    bindMounts =  {
      "/var/lib/jellyfin" = {
        hostPath = "/var/lib/jellyfin";
        isReadOnly = false;
      };
      "/dev/dri/card0" = {
        hostPath = "/dev/dri/card0";
        isReadOnly = false;
      };
      "/dev/dri/renderD128" = {
        hostPath = "/dev/dri/renderD128";
        isReadOnly = false;
      };
      "/etc/resolv.conf" = {
        hostPath = "/etc/resolv.conf";
        isReadOnly = true;
      };
    } // lib.genAttrs config.homeserver.jellyfin.mediaDirs (dir: {
      hostPath = dir;
      isReadOnly = true;
    });
    config = { pkgs, lib, ... }: {
      time.timeZone = config.homeserver.timeZone;
      system.stateVersion = config.system.stateVersion;

      services.jellyfin = {
        enable = true;
        openFirewall = true;
      };
      systemd.services.jellyfin.serviceConfig.PrivateDevices = lib.mkForce false;

      services.oauth2_proxy = {
        enable = true;
        upstream = ["http://127.0.0.1:8096"];
        provider = "oidc";
        reverseProxy = true;
        clientID = config.homeserver.jellyfin.clientID;
        clientSecret = config.homeserver.jellyfin.clientSecret;
        cookie.secret = config.homeserver.jellyfin.cookieSecret;
        email.domains = ["*"];
        loginURL = "https://${primaryDomain}/index.php/apps/oidc/authorize";
        redeemURL = "https://${primaryDomain}/index.php/apps/oidc/token";
        extraConfig = {
          "skip-oidc-discovery" = "true";
          "insecure-oidc-skip-nonce" = "false";
          "insecure-oidc-allow-unverified-email" = "true";
          "oidc-jwks-url" = "https://${primaryDomain}/index.php/apps/oidc/jwks";
          "oidc-issuer-url" = "https://${primaryDomain}";
          "skip-provider-button" = "true";
        };
      };

      hardware.opengl = {
        enable = config.hardware.opengl.enable;
        driSupport = config.hardware.opengl.driSupport;
        extraPackages = config.hardware.opengl.extraPackages;
      };

      users.groups.video = {
        gid = config.users.groups.video.gid;
        members = ["jellyfin"];
      };
      users.groups.render = {
        gid = config.users.groups.render.gid;
        members = ["jellyfin"];
      };
    };
    # Hardware de-/encoding
    allowedDevices = [
      { modifier = "rw"; node = "/dev/dri/card0"; }
      { modifier = "rw"; node = "/dev/dri/renderD128"; }
    ];
  };
}