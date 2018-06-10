{ config, lib, pkgs, ... }: let
    sslValues = n: v: if v.acme then {
        enableACME = true;
        acmeRoot = "/var/lib/acme/acme-${n}";
    } else {
        sslCertificate = "/etc/secrets/nginx/cert/cert.pem";
        sslCertificateKey = "/etc/secrets/nginx/cert/key.pem";
    };
    proxyPass = hostnames: (lib.mapAttrs' (n: v: lib.nameValuePair n ({
        forceSSL = true;
        locations = {
            "/" = {
                proxyPass = "http://127.0.0.1:8080";
            };
        };
    } // (sslValues n v))) hostnames);
    redirect = hostnames: (lib.mapAttrs' (n: v: lib.nameValuePair n ({
        forceSSL = true;
        globalRedirect = builtins.head (builtins.attrNames config.homeserver.hostnames);
    } // (sslValues n v))) hostnames);
in {
    networking.firewall.allowedTCPPorts = [ 80 443 ];

    services.nginx = {
        enable = true;
        recommendedGzipSettings = true;
        recommendedProxySettings = true;
        recommendedTlsSettings = true;
        appendHttpConfig = ''
            server_names_hash_bucket_size 64;
        '';
        virtualHosts = {
            "none" = {
                default = true;
            };
        } // (proxyPass config.homeserver.hostnames);
    };
}