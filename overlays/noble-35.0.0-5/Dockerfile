# Nextcloud 35.0.0-5: the released 35.0.0-4 image with PHP 8.4 in place of
# PHP 8.3, a Redis service for transactional file locking and the distributed
# cache, and support for installations whose database still runs MySQL 8.0.
# Nextcloud, nginx and MySQL 8.4 stay as in 35.0.0-4; release-gate.sh checks
# every package and file this overlay changes.
#
# - PHP 8.4 comes from the ondrej/php PPA (Ubuntu 24.04 ships only 8.3). An
#   apt pin allows only the php8.4 packages and php-common from the PPA, so
#   no other package, and no other PHP version, can come from it. php8.3 and
#   Ubuntu's php-* metapackages are purged.
# - The base mysql.sh no longer runs apt when a container is created, so a
#   container runs exactly the packages that were tested.
# - Redis listens only on /run/redis/redis.sock (runit service
#   /etc/service/redis, user appbox). 30_installer.sh adds memcache.locking,
#   memcache.distributed and redis to config.php when they are missing, and
#   creates the external storage mounts only when they do not exist yet.
# - 15_mysql_config_compat.sh enables mysql_native_password, which Nextcloud
#   31 and older used for its database user, translates expire_logs_days in
#   either spelling and points lc-messages-dir at MySQL 8.4's messages.
#   16_mysql80_backup.sh copies a MySQL 8.0 data directory once before
#   MySQL 8.4 upgrades it.
FROM repo.cylo.net/nextcloud@sha256:5ffeef884defcb09fd788d04aa2fb6560d4d1c559e49d9691b5ccccab4e819e3

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Release pin: the first PPA php8.4 version with the fixes from the PHP
# security release of 21 October 2026 (PHP 8.4.27, CVE-2026-109618 and
# CVE-2026-109619). The build fails unless every installed package built from
# the php8.4 source is at one version that is at least this one.
# release-gate.sh reads this line.
ARG PHP84_MIN_VERSION=8.4.27-1+ubuntu24.04.1+deb.sury.org+1
LABEL net.cylo.php-min-version="${PHP84_MIN_VERSION}"

