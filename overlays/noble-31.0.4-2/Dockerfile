# Nextcloud 31.0.4-2: the released 31.0.4-1 image (the deployed Ubuntu 24.04
# 'latest' with its php8.3 packages patched) with a corrected
# /etc/my_init.d/30_installer.sh. Every other file, package and setting stays
# exactly as in 31.0.4-1; release-gate.sh checks that.
#
# The installer recorded from the deployed 'latest' moves config/config.php to
# logs/config.php whenever a container is created, and puts it back only on
# its upgrade path. When the installed Nextcloud was already at or above the
# image's version it took the fresh-install path instead, so updating an
# installation to an image with the same Nextcloud version (31.0.4 to
# 31.0.4-1) left it without config.php, showing the setup page. The corrected
# installer (30_installer.sh here; release/30_installer.sh.diff is the change)
# takes the upgrade path for every existing installation (occ upgrade has
# nothing to do when the versions match), puts the saved config.php back
# before nginx and php-fpm start, and never replaces a saved installed
# configuration with an empty or not-installed config.php.
FROM repo.cylo.net/nextcloud@sha256:42472261703048501e6e3eb0ba272c3fc6f495d03337031a68dc9edfb14d0cf8

# Release pin carried over from 31.0.4-1: the first Ubuntu noble php8.3
# version with the fixes from the PHP security release of 21 October 2026.
# This overlay does not change PHP; the build and release-gate.sh check that
# the inherited php8.3 packages still satisfy it.
ARG PHP83_MIN_VERSION=8.3.6-0ubuntu0.24.04.13
LABEL net.cylo.php-min-version="${PHP83_MIN_VERSION}"

# Replace only the installer, and only when the base still has the installer
# the fix was written against (the deployed 'latest' and 31.0.4-1 share it).
# cp keeps the existing file's owner and mode.
RUN --mount=type=bind,source=30_installer.sh,target=/tmp/30_installer.sh \
    --mount=type=bind,source=release/check-php-packages.sh,target=/tmp/check-php-packages.sh \
    set -eu; \
    echo '132f8c91f4821f1a1c0eb86ceedd326ad3b721147b5741f50fd2cfda346480b0  /etc/my_init.d/30_installer.sh' | sha256sum -c -; \
    bash -n /tmp/30_installer.sh; \
    cp /tmp/30_installer.sh /etc/my_init.d/30_installer.sh; \
    cmp /tmp/30_installer.sh /etc/my_init.d/30_installer.sh; \
    sh /tmp/check-php-packages.sh php8.3 "$PHP83_MIN_VERSION"
