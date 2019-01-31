#!/bin/bash
set -x

# Remove MySQL Lock file if the app was forcefully closed.
rm -fr /var/run/mysqld/mysqld.sock.lock

if [ ! -f /etc/nc_installed ]; then
    if [ -f /home/appbox/public_html/config/config.php ]; then
        mv /home/appbox/public_html/config/config.php /home/appbox/logs/config.php
    fi

    # Install & Configure LEMP Stack
    /bin/sh /scripts/lemp.sh

    # Add our own NGINX Config.
    rm -fr /home/appbox/config/nginx/sites-enabled/default-site.conf
    mv /tmp/nextcloud.conf /home/appbox/config/nginx/sites-enabled/nextcloud.conf

    # Configure PHP for Nextcloud
echo "opcache.enable=1
opcache.enable_cli=1
opcache.interned_strings_buffer=8
opcache.max_accelerated_files=10000
opcache.memory_consumption=128
opcache.save_comments=1
opcache.revalidate_freq=1 " >> /etc/php/7.2/fpm/php.ini

echo "env[HOSTNAME] = $HOSTNAME
env[PATH] = /usr/local/bin:/usr/bin:/bin
env[TMP] = /tmp
env[TMPDIR] = /tmp
env[TEMP] = /tmp" >> /home/appbox/config/php-fpm/pool.d/www.conf

    mkdir -p /storage
    # download app
    cd /home/appbox/public_html
    curl -o nextcloud.zip -L https://download.nextcloud.com/server/releases/nextcloud-"${NEXTCLOUD_VER}".zip
    unzip nextcloud.zip
    mv nextcloud/* .
    mv nextcloud/.htaccess .
    mv nextcloud/.user.ini .
    rm -f nextcloud.zip
    rm -fr nextcloud/

echo "<?php
\$AUTOCONFIG = array(
  'dbtype'        => 'mysql',
  'dbname'        => 'nextcloud',
  'dbuser'        => 'root',
  'dbpass'        => '${MYSQL_ROOT_PASSWORD}',
  'dbhost'        => 'localhost:3306',
  'dbtableprefix' => 'nc_',
  'adminlogin'    => '${ADMIN_USER}',
  'adminpass'     => '${ADMIN_PASS}',
  'directory'     => '/storage',
);" > /home/appbox/public_html/config/autoconfig.php

    if [ ! -f /storage/.ocdata ]; then
        touch /storage/.ocdata
    fi

    chown -R appbox:appbox /home/appbox/public_html

    # set cronjob
    crontab /tmp/crontab

    chmod -R 0770 /storage
    chown -R appbox:appbox /storage

    #This is an upgrade...
    if [ -f /home/appbox/logs/config.php ]; then
        /usr/sbin/mysqld --verbose=0 --socket=/run/mysqld/mysqld.sock &
        sleep 10

        mv /home/appbox/logs/config.php /home/appbox/public_html/config/config.php
        chown -R appbox:appbox /home/appbox/public_html/config/config.php
        sed -i "s/throw new \\\Exception('Updates between multiple major versions and downgrades are unsupported.');/# throw new \\\Exception('Updates between multiple major versions and downgrades are unsupported.');/g" /home/appbox/public_html/lib/private/Updater.php
        touch /etc/nc_installed

        exec su -c "cd /home/appbox/public_html; php occ upgrade; touch /home/appbox/public_html/finished-upgrade" -s /bin/sh appbox &
        while [ ! -f /home/appbox/public_html/finished-upgrade ]
        do
          sleep 5
          echo "Waiting for upgrade to finish"
        done

        pkill -9 mysql
        rm -fr /run/mysqld/mysqld.sock
    fi

    # Finish Installation
    curl -i -H "Accept: application/json" -H "Content-Type:application/json" -X POST "https://api.cylo.io/v1/apps/installed/$INSTANCE_ID"
    touch /etc/nc_installed
fi

exec /usr/bin/supervisord -n -c /home/appbox/config/supervisor/supervisord.conf