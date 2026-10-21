#!/bin/bash
set -x

# MySQL Lock file if the app was forcefully closed.
rm -fr /var/run/mysqld/mysqld.sock.lock

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
max_execution_time=3600" > /etc/php/8.1/fpm/conf.d/40-nextcloud.ini

echo "env[HOSTNAME] = $HOSTNAME
env[PATH] = /usr/local/bin:/usr/bin:/bin
env[TMP] = /tmp
env[TMPDIR] = /tmp
env[TEMP] = /tmp" >> /home/appbox/config/php-fpm/pool.d/www.conf

    mkdir -p /storage

    UPGRADE=true
    if [ ! -f /home/appbox/public_html/index.php ]; then
        UPGRADE=false
    fi

    # download app
    cd /home/appbox/public_html
    curl -o nextcloud.zip -L https://download.nextcloud.com/server/releases/nextcloud-"${NEXTCLOUD_VER}".zip
    unzip -o nextcloud.zip
    cp -R nextcloud/* .
    cp nextcloud/.htaccess .
    cp nextcloud/.user.ini .
    rm -f nextcloud.zip
    rm -fr nextcloud/

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

    #This is an upgrade...
    if [[ $UPGRADE == "true" ]]; then
        /usr/sbin/mysqld --defaults-file=/home/appbox/config/mysql/mysqld.cnf --verbose=0 --socket=/run/mysqld/mysqld.sock &
        /usr/sbin/nginx -c /home/appbox/config/nginx/nginx.conf -g "daemon off;" &
        /usr/sbin/php-fpm8.1 --nodaemonize --fpm-config /home/appbox/config/php-fpm/php-fpm.conf &
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
        until [[ $(curl -i -L http://"$HOSTNAME":80/index.php | grep -E '302|200') ]]; do
            printf '.'
            sleep 1
        done

        if ! grep -q 'memcache' /home/appbox/public_html/config/config.php; then
            sed -i "/\$CONFIG/a \ \ 'memcache.local' => '\\\OC\\\Memcache\\\APCu'," /home/appbox/public_html/config/config.php
        fi

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
        if cat /home/appbox/public_html/lib/private/User/Manager.php | grep -q "throw new \\\InvalidArgumentException(\$l->t('Username is invalid because files already exist for this user'));"; then
            /usr/sbin/mysqld --defaults-file=/home/appbox/config/mysql/mysqld.cnf --verbose=0 --socket=/run/mysqld/mysqld.sock &
            /usr/sbin/nginx -c /home/appbox/config/nginx/nginx.conf -g "daemon off;" &
            /usr/sbin/php-fpm8.1 --nodaemonize --fpm-config /home/appbox/config/php-fpm/php-fpm.conf &
            sleep 10

            while ! (mysqladmin --socket=/run/mysqld/mysqld.sock ping)
            do
                sleep 3
                echo "waiting for mysql ..."
            done

            cp /home/appbox/public_html/lib/private/User/Manager.php /home/appbox/public_html/lib/private/User/Manager.php.bak
            sed -i "/throw new \\\InvalidArgumentException(\$l->t('Username is invalid because files already exist for this user'));/d" /home/appbox/public_html/lib/private/User/Manager.php
            sed -i "/throw new \\\InvalidArgumentException(\$l->t('The username is already being used'));/d" /home/appbox/public_html/lib/private/User/Manager.php
            sed -i "/throw new \\\InvalidArgumentException(\$l->t('Could not create user'));/d" /home/appbox/public_html/lib/private/User/Manager.php
            until [[ $(curl -i -L http://"$HOSTNAME":80/index.php | grep '200') ]]; do
                printf '.'
                sleep 1
            done
            mv /home/appbox/public_html/lib/private/User/Manager.php.bak /home/appbox/public_html/lib/private/User/Manager.php
            su -c "php /home/appbox/public_html/occ integrity:check-core" appbox -s /bin/sh
            su -c "cd /home/appbox/public_html; php occ --no-interaction db:add-missing-indices" -s /bin/sh appbox
            su -c "cd /home/appbox/public_html; php occ --no-interaction db:convert-filecache-bigint" -s /bin/sh appbox
            su -c "cd /home/appbox/public_html; php occ --no-interaction app:update --all" -s /bin/sh appbox
            su -c "cd /home/appbox/public_html; php occ --no-interaction app:enable files_external" -s /bin/sh appbox
            su -c "cd /home/appbox/public_html; php occ --no-interaction files_external:create apps local null::null --config datadir=/APPBOX_DATA/apps/" -s /bin/sh appbox
            su -c "cd /home/appbox/public_html; php occ --no-interaction files_external:option 1 enable_sharing true" -s /bin/sh appbox
            su -c "cd /home/appbox/public_html; php occ --no-interaction files_external:create storage local null::null --config datadir=/APPBOX_DATA/storage/" -s /bin/sh appbox
            su -c "cd /home/appbox/public_html; php occ --no-interaction files_external:option 2 enable_sharing true" -s /bin/sh appbox
            su -c "cd /home/appbox/public_html; php occ --no-interaction config:app:set files max_chunk_size --value 52428800" -s /bin/sh appbox

            if ! grep -q 'memcache' /home/appbox/public_html/config/config.php; then
                sed -i "/\$CONFIG/a \ \ 'memcache.local' => '\\\OC\\\Memcache\\\APCu'," /home/appbox/public_html/config/config.php
            fi

            pkill -9 mysql
            pkill -9 nginx
            pkill -9 php
        fi
    fi
fi

# To fix https://github.com/nextcloud/desktop/issues/1130
if ! grep -q 'overwriteprotocol' /home/appbox/public_html/config/config.php; then
    sed -i "/\$CONFIG/a \ \ 'overwriteprotocol' => 'https'," /home/appbox/public_html/config/config.php
fi

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
# su -c "cd /home/appbox/public_html; php occ --no-interaction db:add-missing-indices" -s /bin/sh appbox
# su -c "cd /home/appbox/public_html; php occ --no-interaction db:convert-filecache-bigint" -s /bin/sh appbox
# su -c "cd /home/appbox/public_html; php occ --no-interaction db:add-missing-columns" -s /bin/sh appbox
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
# echo "apc.enable_cli=1" >> /etc/php/8.1/cli/conf.d/20-apcu.ini
# If end up in an upgrade loop
# delete affected apps from /home/appbox/public_html/apps/
# and restore from a fresh unzipped nextcloud.zip
# upgrade should then complete