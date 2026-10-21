# Nextcloud 27.1.5-1: the newest deployed Ubuntu 22.04 image (nextcloud:27.1.5)
# with only its php8.1 packages upgraded, plus a startup script that keeps the
# Nextcloud version already installed on the volume. The installer, the
# configuration and every other package stay exactly as deployed;
# release-gate.sh checks that.
FROM repo.cylo.net/nextcloud@sha256:3e0c085feeef8cddbc150598fc2c71c6aef242892ca03aaafbe203d3771d54fe

# Release pin: the first Ubuntu jammy php8.1 version that contains the fixes
# from the PHP security release of 21 October 2026 (multipart/form-data
# parsing). The build fails unless every installed package built from the
# php8.1 source ends up at one version that is at least this one, so it cannot
# succeed before Ubuntu publishes the fix. release-gate.sh reads this line.
ARG PHP81_MIN_VERSION=8.1.2-1ubuntu2.28
LABEL net.cylo.php-min-version="${PHP81_MIN_VERSION}"

# Upgrade only the installed php8.1 packages; keep existing configuration.
RUN --mount=type=bind,source=release/check-php-packages.sh,target=/tmp/check-php-packages.sh \
    set -eux; \
    apt-get update; \
    php_packages=$(dpkg-query -W -f='${db:Status-Abbrev}|${binary:Package}|${source:Package}\n' \
        | awk -F'|' '$1 ~ /^ii/ && $3 == "php8.1" {print $2}'); \
    test -n "$php_packages"; \
    DEBIAN_FRONTEND=noninteractive UCF_FORCE_CONFFOLD=1 apt-get install -y --no-install-recommends --only-upgrade \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
        $php_packages; \
    sh /tmp/check-php-packages.sh php8.1 "$PHP81_MIN_VERSION"; \
    php-fpm8.1 -t; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# Keep the installed Nextcloud version when the container is recreated.
COPY --chmod=0755 29_keep_installed_nextcloud.sh /etc/my_init.d/29_keep_installed_nextcloud.sh
