# Nextcloud 35.0.0-3: the deployed Ubuntu 24.04 35.0.0-2 image with only its
# php8.3 packages upgraded. Nextcloud, the installer, the configuration and
# every other package stay exactly as deployed; release-gate.sh checks that.
#
# This is an overlay rather than a rebuild of the root Dockerfile: on
# 21 October 2026 the rebuild failed at 'pecl install smbclient' because
# PEAR 1.10.13 rejects PECL's REST files (now served gzip-encoded through a
# CDN) as invalid XML. The overlay keeps the deployed nginx, MySQL, samba
# and smbclient builds and changes only PHP.
FROM repo.cylo.net/nextcloud@sha256:e840fc9dcf952c7555872534c2c12e7cea16cd00e556be542e570ea400ae3b2e

# Release pin: the first Ubuntu noble php8.3 version that contains the fixes
# from the PHP security release of 21 October 2026 (multipart/form-data
# parsing). The build fails unless every installed package built from the
# php8.3 source ends up at one version that is at least this one, so it cannot
# succeed before Ubuntu publishes the fix. release-gate.sh reads this line.
ARG PHP83_MIN_VERSION=8.3.6-0ubuntu0.24.04.13
LABEL net.cylo.php-min-version="${PHP83_MIN_VERSION}"

# Upgrade only the installed php8.3 packages; keep existing configuration.
RUN --mount=type=bind,source=release/check-php-packages.sh,target=/tmp/check-php-packages.sh \
    set -eux; \
    apt-get update; \
    php_packages=$(dpkg-query -W -f='${db:Status-Abbrev}|${binary:Package}|${source:Package}\n' \
        | awk -F'|' '$1 ~ /^ii/ && $3 == "php8.3" {print $2}'); \
    test -n "$php_packages"; \
    DEBIAN_FRONTEND=noninteractive UCF_FORCE_CONFFOLD=1 apt-get install -y --no-install-recommends --only-upgrade \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
        $php_packages; \
    sh /tmp/check-php-packages.sh php8.3 "$PHP83_MIN_VERSION"; \
    php-fpm8.3 -t; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*
