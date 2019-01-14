let
    phpFpmSocket = "/run/phpfpm/phpfpm.sock";
    wrapOcc = pkgs: pkgs.stdenv.mkDerivation {
        name = "occ";
        src = pkgs.nextcloud;
        buildInputs = [ pkgs.makeWrapper ];
        buildPhase = ''true'';
        installPhase = ''
            mkdir -p $out/bin
            makeWrapper ${pkgs.php}/bin/php $out/bin/.occ-needs-sudo --add-flags "${pkgs.nextcloud}/occ" \
                --set NEXTCLOUD_CONFIG_DIR "/var/lib/nextcloud/config"
            makeWrapper ${pkgs.sudo}/bin/sudo $out/bin/occ --add-flags "-u nginx $out/bin/.occ-needs-sudo"
        '';
    };
    wrapCron = pkgs: pkgs.stdenv.mkDerivation {
        name = "nexcloud-cron";
        src = pkgs.nextcloud;
        buildInputs = [ pkgs.makeWrapper ];
        buildPhase = ''true'';
        installPhase = ''
            mkdir -p $out/bin
            makeWrapper ${pkgs.php}/bin/php $out/bin/.nextcloud-cron-needs-sudo --add-flags "${pkgs.nextcloud}/cron.php" \
                --set NEXTCLOUD_CONFIG_DIR "/var/lib/nextcloud/config"
            makeWrapper ${pkgs.sudo}/bin/sudo $out/bin/nextcloud-cron --add-flags "-u nginx $out/bin/.nextcloud-cron-needs-sudo"
        '';
    };
    wrapBorg = pkgs: config: pkgs.stdenv.mkDerivation {
        name = "nextcloud-borg";
        src = pkgs.borgbackup;
        buildInputs = [ pkgs.makeWrapper ];
        buildPhase = ''true'';
        installPhase = ''
            mkdir -p $out/bin
            makeWrapper ${pkgs.borgbackup}/bin/borg $out/bin/nextcloud-borg \
                --set BORG_REPO "${config.homeserver.borgRepo}" \
                --set BORG_PASSCOMMAND "cat ${secrets.getPath "backup/nextcloud"}" \
                --set BORG_RSH "ssh -i ${secrets.getPath "backup/key"} -o StrictHostKeyChecking=no"
        '';
    };
    buildInitialConfig = pkgs: pkgs.writeText "config.php" ''<?php
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
    buildExtraConfig = pkgs: config: pkgs.writeText "nextcloud-extra.json" ''
        {
            "system": {
                "trusted_domains": ${builtins.toJSON (builtins.attrNames config.homeserver.hostnames)},
                "trusted_proxies": [ "127.0.0.1" ],
                "memcache.local": "\\OC\\Memcache\\APCu",
                "memcache.distributed": "\\OC\\Memcache\\Memcached",
                "memcached_servers": [ [ "localhost", 11211 ] ],

                "auth.bruteforce.protection.enabled": true
            }
        }
    '';
    installAndEnable = occ: app: ''
        ${occ}/bin/occ app:install ${app} || echo "Error, probably already installed";
        ${occ}/bin/occ app:enable ${app} || echo "Error, probably already enabled";
    '';
    updateConfig = occ: extraConfig: ''
        ${occ}/bin/occ config:import ${extraConfig};
        ${occ}/bin/occ upgrade;
        ${occ}/bin/occ background:cron;
        ${installAndEnable occ "calendar"}
        ${installAndEnable occ "contacts"}
        ${installAndEnable occ "notes"}
        ${installAndEnable occ "bookmarks"}
        ${occ}/bin/occ app:disable activity || echo "Error, probably already disabled";
    '';
    bootstapNextcloud = lib: pkgs: extraConfig: initialConfig: occ: pkgs.writeScriptBin "nextcloud-bootstrap" ''
        if [ -f /var/lib/nextcloud/config/config.php ]; then
            echo "Nextcloud config already exists, skipping nextcloud bootstrap."
            ${updateConfig occ extraConfig}
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

            ${updateConfig occ extraConfig}
        fi
    '';
    backupNextcloudDb = pkgs: pkgs.writeScriptBin "nextcloud-backup-db" ''
        export PGPASSWORD=${secrets.getBash "postgresql/nextcloud"};
        ${pkgs.postgresql_10}/bin/pg_dump -h 127.0.0.1 -U nextcloud --clean --if-exists -f /mnt/db/nextcloud.sql nextcloud
    '';
    restoreNextcloudDb = pkgs: pkgs.writeScriptBin "nextcloud-restore-db" ''
        export PGPASSWORD=${secrets.getBash "postgresql/nextcloud"};
        ${pkgs.postgresql_10}/bin/psql -h 127.0.0.1 -U nextcloud < /mnt/db/nextcloud.sql
    '';
    restoreNextcloud = pkgs: nextcloudBorg: restoreDbScript: pkgs.writeScriptBin "nextcloud-restore" ''
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
{ config, lib, pkgs, ... }:
let
    occ = (wrapOcc pkgs);
    cron = (wrapCron pkgs);
    initialConfig = buildInitialConfig pkgs;
    extraConfig = buildExtraConfig pkgs config;
    bootstapScript = bootstapNextcloud lib pkgs extraConfig initialConfig occ;
    backupDbScript = backupNextcloudDb pkgs;
    restoreDbScript = restoreNextcloudDb pkgs;
    nextcloudBorg = wrapBorg pkgs config;
    restoreNextcloudScript = restoreNextcloud pkgs nextcloudBorg restoreDbScript;
