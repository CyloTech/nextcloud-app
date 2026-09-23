#!/bin/bash

if [ ! -f /etc/ssh/ssh_host_rsa_key ] ; then
    ssh-keygen -o -f /etc/ssh/ssh_host_rsa_key -N '' -t rsa -b 4096
fi

if [ ! -f /etc/ssh/ssh_host_ed25519_key ] ; then
    ssh-keygen -o -f /etc/ssh/ssh_host_ed25519_key -N '' -t ed25519
fi


mkdir -p /run/php
chmod 755 /run/php
chown -R appbox:appbox /run/php
mkdir -p /run/sshd
chmod 755 /run/sshd
mkdir /home/appbox/.ssh
chmod 700 /home/appbox/.ssh
touch /home/appbox/.ssh/authorized_keys
chmod 600 /home/appbox/.ssh/authorized_keys
chmod 770 /home/appbox
chown -R appbox:appbox /home/appbox/.ssh
mkdir -p /run/mysqld
chmod 755 /run/mysqld
chown -R appbox:appbox /run/mysqld

# Change the appbox user shell to /bin/bash
usermod -s /bin/bash appbox

echo "appbox:$ADMIN_PASS" | chpasswd

echo "Setting up SSH Daemon"
mkdir -p /etc/service/sshd
echo "#!/bin/sh
exec /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config" > /etc/service/sshd/run
chmod +x /etc/service/sshd/run
rm -f /etc/service/sshd/down


# MySQL Lock file if the app was forcefully closed.
rm -fr /var/run/mysqld/mysqld.sock.lock

# These files can survive an image change in the Appbox home volume. Keep the
# active FPM service, nginx socket, and both PHP SAPIs on the same release.
printf 'memory_limit = 3G\n' > /etc/php/8.3/fpm/conf.d/99-nextcloud-memory.ini
printf 'memory_limit = 3G\n' > /etc/php/8.3/cli/conf.d/99-nextcloud-memory.ini
if [ -f /etc/service/phpfpm/run ]; then
    sed -i 's/php-fpm8\.[23]/php-fpm8.3/g' /etc/service/phpfpm/run
fi
if [ -f /home/appbox/config/nginx/sites-enabled/nextcloud.conf ]; then
    sed -i 's/php8\.[23]-fpm.sock/php8.3-fpm.sock/g' /home/appbox/config/nginx/sites-enabled/nextcloud.conf
fi

if [ ! -f /etc/app_installer_completed ]; then

    echo "**************************************************************"
    echo "*                                                            *"
    echo "*                 Cylo Base Installer 1.0                    *"
    echo "*                     Installing Apps:                       *"
    echo "*                                                            *"
    echo "**************************************************************"
    echo "Nextcloud"
    echo "**************************************************************"
    echo " "

    if [ -f /home/appbox/public_html/config/config.php ]; then
        mkdir -p /home/appbox/public_html/config/
        mv /home/appbox/public_html/config/config.php /home/appbox/logs/config.php
    fi

    ls -la /home/appbox/config
    ls -la /home/appbox/config/php-fpm/

    # Add our own NGINX Config.
    mkdir -p /home/appbox/config/nginx/sites-enabled/
    rm -fr /home/appbox/config/nginx/sites-enabled/default-site.conf
    cp /app-sources/nextcloud.conf /home/appbox/config/nginx/sites-enabled/nextcloud.conf
    sed -i 's/HOSTNAME/'"$HOSTNAME"'/g' /home/appbox/config/nginx/sites-enabled/nextcloud.conf

    # Configure PHP for Nextcloud
echo "memory_limit = 3G
max_execution_time = 300
opcache.enable=1
opcache.enable_cli=1
opcache.interned_strings_buffer=32
opcache.max_accelerated_files=10000
opcache.memory_consumption=128
opcache.save_comments=1
opcache.revalidate_freq=1
upload_max_filesize=100G
post_max_size=100G
max_execution_time=3600" > /etc/php/8.3/fpm/conf.d/40-nextcloud.ini

