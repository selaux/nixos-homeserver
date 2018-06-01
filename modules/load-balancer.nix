{ config, lib, pkgs, ... }: let
    proxyPass = hostnames: lib.listToAttrs (map (n: lib.nameValuePair n {
                # enableACME = true;
                # acmeRoot = "/var/lib/acme/acme-${cfg.domain}";
                # forceSSL = true;
        locations = {
            "/" = {
                proxyPass = "http://127.0.0.1:8080";
            };
        };
    }) hostnames);
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
            # "schelling30.com" = {
            #     # enableACME = true;
            #     # acmeRoot = "/var/lib/acme/acme-${cfg.domain}";
            #     # forceSSL = true;
            #     globalRedirect = "www.schelling30.com";
            # };
        } // (proxyPass config.homeserver.hostnames);
    };
}