# Edit the base files only when they are the ones these edits were written
# against (35.0.0-4).
RUN --mount=type=bind,source=.,target=/mnt/overlay \
    set -eux; \
    printf '%s\n' \
        '2cae11666d2c9c39f38fdba84c3db1e96b6dffeb4a70e71b6c064c22c82ed5c3  /scripts/nginx_php7.sh' \
        '0427b72f1f811f61e7757e5b5fe6e033ad51fcf6ac00a399afc057355801ccfb  /scripts/mysql.sh' \
        '677b692de858b3ab913d15a174743b11715947834696a91dfc977eb4edd7c8a5  /sources/php-fpm.conf' \
        '6473c7f45bcf989d1877d79bb0a1c228eec0260a0f2a839750c7668553f984eb  /sources/www.conf' \
        'a9cd59c2f83e83b467f3463881c7a62cfaf2861d2db7940c28b3feae154475e3  /app-sources/nextcloud.conf' \
        '8f91bf227eeb642765ac864bd56373f5e6a039600846cfea99a287fceeebfe3f  /etc/my_init.d/15_mysql_config_compat.sh' \
        'c51134d0711c398d80987a1a223b7ccf6330e1a230b2cfd9941409f18e789dc6  /etc/my_init.d/30_installer.sh' \
        | sha256sum -c -; \
    for script in 15_mysql_config_compat.sh 16_mysql80_backup.sh 30_installer.sh redis/run; do \
        bash -n "/mnt/overlay/$script"; \
    done; \
    \
    curl -fsSL 'https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x14AA40EC0831756756D7F66C4F4EA0AAE5267A6C' \
        | gpg --dearmor -o /usr/share/keyrings/ondrej-php.gpg; \
    [ "$(gpg --show-keys --with-colons /usr/share/keyrings/ondrej-php.gpg | awk -F: '$1 == "fpr" {print $10; exit}')" = 14AA40EC0831756756D7F66C4F4EA0AAE5267A6C ]; \
    echo 'deb [signed-by=/usr/share/keyrings/ondrej-php.gpg] https://ppa.launchpadcontent.net/ondrej/php/ubuntu noble main' \
        > /etc/apt/sources.list.d/ondrej-php.list; \
    printf '%s\n' \
        'Package: *' 'Pin: release o=LP-PPA-ondrej-php' 'Pin-Priority: -1' '' \
        'Package: /^php8\.4/ php-common' 'Pin: release o=LP-PPA-ondrej-php' 'Pin-Priority: 500' \
        > /etc/apt/preferences.d/ondrej-php; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        php8.4-fpm php8.4-cli php8.4-common php8.4-opcache php8.4-readline \
        php8.4-curl php8.4-gd php8.4-xml php8.4-mbstring php8.4-zip php8.4-intl \
        php8.4-mysql php8.4-apcu php8.4-redis php8.4-imagick php8.4-bcmath \
        php8.4-gmp php8.4-bz2 php8.4-ldap php8.4-smbclient php8.4-imap \
        php8.4-soap php8.4-sqlite3 php8.4-pgsql php8.4-sybase php8.4-pspell \
        php8.4-amqp php8.4-gnupg php8.4-igbinary php8.4-mailparse \
        php8.4-memcache php8.4-memcached php8.4-mongodb php8.4-msgpack \
        php8.4-oauth php8.4-ps php8.4-uploadprogress php8.4-uuid \
        php8.4-xmlrpc php8.4-yaml php8.4-ssh2 php8.4-raphf php8.4-http \
        redis-server; \
    DEBIAN_FRONTEND=noninteractive apt-get purge -y 'php8.3*'; \
    DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y; \
    rm -rf /etc/php/8.3 /usr/lib/php/8.3 /usr/lib/php/20230831; \
    update-alternatives --set php /usr/bin/php8.4; \
    \
    printf 'memory_limit = 3G\n' > /etc/php/8.4/fpm/conf.d/99-nextcloud-memory.ini; \
    printf 'memory_limit = 3G\n' > /etc/php/8.4/cli/conf.d/99-nextcloud-memory.ini; \
    printf 'apc.enable_cli=1\n' > /etc/php/8.4/cli/conf.d/99-nextcloud-apcu.ini; \
    \
    sed -i 's#/etc/php/8\.3/#/etc/php/8.4/#g; s/php-fpm8\.3/php-fpm8.4/g' /scripts/nginx_php7.sh; \
    sed -i 's/^apt update$/true # 35.0.0-5: the packages are installed in the image/; s/^apt install -y mysql-server php8\.3-mysql$/true # 35.0.0-5: the packages are installed in the image/' /scripts/mysql.sh; \
    sed -i 's#^pid = /run/php/php8\.3-fpm\.pid$#pid = /run/php/php8.4-fpm.pid#; s#^error_log = /home/appbox/logs/php8\.3-fpm\.log$#error_log = /home/appbox/logs/php8.4-fpm.log#' /sources/php-fpm.conf; \
    sed -i 's#^listen = /run/php/php8\.3-fpm\.sock$#listen = /run/php/php8.4-fpm.sock#' /sources/www.conf; \
    sed -i 's#unix:/run/php/php8\.3-fpm\.sock;#unix:/run/php/php8.4-fpm.sock;#' /app-sources/nextcloud.conf; \
    if grep -n '8\.3' /scripts/nginx_php7.sh; then exit 1; fi; \
    if grep -nE '^apt ' /scripts/mysql.sh; then exit 1; fi; \
    [ "$(grep -c '^true # 35.0.0-5: the packages are installed in the image$' /scripts/mysql.sh)" -eq 2 ]; \
    if grep -n 'php8\.3' /sources/php-fpm.conf /app-sources/nextcloud.conf; then exit 1; fi; \
    grep -q '^listen = /run/php/php8.4-fpm.sock$' /sources/www.conf; \
    \
    cp /mnt/overlay/15_mysql_config_compat.sh /etc/my_init.d/15_mysql_config_compat.sh; \
    install -m 0755 -o root -g root /mnt/overlay/16_mysql80_backup.sh /etc/my_init.d/16_mysql80_backup.sh; \
    cp /mnt/overlay/30_installer.sh /etc/my_init.d/30_installer.sh; \
    install -m 0644 -o root -g root /mnt/overlay/redis/nextcloud.conf /etc/nextcloud-redis.conf; \
    install -d -m 0755 /etc/service/redis; \
    install -m 0755 -o root -g root /mnt/overlay/redis/run /etc/service/redis/run; \
    for script in 15_mysql_config_compat.sh 16_mysql80_backup.sh 30_installer.sh; do \
        cmp "/mnt/overlay/$script" "/etc/my_init.d/$script"; \
    done; \
    \
    sh /mnt/overlay/release/check-php-packages.sh php8.4 "$PHP84_MIN_VERSION"; \
    if dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package}\n' | grep -E '^.i +php8\.(3|5)'; then exit 1; fi; \
    [ -z "$(apt-get -s autoremove | grep '^Remv' || true)" ]; \
    php-fpm8.4 -t; \
    redis-server --version; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
