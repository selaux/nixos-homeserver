{ config, lib, pkgs, ... }:
let
    cfg = config;
    customPHP = pkgs.php74.buildEnv {
        extensions = { enabled, all }: (lib.unique (enabled ++ [ all.opcache all.redis all.apcu all.imagick ]));
        extraConfig = ''
            memory_limit = 2048M

            [opcache]
            opcache.enable=1
            opcache.enable_cli=1
            opcache.interned_strings_buffer=8
            opcache.max_accelerated_files=10000
            opcache.memory_consumption=256
            opcache.save_comments=1
            opcache.revalidate_freq=1

            [apc]
            apc.enable_cli=1
        '';

    };
    nextcloudPackage = pkgs.nextcloud21;
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
        src = nextcloudPackage;
        buildInputs = [ pkgs.makeWrapper ];
        buildPhase = ''true'';
        installPhase = ''
            mkdir -p $out/bin
            makeWrapper ${occ}/bin/occ $out/bin/nextcloud-cron-thumbnails --add-flags "preview:pre-generate"
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
            until ${pkgs.postgresql_10}/bin/psql -h 127.0.0.1 -U nextcloud -d nextcloud -c "" 2> /dev/null || [ $RETRIES -eq 0 ]; do
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
        ${pkgs.postgresql_10}/bin/pg_dump -h 127.0.0.1 -U nextcloud --clean --if-exists -f /mnt/db/nextcloud.sql nextcloud
    '';
    restoreDbScript = pkgs.writeScriptBin "nextcloud-restore-db" ''
        export PGPASSWORD=${secrets.getBash "postgresql/nextcloud"};
        ${pkgs.postgresql_10}/bin/psql -h 127.0.0.1 -U nextcloud < /mnt/db/nextcloud.sql
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
            boot.tmpOnTmpfs = true;

            services.nginx = {
                enable = true;
                recommendedGzipSettings = true;
                recommendedOptimisation = true;
                clientMaxBodySize = "512M";
                appendHttpConfig = ''
                    fastcgi_cache_path /tmp/nginx-cache levels=1:2 keys_zone=NEXTCLOUD:10m max_size=512M inactive=336h use_temp_path=off;
                    fastcgi_cache_key "$scheme$request_method$host$request_uri";

                    server_names_hash_bucket_size 64;
                '';
                upstreams = {
                    phpfpm = {
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
                            add_header X-Content-Type-Options nosniff;
                            add_header X-XSS-Protection "1; mode=block";
                            add_header X-Robots-Tag none;
                            add_header X-Download-Options noopen;
                            add_header X-Permitted-Cross-Domain-Policies none;
                            add_header Referrer-Policy same-origin;
                            add_header X-Frame-Options "SAMEORIGIN" always;

                            location = /.well-known/carddav {
                                return 301 $scheme://$host/remote.php/dav;
                            }
                            location = /.well-known/caldav {
                                return 301 $scheme://$host/remote.php/dav;
                            }
                            location / {
                                rewrite ^ /index.php$request_uri;
                            }

                            location ~ ^/(?:build|tests|config|lib|3rdparty|templates|data)/ {
                                deny all;
                            }
                            location ~ ^/(?:\.|autotest|occ|issue|indie|db_|console) {
                                deny all;
                            }

                            location ~ ^/(?:index|remote|public|cron|core/ajax/update|status|ocs/v[12]|updater/.+|ocs-provider/.+)\.php(?:$|/) {
                                fastcgi_split_path_info ^(.+\.php)(/.*)$;
                                include ${pkgs.nginx}/conf/fastcgi_params;
                                fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
                                fastcgi_param PATH_INFO $fastcgi_path_info;
                                #fastcgi_param HTTPS on;
                                #Avoid sending the security headers twice
                                fastcgi_param modHeadersAvailable true;
                                fastcgi_param front_controller_active true;
                                fastcgi_pass phpfpm;
                                fastcgi_intercept_errors on;
                                fastcgi_request_buffering off;

                                fastcgi_cache NEXTCLOUD;
                            }

                            location ~ ^/(?:updater|ocs-provider)(?:$|/) {
                                try_files $uri/ =404;
                                index index.php;
                            }

                            # Adding the cache control header for js and css files
                            # Make sure it is BELOW the PHP block
                            location ~ \.(?:css|js|woff|svg|gif)$ {
                                try_files $uri /index.php$uri$is_args$args;
                                add_header Cache-Control "public, max-age=15778463";
                                add_header X-Content-Type-Options nosniff;
                                add_header X-XSS-Protection "1; mode=block";
                                add_header X-Robots-Tag none;
                                add_header X-Download-Options noopen;
                                add_header X-Permitted-Cross-Domain-Policies none;
                                add_header X-Frame-Options "SAMEORIGIN" always;
                                # Optional: Don't log access to assets
                                access_log off;
                            }

                            location ~ \.(?:png|html|ttf|ico|jpg|jpeg)$ {
                                try_files $uri /index.php$uri$is_args$args;
                                # Optional: Don't log access to other assets
                                access_log off;
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
                bootstapScript
                backupDbScript
                restoreDbScript
            ];

            services.cron = {
                enable = true;
                systemCronJobs = [
                    "*/15 * * * * root ${cron}/bin/nextcloud-cron"
                    "*/15 * * * * root ${cronThumbnails}/bin/nextcloud-cron-thumbnails"
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
                    deps = [];
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
            deps = [];
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