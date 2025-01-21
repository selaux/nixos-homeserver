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
      listen = [
        { addr = "0.0.0.0"; port = 80; }
        { addr = "[::0]"; port = 80; }
        { addr = "0.0.0.0"; ssl = true; port = 443; }
        { addr = "[::0]"; ssl = true; port = 443; }
        { addr = "0.0.0.0"; proxyProtocol = true; ssl = true; port = 444; }
        { addr = "[::0]"; proxyProtocol = true; ssl = true; port = 444; }
      ];
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
      listen = [
        { addr = "0.0.0.0"; port = 80; }
        { addr = "[::0]"; port = 80; }
        { addr = "0.0.0.0"; ssl = true; port = 443; }
        { addr = "[::0]"; ssl = true; port = 443; }
        { addr = "0.0.0.0"; proxyProtocol = true; ssl = true; port = 444; }
        { addr = "[::0]"; proxyProtocol = true; ssl = true; port = 444; }
      ];
      globalRedirect = builtins.head (builtins.attrNames (lib.filterAttrs (n: v: v.primary && v.proxyTo == "nextcloud") config.homeserver.hostnames));
    } // (sslValues n v)))
    hostnames);
in
{
  networking.firewall.allowedTCPPorts = [ 80 81 443 444 8096 ];

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
    commonHttpConfig = ''
      set_real_ip_from 127.0.0.1;
      real_ip_header proxy_protocol;
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
