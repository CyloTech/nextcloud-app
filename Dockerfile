FROM repo.cylo.net/baseimage@sha256:14cefc412bab9e3bba6bed680ec8f9bfc204bd75a3c983c394558d1a0401d1a5

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# PHP 8.4 supports both the existing Nextcloud 31 release and Nextcloud 35.
# Nextcloud 35 requires MySQL 8.4 or newer. Retain the existing data volume.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg software-properties-common; \
    add-apt-repository -y ppa:ondrej/php; \
    curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg; \
    echo 'deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/ubuntu noble nginx' > /etc/apt/sources.list.d/nginx.list; \
    echo -e 'Package: *\nPin: origin nginx.org\nPin-Priority: 900' > /etc/apt/preferences.d/99nginx; \
    curl -fsSL https://repo.mysql.com/RPM-GPG-KEY-mysql-2025 | gpg --dearmor -o /usr/share/keyrings/mysql-archive-keyring.gpg; \
    echo 'deb [signed-by=/usr/share/keyrings/mysql-archive-keyring.gpg] https://repo.mysql.com/apt/ubuntu/ noble mysql-8.4-lts' > /etc/apt/sources.list.d/mysql.list; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      nginx mysql-server unzip \
      php8.4-fpm php8.4-cli php8.4-curl php8.4-gd php8.4-xml \
      php8.4-mbstring php8.4-zip php8.4-intl php8.4-mysql \
      php8.4-apcu php8.4-redis php8.4-imagick php8.4-bcmath \
      php8.4-gmp php8.4-bz2 php8.4-ldap php8.4-smbclient; \
    update-alternatives --set php /usr/bin/php8.4; \
    grep -q 'php-fpm8.3' /scripts/nginx_php7.sh; \
    sed -i 's/php-fpm8\.3/php-fpm8.4/g; s@/etc/php/8\.3/@/etc/php/8.4/@g; s/memory_limit = 2G/memory_limit = 3G/' /scripts/nginx_php7.sh; \
    grep -q 'apt install -y mysql-server php-mysql' /scripts/mysql.sh; \
    sed -i 's/apt install -y mysql-server php-mysql/apt install -y mysql-server php8.4-mysql/' /scripts/mysql.sh; \
    printf 'memory_limit = 3G\n' > /etc/php/8.4/fpm/conf.d/99-nextcloud-memory.ini; \
    printf 'memory_limit = 3G\n' > /etc/php/8.4/cli/conf.d/99-nextcloud-memory.ini; \
    apt-get clean; rm -rf /var/lib/apt/lists/*

ENV DB_NAME=nextcloud
ENV DB_USER=root
ENV INSTALL_MYSQL=true
ENV INSTALL_NGINXPHP=true
ENV DB_PASS=mysqlr00t

# Nextcloud Environment variables
ENV NEXTCLOUD_VER="35.0.0"
ENV ADMIN_USER=admin
ENV ADMIN_PASS=Letmein123
ENV APP_APEX_CALLBACK=true

# Add installer and source files
ADD ./scripts/10_upgrade_preflight.sh /etc/my_init.d/10_upgrade_preflight.sh
ADD ./scripts/30_installer.sh /etc/my_init.d/30_installer.sh
ADD ./sources/* /app-sources/

# Verify the release archive once at build time; customer startup uses the
# verified copy and does not depend on the download service.
RUN set -eux; \
    curl -fsSL https://download.nextcloud.com/server/releases/nextcloud-35.0.0.zip -o /app-sources/nextcloud-35.0.0.zip; \
    curl -fsSL https://download.nextcloud.com/server/releases/nextcloud-35.0.0.zip.sha256 -o /app-sources/nextcloud-35.0.0.zip.sha256; \
    cd /app-sources; \
    sha256sum -c nextcloud-35.0.0.zip.sha256; \
    unzip -tq nextcloud-35.0.0.zip >/dev/null

COPY ./sources/sshd_config /etc/ssh/sshd_config

RUN groupmod -g 9999 nogroup && \
    usermod -g 9999 nobody && \
    usermod -u 9999 nobody && \
    usermod -g 9999 sync && \
    usermod -g 9999 _apt && \
    apt update && \
    apt install -y unzip \
                   samba \
                   samba-dev \
                   php-zip \
                   php-gd \
                   php-dom \
                   php-mbstring \
                   libsmbclient-dev \
                   php-intl \
                   libmagickwand-dev \
                   imagemagick \
                   unrar \
                   ack-grep \
                   php-apcu \
                   p7zip \
                   p7zip-full \
                   librsvg2-dev \
                   openssh-server \
                   rar && \
    echo "apc.enable_cli=1" >> /etc/php/8.4/cli/conf.d/20-apcu.ini && \
    \
    mkdir -p /etc/my_init.d && \
    chmod +x /etc/my_init.d/10_upgrade_preflight.sh /etc/my_init.d/30_installer.sh && \
    apt autoremove -y && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

EXPOSE 80

CMD ["/sbin/my_init"]
