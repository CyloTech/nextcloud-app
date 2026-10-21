#!/bin/sh
# Keep the Nextcloud version that is already installed on the volume.
#
# The 22.04 installer (30_installer.sh) runs on every container recreate. It
# downloads nextcloud-$NEXTCLOUD_VER.zip, unpacks it over public_html and runs
# 'occ upgrade', so an installation newer than the image's NEXTCLOUD_VER would
# be downgraded and an older one silently upgraded. Before the installer runs,
# point NEXTCLOUD_VER at the installed version; my_init reloads
# /etc/container_environment after each startup script, so 30_installer.sh
# then unpacks the version that is already installed and 'occ upgrade' has
# nothing to do. Fresh installs and container restarts are unaffected.
set -eu

version_file=/home/appbox/public_html/version.php
env_file=/etc/container_environment/NEXTCLOUD_VER

if [ -f /etc/app_installer_completed ]; then
    exit 0
fi
if [ ! -f "$version_file" ]; then
    echo "No installed Nextcloud found; using the image's NEXTCLOUD_VER=${NEXTCLOUD_VER:-}"
    exit 0
fi

installed=$(sed -n "s/^[[:space:]]*[$]OC_VersionString[[:space:]]*=[[:space:]]*'\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)'[[:space:]]*;.*\$/\1/p" "$version_file" | head -n 1)
case "$installed" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *)
        echo "Could not read the installed Nextcloud version from $version_file; using NEXTCLOUD_VER=${NEXTCLOUD_VER:-}"
        exit 0
        ;;
esac

if [ "$installed" != "${NEXTCLOUD_VER:-}" ]; then
    echo "Installed Nextcloud is $installed; keeping it instead of the image's NEXTCLOUD_VER=${NEXTCLOUD_VER:-}"
fi
mkdir -p /etc/container_environment
printf '%s' "$installed" > "$env_file"
