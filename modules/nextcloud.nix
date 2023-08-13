{ config, lib, pkgs, ... }:
let
  domains = builtins.attrNames config.homeserver.hostnames;
  isPrimaryNextcloudDomain = d: config.homeserver.hostnames.${d}.primary && config.homeserver.hostnames.${d}.proxyTo == "nextcloud";
  primaryDomain = lib.findFirst isPrimaryNextcloudDomain null domains;
  cfg = config;
  customPHP = pkgs.php81.buildEnv {
    extensions = { enabled, all }: (lib.unique (enabled ++ [ all.opcache all.redis all.apcu all.imagick ]));
    extraConfig = ''
      memory_limit = 4096M

      [opcache]
      opcache.enable=1
      opcache.enable_cli=1
      opcache.interned_strings_buffer=8
      opcache.max_accelerated_files=10000
      opcache.memory_consumption=512
      opcache.save_comments=1
      opcache.revalidate_freq=1

      [apc]
      apc.enable_cli=1
    '';

  };
  nextcloudPackage = pkgs.nextcloud27;
  occ = pkgs.stdenv.mkDerivation {
    name = "occ";
    src = nextcloudPackage;
    buildInputs = [ pkgs.makeWrapper ];
    buildPhase = ''true'';
    installPhase = ''
      mkdir -p $out/bin
      makeWrapper ${customPHP}/bin/php $out/bin/.occ-needs-sudo --add-flags "/var/lib/nextcloud/root/occ" \
          --set NEXTCLOUD_CONFIG_DIR "/var/lib/nextcloud/config"
      makeWrapper ${pkgs.sudo}/bin/sudo $out/bin/occ --add-flags "-u nginx $out/bin/.occ-needs-sudo"
    '';
  };
  cron = pkgs.stdenv.mkDerivation {
    name = "nexcloud-cron";
    src = nextcloudPackage;
    buildInputs = [ pkgs.makeWrapper ];
    buildPhase = ''true'';
    installPhase = ''
      mkdir -p $out/bin
      makeWrapper ${customPHP}/bin/php $out/bin/.nextcloud-cron-needs-sudo --add-flags "/var/lib/nextcloud/root/cron.php" \
          --set NEXTCLOUD_CONFIG_DIR "/var/lib/nextcloud/config"
      makeWrapper ${pkgs.sudo}/bin/sudo $out/bin/nextcloud-cron --add-flags "-u nginx $out/bin/.nextcloud-cron-needs-sudo"
    '';
  };
  cronThumbnails = pkgs.stdenv.mkDerivation {
    name = "nexcloud-cron-thumbnails";
    src = occ;
    buildInputs = [ pkgs.makeWrapper ];
    buildPhase = ''true'';
    installPhase = ''
      mkdir -p $out/bin
      makeWrapper ${occ}/bin/occ $out/bin/nextcloud-cron-thumbnails --add-flags "preview:pre-generate"
    '';
  };
  cronAppUpdates = pkgs.stdenv.mkDerivation {
    name = "nexcloud-cron-app-updates";
    src = occ;
    buildInputs = [ pkgs.makeWrapper ];
    buildPhase = ''true'';
    installPhase = ''
      mkdir -p $out/bin
      makeWrapper ${occ}/bin/occ $out/bin/nextcloud-cron-app-updates --add-flags "app:update --all"
    '';
  };
  nextcloudBorg = pkgs.stdenv.mkDerivation {
    name = "nextcloud-borg";
    src = pkgs.borgbackup;
    buildInputs = [ pkgs.makeWrapper ];
    buildPhase = ''true'';
    installPhase = ''
      mkdir -p $out/bin
      makeWrapper ${pkgs.borgbackup}/bin/borg $out/bin/nextcloud-borg \
          --set BORG_REPO "${cfg.homeserver.borgRepo}" \
          --set BORG_PASSCOMMAND "cat ${secrets.getPath "backup/nextcloud"}" \
          --set BORG_RSH "ssh -i ${secrets.getPath "backup/key"} -o StrictHostKeyChecking=no"
    '';
  };
  initialConfig = pkgs.writeText "config.php" ''<?php
        $CONFIG = array(
            'apps_paths' => array(
                array(
                    'path'=> '/var/lib/nextcloud/root/apps',
                    'url' => '/apps',
                    'writable' => false,
                ),
                array(
                    'path'=> '/var/lib/nextcloud/root/apps2',
                    'url' => '/apps2',
                    'writable' => true,
                ),
            ),
            'htaccess.RewriteBase' => '/',
            'overwrite.cli.url' => 'https://${primaryDomain}',
        );
    '';
  extraConfig = pkgs.writeText "nextcloud-extra.json" ''
    {
        "system": {
            "trusted_domains": ${builtins.toJSON (builtins.attrNames cfg.homeserver.hostnames)},
            "trusted_proxies": [ "127.0.0.1" ],
            "memcache.local": "\\OC\\Memcache\\APCu",
            "memcache.distributed" => "\OC\Memcache\Redis",
            "memcache.locking" => "\OC\Memcache\Redis",
            "redis" => array(
                "host" => "localhost",
                "port" => 6379,
            ),

            "auth.bruteforce.protection.enabled": true
        }
    }
  '';
  nginxHeaders = pkgs.writeText "nginx-headers.conf" ''
    add_header Referrer-Policy                   "no-referrer"       always;
    add_header X-Content-Type-Options            "nosniff"           always;
    add_header X-Download-Options                "noopen"            always;
    add_header X-Frame-Options                   "SAMEORIGIN"        always;
    add_header X-Permitted-Cross-Domain-Policies "none"              always;
    add_header X-Robots-Tag                      "noindex, nofollow" always;
    add_header X-XSS-Protection                  "1; mode=block"     always;
  '';
  installAndEnable = app: ''
    ${occ}/bin/occ app:install ${app} || echo "Error, probably already installed";
    ${occ}/bin/occ app:enable ${app} || echo "Error, probably already enabled";
  '';
  updateConfig = ''
    ${occ}/bin/occ config:import ${extraConfig};
    ${occ}/bin/occ upgrade;
    ${occ}/bin/occ background:cron;
    ${installAndEnable "calendar"}
    ${installAndEnable "contacts"}
    ${installAndEnable "notes"}
    ${installAndEnable "bookmarks"}
    ${installAndEnable "oidc"}
    ${occ}/bin/occ app:disable activity || echo "Error, probably already disabled";
  '';
  bootstapScript = pkgs.writeScriptBin "nextcloud-bootstrap" ''
    if [ -f /var/lib/nextcloud/config/config.php ]; then
        echo "Nextcloud config already exists, skipping nextcloud bootstrap."
        ${updateConfig}
    else
        RETRIES=5
        export PGPASSWORD=${secrets.getBash "postgresql/nextcloud"};
        echo "Connecting to postgres server, $(RETRIES) remaining attempts..."
        until ${pkgs.postgresql_13}/bin/psql -h 127.0.0.1 -U nextcloud -d nextcloud -c "" 2> /dev/null || [ $RETRIES -eq 0 ]; do
            echo "Waiting for postgres server, $((RETRIES--)) remaining attempts..."
            sleep 5
        done
        sleep 10

        ${pkgs.sudo}/bin/sudo -u nginx cp -f ${initialConfig} /var/lib/nextcloud/config/config.php;
        chmod 660 /var/lib/nextcloud/config/config.php;

        ${occ}/bin/occ maintenance:install \
            --database pgsql \
            --database-name nextcloud \
            --database-user nextcloud \
            --database-pass ${secrets.getBash "postgresql/nextcloud"} \
            --admin-user ${secrets.getBash "initial/user"} \
            --admin-pass ${secrets.getBash "initial/password"} \
            --data-dir /var/lib/nextcloud/data;

        ${updateConfig}
    fi
  '';
  backupDbScript = pkgs.writeScriptBin "nextcloud-backup-db" ''
    export PGPASSWORD=${secrets.getBash "postgresql/nextcloud"};
    ${pkgs.postgresql_13}/bin/pg_dump -h 127.0.0.1 -U nextcloud --clean --if-exists -f /mnt/db/nextcloud.sql nextcloud
  '';
  restoreDbScript = pkgs.writeScriptBin "nextcloud-restore-db" ''
    export PGPASSWORD=${secrets.getBash "postgresql/nextcloud"};
    ${pkgs.postgresql_13}/bin/psql -h 127.0.0.1 -U nextcloud < /mnt/db/nextcloud.sql
  '';
  restoreNextcloudScript = pkgs.writeScriptBin "nextcloud-restore" ''
    set -e

    ${pkgs.nixos-container}/bin/nixos-container run nextcloud -- occ maintenance:mode --on
    sleep 15

    cd /
    ${nextcloudBorg}/bin/nextcloud-borg extract ::$1
    ${pkgs.nixos-container}/bin/nixos-container run nextcloud -- ${restoreDbScript}/bin/nextcloud-restore-db

    ${pkgs.nixos-container}/bin/nixos-container run nextcloud -- occ maintenance:mode --off
  '';
  secrets = import ./lib/secrets.nix;