echo "env[HOSTNAME] = $HOSTNAME
env[PATH] = /usr/local/bin:/usr/bin:/bin
env[TMP] = /tmp
env[TMPDIR] = /tmp
env[TEMP] = /tmp" >> /home/appbox/config/php-fpm/pool.d/www.conf

    mkdir -p /storage

    UPGRADE=true
    SKIP_UPGRADE=false
    if [ ! -f /home/appbox/public_html/index.php ]; then
        UPGRADE=false
    fi

    # Function to compare semantic versions
    # Returns 0 if v1 > v2, 1 if v1 = v2, 2 if v1 < v2
    version_compare() {
        local v1=$1
        local v2=$2

        # Split versions into arrays
        IFS='.' read -ra V1_PARTS <<< "$v1"
        IFS='.' read -ra V2_PARTS <<< "$v2"

        # Compare each part
        for i in 0 1 2; do
            local part1=${V1_PARTS[$i]:-0}
            local part2=${V2_PARTS[$i]:-0}

            if (( part1 > part2 )); then
                return 0
            elif (( part1 < part2 )); then
                return 2
            fi
        done

        return 1
    }

    # Check if installed version is higher than the version we're deploying
    # This can happen when users upgrade from the Nextcloud frontend
    if [ -f /home/appbox/public_html/version.php ]; then
        # Extract version from version.php (e.g., $OC_VersionString = '31.0.4';)
        INSTALLED_VER=$(grep -oP "\\\$OC_VersionString\s*=\s*'\K[0-9]+\.[0-9]+\.[0-9]+" /home/appbox/public_html/version.php)

        if [ -n "$INSTALLED_VER" ]; then
            echo "Installed Nextcloud version: $INSTALLED_VER"
            echo "Dockerfile Nextcloud version: $NEXTCLOUD_VER"

            version_compare "$INSTALLED_VER" "$NEXTCLOUD_VER"
            COMPARE_RESULT=$?

            if [ $COMPARE_RESULT -eq 0 ] || [ $COMPARE_RESULT -eq 1 ]; then
                echo "Installed version ($INSTALLED_VER) is >= Dockerfile version ($NEXTCLOUD_VER). Skipping download and upgrade."
                SKIP_UPGRADE=true
            fi
        fi
    fi

    # download app (skip if installed version is already higher)
    if [ "$SKIP_UPGRADE" = false ]; then
        cd /home/appbox/public_html
        /app-sources/verify-nextcloud-archive.sh "$NEXTCLOUD_VER" || exit 1
        cd /home/appbox/public_html
        unzip -o /app-sources/nextcloud-"${NEXTCLOUD_VER}".zip || exit 1
        cp -R nextcloud/* .
        cp -R nextcloud/.* .
        rm -fr nextcloud/
    fi

echo "<?php
\$AUTOCONFIG = array(
  'dbtype'        => 'mysql',
  'dbname'        => '${DB_NAME}',
  'dbuser'        => '${DB_USER}',
  'dbpass'        => '${DB_PASS}',
  'dbhost'        => 'localhost:3306',
  'dbtableprefix' => 'nc_',
  'adminlogin'    => '${ADMIN_USER}',
  'adminpass'     => '${ADMIN_PASS}',
  'directory'     => '/storage'
);" > /home/appbox/public_html/config/autoconfig.php

    if [ ! -f /storage/.ocdata ]; then
        touch /storage/.ocdata
    fi

    chown -R appbox:appbox /home/appbox/public_html

    find /storage -not \( -path */apps/* -prune \) -not \( -path */apps/ -prune \) -exec chmod 0770 {} \;
    find /storage -not \( -path */apps/* -prune \) -not \( -path */apps/ -prune \) -exec chown appbox:appbox {} \;

    #This is an upgrade... (skip if installed version is already higher)
    if [[ $UPGRADE == "true" ]] && [[ $SKIP_UPGRADE == "false" ]]; then
        /usr/sbin/mysqld --defaults-file=/home/appbox/config/mysql/mysqld.cnf --verbose=0 --socket=/run/mysqld/mysqld.sock &
        /usr/sbin/nginx -c /home/appbox/config/nginx/nginx.conf -g "daemon off;" &
        /usr/sbin/php-fpm8.3 --nodaemonize --fpm-config /home/appbox/config/php-fpm/php-fpm.conf &
        sleep 10

        while ! (mysqladmin --socket=/run/mysqld/mysqld.sock ping)
        do
            sleep 3
            echo "waiting for mysql ..."
        done

        if [ -f /home/appbox/logs/config.php ]; then
            mv /home/appbox/logs/config.php /home/appbox/public_html/config/config.php
            chown -R appbox:appbox /home/appbox/public_html/config/config.php
        fi

        # Make sure config.php exists
        until curl -i -L http://"$HOSTNAME":80/index.php | grep -q '200'; do
            printf '.'
            sleep 1
        done

        su -c "cd /home/appbox/public_html; php occ --no-interaction upgrade" -s /bin/sh appbox
        su -c "cd /home/appbox/public_html; php occ --no-interaction db:add-missing-indices" -s /bin/sh appbox
        su -c "cd /home/appbox/public_html; php occ --no-interaction db:convert-filecache-bigint" -s /bin/sh appbox
        su -c "cd /home/appbox/public_html; php occ --no-interaction db:add-missing-columns" -s /bin/sh appbox
        su -c "cd /home/appbox/public_html; php occ --no-interaction config:app:set files max_chunk_size --value 52428800" -s /bin/sh appbox

        pkill -9 mysql
        pkill -9 nginx
        pkill -9 php
        rm -fr /run/mysqld/mysqld.sock
    else
        /usr/sbin/mysqld --defaults-file=/home/appbox/config/mysql/mysqld.cnf --verbose=0 --socket=/run/mysqld/mysqld.sock &
        /usr/sbin/nginx -c /home/appbox/config/nginx/nginx.conf -g "daemon off;" &
        /usr/sbin/php-fpm8.3 --nodaemonize --fpm-config /home/appbox/config/php-fpm/php-fpm.conf &
        sleep 10

        while ! (mysqladmin --socket=/run/mysqld/mysqld.sock ping)
        do
            sleep 3
            echo "waiting for mysql ..."
        done

        until curl -i -L http://"$HOSTNAME":80/index.php | grep -q '200'; do
            printf '.'
            sleep 1
        done

        su -c "cd /home/appbox/public_html; php occ --no-interaction db:add-missing-indices" -s /bin/sh appbox
        su -c "cd /home/appbox/public_html; php occ --no-interaction db:convert-filecache-bigint" -s /bin/sh appbox
        su -c "cd /home/appbox/public_html; php occ --no-interaction app:update --all" -s /bin/sh appbox
        su -c "cd /home/appbox/public_html; php occ --no-interaction app:enable files_external" -s /bin/sh appbox
        su -c "cd /home/appbox/public_html; php occ --no-interaction files_external:create apps local null::null --config datadir=/APPBOX_DATA/apps/" -s /bin/sh appbox
        su -c "cd /home/appbox/public_html; php occ --no-interaction files_external:option 1 enable_sharing true" -s /bin/sh appbox
        su -c "cd /home/appbox/public_html; php occ --no-interaction files_external:create storage local null::null --config datadir=/APPBOX_DATA/storage/" -s /bin/sh appbox
        su -c "cd /home/appbox/public_html; php occ --no-interaction files_external:option 2 enable_sharing true" -s /bin/sh appbox
        su -c "cd /home/appbox/public_html; php occ --no-interaction config:app:set files max_chunk_size --value 52428800" -s /bin/sh appbox

        pkill -9 mysql
        pkill -9 nginx
        pkill -9 php
    fi
