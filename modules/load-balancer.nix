{ config, lib, pkgs, ... }:
let
  secrets = import ./lib/secrets.nix;
  sslValues = n: v:
    if v.acme then {
      enableACME = true;
      acmeRoot = "/var/lib/acme/${n}";
    } else {
      sslCertificate = secrets.getPath "nginx/cert/cert.pem";
      sslCertificateKey = secrets.getPath "nginx/cert/key.pem";
    };
  proxyPass = hostnames: (lib.mapAttrs'
    (n: v: lib.nameValuePair n ({
      forceSSL = true;
      locations = {
        "/" = {
          proxyPass = "http://127.0.0.1:${if v.proxyTo == "nextcloud" then "8080" else "4180"}";
        };
      };
    } // (sslValues n v)))
    hostnames);
  redirect = hostnames: (lib.mapAttrs'
    (n: v: lib.nameValuePair n ({
      forceSSL = true;
      globalRedirect = builtins.head (builtins.attrNames (lib.filterAttrs (n: v: v.primary && v.proxyTo == "nextcloud") config.homeserver.hostnames));
    } // (sslValues n v)))
    hostnames);
in
{
  networking.firewall.allowedTCPPorts = [ 80 443 8096 ];

  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    clientMaxBodySize = "512M";
    appendHttpConfig = ''
      server_names_hash_bucket_size 64;
    '';
    virtualHosts = {
      "none" = {
        forceSSL = true;
        default = true;
        sslCertificate = secrets.getPath "nginx/cert/cert.pem";
        sslCertificateKey = secrets.getPath "nginx/cert/key.pem";
      };
    } // (proxyPass config.homeserver.hostnames) // (redirect config.homeserver.secondaryHostnames);
  };
}