in
{
  imports = [
    ./redis.nix
    ./postgresql.nix
  ];

  containers.nextcloud = {
    autoStart = true;
    privateNetwork = false;
    bindMounts = {
      "/mnt/data" = {
        hostPath = "/var/lib/nextcloud/data";
        isReadOnly = false;
      };
      "/mnt/config" = {
        hostPath = "/var/lib/nextcloud/config";
        isReadOnly = false;
      };
      "/var/lib/nextcloud/root/apps2" = {
        hostPath = "/var/lib/nextcloud/apps";
        isReadOnly = false;
      };
      "/mnt/db" = {
        hostPath = "/var/lib/nextcloud/db";
        isReadOnly = false;
      };
      "/etc/resolv.conf" = {
        hostPath = "/etc/resolv.conf";
        isReadOnly = true;
      };
    } // (secrets.mountSecrets lib [
      "initial/user"
      "initial/password"
      "postgresql/nextcloud"
    ]);
    config = { config, pkgs, lib, ... }: {
      time.timeZone = cfg.homeserver.timeZone;
      system.stateVersion = cfg.system.stateVersion;
      boot.tmp.useTmpfs = true;

      services.nginx = {
        enable = true;
        recommendedGzipSettings = true;
        recommendedOptimisation = true;
        clientMaxBodySize = "512M";
        appendHttpConfig = ''
          fastcgi_cache_path /tmp/nginx-cache levels=1:2 keys_zone=NEXTCLOUD:10m max_size=512M inactive=336h use_temp_path=off;
          fastcgi_cache_key "$scheme$request_method$host$request_uri";

          server_names_hash_bucket_size 64;

          # Set the `immutable` cache control options only for assets with a cache busting `v` argument
          map $arg_v $asset_immutable {
              "" "";
              default "immutable";
          }
        '';
        upstreams = {
          "php-handler" = {
            servers = {
              "unix:${config.services.phpfpm.pools.www.socket}" = {
                backup = false;
              };
            };
          };
        };
        virtualHosts = {
          "none" = {
            default = true;
            root = "/var/lib/nextcloud/root";
            listen = [
              { addr = "127.0.0.1"; port = 8080; }
            ];
            extraConfig = ''
              include ${nginxHeaders};

              index index.php index.html /index.php$request_uri;

              location = / {
                if ( $http_user_agent ~ ^DavClnt ) {
                  return 302 /remote.php/webdav/$is_args$args;
                }
              }

              location = /robots.txt {
                allow all;
                log_not_found off;
                access_log off;
              }

              # Make a regex exception for `/.well-known` so that clients can still
              # access it despite the existence of the regex rule
              # `location ~ /(\.|autotest|...)` which would otherwise handle requests
              # for `/.well-known`.
              location ^~ /.well-known {
                # The rules in this block are an adaptation of the rules
                # in `.htaccess` that concern `/.well-known`.

                location = /.well-known/carddav { return 301 https://$host/remote.php/dav/; }
                location = /.well-known/caldav  { return 301 https://$host/remote.php/dav/; }
                location = /.well-known/webfinger  { return 301 https://$host/index.php$request_uri; }
                location = /.well-known/nodeinfo  { return 301 https://$host/index.php$request_uri; }

                location /.well-known/acme-challenge    { try_files $uri $uri/ =404; }
                location /.well-known/pki-validation    { try_files $uri $uri/ =404; }

                # Let Nextcloud's API for `/.well-known` URIs handle all other
                # requests by passing them to the front-end controller.
                return 301 https://$host/index.php$request_uri;
              }

              location ~ ^/(?:build|tests|config|lib|3rdparty|templates|data)(?:$|/)  { return 404; }
              location ~ ^/(?:\.|autotest|occ|issue|indie|db_|console)                { return 404; }

              # Ensure this block, which passes PHP files to the PHP process, is above the blocks
              # which handle static assets (as seen below). If this block is not declared first,
              # then Nginx will encounter an infinite rewriting loop when it prepends `/index.php`
              # to the URI, resulting in a HTTP 500 error response.
              location ~ \.php(?:$|/) {
                  # Required for legacy support
                  rewrite ^/(?!index|remote|public|cron|core\/ajax\/update|status|ocs\/v[12]|updater\/.+|oc[ms]-provider\/.+|.+\/richdocumentscode\/proxy) /index.php$request_uri;

                  fastcgi_split_path_info ^(.+?\.php)(/.*)$;
                  set $path_info $fastcgi_path_info;

                  try_files $fastcgi_script_name =404;

                  include ${pkgs.nginx}/conf/fastcgi_params;
                  fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
                  fastcgi_param PATH_INFO $path_info;
                  fastcgi_param HTTPS on;

                  fastcgi_param modHeadersAvailable true;         # Avoid sending the security headers twice
                  fastcgi_param front_controller_active true;     # Enable pretty urls
                  fastcgi_pass php-handler;

                  fastcgi_intercept_errors on;
                  fastcgi_request_buffering off;

                  fastcgi_max_temp_file_size 0;
                  fastcgi_cache NEXTCLOUD;
              }

              location ~ \.(?:css|js|svg|gif|png|jpg|ico|wasm|tflite|map)$ {
                try_files $uri /index.php$request_uri;
                add_header Cache-Control "public, max-age=15778463, $asset_immutable";
                access_log off;     # Optional: Don't log access to assets

                location ~ \.wasm$ {
                  default_type application/wasm;
                }
              }

              location ~ \.woff2?$ {
                try_files $uri /index.php$request_uri;
                expires 7d;         # Cache-Control policy borrowed from `.htaccess`
                access_log off;     # Optional: Don't log access to assets
              }

              # Rule borrowed from `.htaccess`
              location /remote {
                return 301 /remote.php$request_uri;
              }

              location / {
                try_files $uri $uri/ /index.php$request_uri;
              }
            '';
          };
        };
      };
      users.users.nginx = {
        useDefaultShell = true;
      };
      systemd.services.nginx.postStart = ''
        ${bootstapScript}/bin/nextcloud-bootstrap
      '';

      services.phpfpm.phpPackage = customPHP;
      services.phpfpm.pools = {
        www = {
          user = "nginx";
          group = "nginx";
          phpPackage = customPHP;
          phpEnv = {
            NEXTCLOUD_CONFIG_DIR = "/var/lib/nextcloud/config";
            PATH = "/run/current-system/sw/bin/";
            TMP = "/tmp";
            TMPDIR = "/tmp";
            TEMP = "/tmp";
          };
          settings = {
            "pm" = "dynamic";
            "pm.max_children" = 50;
            "pm.start_servers" = 10;
            "pm.min_spare_servers" = 10;
            "pm.max_spare_servers" = 20;
            "pm.max_requests" = 100;
            "php_admin_value[display_errors]" = "Off";
            "php_admin_value[session.save_path]" = "/var/lib/nextcloud/sessions";
            "php_admin_value[session.save_handler]" = "files";
            "listen.owner" = "nginx";
            "listen.group" = "nginx";
          };
        };
      };

      environment.systemPackages = [
        occ
        cron
        cronThumbnails
        cronAppUpdates
        bootstapScript
        backupDbScript
        restoreDbScript
        pkgs.nodejs-18_x
      ];

      services.cron = {
        enable = true;
        systemCronJobs = [
          "*/10 * * * * root ${cron}/bin/nextcloud-cron"
          "*/10 * * * * root ${cronThumbnails}/bin/nextcloud-cron-thumbnails"
          "0    2 * * * root ${cronAppUpdates}/bin/nextcloud-cron-app-updates"
        ];
      };

      system.activationScripts = {
        mnt = {
          text = ''
            find /var/lib/nextcloud/root -mindepth 1 -maxdepth 1 -a ! -name 'apps2' \
                -exec rm -rf {} \;

            mkdir -p /var/lib/nextcloud/root;
            mkdir -p /var/lib/nextcloud/sessions;
            mkdir -p /tmp/nextcloud;
            mkdir -p /tmp/nginx-cache;
            chown -R nginx:nginx /tmp/nginx-cache

            cp -r ${nextcloudPackage}/. /var/lib/nextcloud/root
            ln -s /mnt/config /var/lib/nextcloud/config
            ln -s /mnt/data /var/lib/nextcloud/data

            chown -R nginx:nginx /var/lib/nextcloud
            chown -R nginx:nginx /tmp/nextcloud
          '';
          deps = [ ];
        };
      };
    };
  };

  system.activationScripts = {
    nextcloud = {
      text = ''
        mkdir -p /var/lib/nextcloud/apps;
        mkdir -p /var/lib/nextcloud/data;
        mkdir -p /var/lib/nextcloud/config;
        mkdir -p /var/lib/nextcloud/db;

        chown -R nginx:nginx /var/lib/nextcloud
      '';
      deps = [ ];
    };
  };

  environment.systemPackages = [
    nextcloudBorg
    restoreNextcloudScript
  ];

  services.borgbackup.jobs.nextcloud = {
    encryption = {
      mode = "repokey";
      passCommand = "cat ${secrets.getPath "backup/nextcloud"}";
    };
    environment = {
      BORG_RSH = "ssh -i ${secrets.getPath "backup/key"} -o StrictHostKeyChecking=no";
    };
    paths = [ "/var/lib/nextcloud" ];
    repo = cfg.homeserver.borgRepo;
    preHook = ''
      ${pkgs.nixos-container}/bin/nixos-container run nextcloud -- occ maintenance:mode --on
      sleep 15
      ${pkgs.nixos-container}/bin/nixos-container run nextcloud -- ${backupDbScript}/bin/nextcloud-backup-db
    '';
    postHook = ''
      ${pkgs.nixos-container}/bin/nixos-container run nextcloud -- occ maintenance:mode --off
    '';
  };
}