fi

/usr/sbin/mysqld --defaults-file=/home/appbox/config/mysql/mysqld.cnf --verbose=0 --socket=/run/mysqld/mysqld.sock &
/usr/sbin/nginx -c /home/appbox/config/nginx/nginx.conf -g "daemon off;" &
        /usr/sbin/php-fpm8.3 --nodaemonize --fpm-config /home/appbox/config/php-fpm/php-fpm.conf &
sleep 10

while ! (mysqladmin --socket=/run/mysqld/mysqld.sock ping)
do
    sleep 3
    echo "waiting for mysql ..."
done

until curl -i -L http://"$HOSTNAME":80/index.php | grep -q '200'; do
    printf '.'
    sleep 1
done

# Check if the MIME type mapping for .mjs already exists
if ! grep -q "text/javascript js mjs;" "/home/appbox/config/nginx/nginx.conf"; then
    # Use sed to insert the types block after the include directive
    sed -i '/include \/etc\/nginx\/mime.types;/a\
types {\
    text/javascript js mjs;\
}' "/home/appbox/config/nginx/nginx.conf"
    echo "Added MIME type mapping for .mjs to /home/appbox/config/nginx/nginx.conf."
else
    echo "MIME type mapping for .mjs already exists in /home/appbox/config/nginx/nginx.conf."
fi

# To fix https://github.com/nextcloud/desktop/issues/1130
if ! grep -q 'overwriteprotocol' /home/appbox/public_html/config/config.php; then
    sed -i "/\$CONFIG/a \ \ 'overwriteprotocol' => 'https'," /home/appbox/public_html/config/config.php