in
{
    imports = [
        ./memcached.nix
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
        config = { pkgs, lib, ... }: {
            time.timeZone = config.homeserver.timeZone;
            system.stateVersion = config.system.stateVersion;

            services.nginx = {
                enable = true;
                appendHttpConfig = ''
                    server_names_hash_bucket_size 64;
                '';
                upstreams = {
                    phpfpm = {
                        servers = {
                            "unix:${phpFpmSocket}" = {
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

                            location = /.well-known/carddav {
                                return 301 $scheme://$host/remote.php/dav;
                            }
                            location = /.well-known/caldav {
                                return 301 $scheme://$host/remote.php/dav;
                            }
                            location / {
                                rewrite ^ /index.php$uri;
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

            services.phpfpm.phpOptions = ''
                zend_extension=${pkgs.php72}/lib/php/extensions/opcache.so
                extension=${pkgs.php72Packages.memcached}/lib/php/extensions/memcached.so
                extension=${pkgs.php72Packages.apcu}/lib/php/extensions/apcu.so

                memory_limit = 512M

                [opcache]
                opcache.enable=1
                opcache.enable_cli=1
                opcache.interned_strings_buffer=8
                opcache.max_accelerated_files=10000
                opcache.memory_consumption=128
                opcache.save_comments=1
                opcache.revalidate_freq=1
            '';
            services.phpfpm.pools = {
                www = {
                    listen = phpFpmSocket;
                    extraConfig = ''
                        user = nginx
                        group = nginx
                        listen.owner = nginx
                        listen.group = nginx
                        pm = dynamic
                        pm.max_children = 25
                        pm.start_servers = 5
                        pm.min_spare_servers = 5
                        pm.max_spare_servers = 10
                        pm.max_requests = 50

                        php_admin_value[display_errors] = Off
                        php_admin_value[session.save_path] = /var/lib/nextcloud/sessions
                        php_admin_value[session.save_handler] = files

                        env[NEXTCLOUD_CONFIG_DIR] = "/var/lib/nextcloud/config"
                        env[PATH] = /run/current-system/sw/bin/
                        env[TMP] = /tmp
                        env[TMPDIR] = /tmp
                        env[TEMP] = /tmp
                    '';
                };
            };

            environment.systemPackages = [
                occ
                cron
                bootstapScript
                backupDbScript
                restoreDbScript
            ];

            services.cron = {
                enable = true;
                systemCronJobs = [
                    "*/15 * * * * root ${cron}/bin/nextcloud-cron"
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

                        cp -r ${pkgs.nextcloud}/. /var/lib/nextcloud/root
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
        repo = config.homeserver.borgRepo;
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