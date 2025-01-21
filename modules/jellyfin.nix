{ config, lib, pkgs, ... }:
let
  domains = builtins.attrNames config.homeserver.hostnames;
  isPrimaryNextcloudDomain = d: config.homeserver.hostnames.${d}.primary && config.homeserver.hostnames.${d}.proxyTo == "nextcloud";
  primaryDomain = lib.findFirst isPrimaryNextcloudDomain null domains;
in
{
  virtualisation.oci-containers.containers.jellyfin = {
    autoStart = true;
    image = "lscr.io/linuxserver/jellyfin:amd64-${pkgs.jellyfin.version}";
    volumes = ["/var/lib/jellyfin:/config"] ++ map (d: "${d}:${d}:ro") config.homeserver.jellyfin.mediaDirs; 
    extraOptions = ["--device=/dev/dri/card0:/dev/dri/card0" "--device=/dev/dri/renderD128:/dev/dri/renderD128"];
    ports = ["8096:8096"];
    environment = { "PUID" = "777"; "PGID" = "777"; };
  };

  users.users.jellyfin = {
    uid = 777;
    group = "jellyfin";
    isSystemUser = true;
  };
  users.groups.jellyfin = {
      gid = 777;
  };
  users.groups.video = {
    members = ["jellyfin"];
  };
  users.groups.render = {
    members = ["jellyfin"];
  };

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
}