fi

if ! grep -q 'memcache' /home/appbox/public_html/config/config.php; then
    sed -i "/\$CONFIG/a \ \ 'memcache.local' => '\\\OC\\\Memcache\\\APCu'," /home/appbox/public_html/config/config.php
fi

if ! grep -q 'maintenance_window_start' /home/appbox/public_html/config/config.php; then
    # 'maintenance_window_start' => 1,
    # Set maintenance window to a random time of day between 0-6
    RANDOM_TIME=$(shuf -i 0-6 -n 1)
    sed -i "/\$CONFIG/a \ \ 'maintenance_window_start' => $RANDOM_TIME," /home/appbox/public_html/config/config.php
fi

su -c "cd /home/appbox/public_html; php occ maintenance:repair --include-expensive" -s /bin/sh appbox

pkill -9 mysql
pkill -9 nginx
pkill -9 php

echo "                                   .''.       "
echo "       .''.      .        *''*    :_\/_:     . "
echo "      :_\/_:   _\(/_  .:.*_\/_*   : /\ :  .'.:.'."
echo "  .''.: /\ :   ./)\   ':'* /\ * :  '..'.  -=:o:=-"
echo " :_\/_:'.:::.    ' *''*    * '.\'/.' _\(/_'.':'.'"
echo " : /\ : :::::     *_\/_*     -= o =-  /)\    '  *"
echo "  '..'  ':::'     * /\ *     .'/.\'.   '"
echo "      *            *..*         :"

echo "Finishing Install"
# Finish Install
if [ "${APP_APEX_CALLBACK}" = true ]; then
    until [[ $(curl -i -H "Accept: application/json" -H "Content-Type:application/json" -X POST "https://api.cylo.io/v1/apps/installed/${INSTANCE_ID}" | grep '200') ]]
        do
        sleep 5
    done
fi

# set cronjob
crontab /app-sources/crontab
touch /etc/app_installer_completed


#####
# May need to change ~/public_html/lib/private/Updater.php
# cp ~/public_html/lib/private/Updater.php ~/
# edit file as below
# Exception: Updates between multiple major versions and downgrades are unsupported.
# https://help.nextcloud.com/t/cannot-manually-upgrade-from-11-0-3/13054/4
# Table 'nextcloud.nc_flow_operations_scope' doesn't exist:
# then mv ~/public_html/apps/workflowengine/appinfo/database.xml ~/
# su -c "cd /home/appbox/public_html; php occ --no-interaction upgrade" -s /bin/sh appbox
# su -c "cd /home/appbox/public_html; php occ --no-interaction db:add-missing-columns" -s /bin/sh appbox
# su -c "cd /home/appbox/public_html; php occ --no-interaction db:add-missing-indices" -s /bin/sh appbox
# su -c "cd /home/appbox/public_html; php occ --no-interaction db:convert-filecache-bigint" -s /bin/sh appbox
# su -c "cd /home/appbox/public_html; php occ --no-interaction app:update --all" -s /bin/sh appbox
#
# mv ~/database.xml ~/public_html/apps/workflowengine/appinfo/database.xml
# cp ~/Updater.php ~/public_html/lib/private/Updater.php
# su -c "cd /home/appbox/public_html; php occ maintenance:mode --off" -s /bin/sh appbox
#
# Table 'nextcloud.nc_filecache_extended' doesn't exist: https://github.com/nextcloud/server/issues/15698
# mysql -p
# use nextcloud
# CREATE TABLE `nc_filecache_extended` (
#   `fileid` bigint(20) unsigned NOT NULL,
#   `metadata_etag` varchar(40) COLLATE utf8mb4_bin DEFAULT NULL,
#   `creation_time` bigint(20) NOT NULL DEFAULT '0',
#   `upload_time` bigint(20) NOT NULL DEFAULT '0',
#   UNIQUE KEY `fce_fileid_idx` (`fileid`),
#   KEY `fce_ctime_idx` (`creation_time`),
#   KEY `fce_utime_idx` (`upload_time`)
# ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;
#
# If high memory or segfault:
# echo "apc.enable_cli=1" >> /etc/php/8.3/cli/conf.d/20-apcu.ini
# If end up in an upgrade loop
# delete affected apps from /home/appbox/public_html/apps/
# and restore from a fresh unzipped nextcloud.zip
# upgrade should then complete
