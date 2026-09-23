#!/bin/bash
set -eu

version_file=/home/appbox/public_html/version.php
if [ ! -e "$version_file" ]; then
    exit 0
fi

installed_version=$(awk -F"'" '/^\$OC_VersionString[[:space:]]*=/ { split($2, parts, "."); print parts[1]; exit }' "$version_file")
if [ -z "$installed_version" ]; then
    echo 'Cannot identify the installed Nextcloud major version; refusing to change the database.' >&2
    exit 1
fi

case "$installed_version" in
    34|35) ;;
    *)
        echo "Nextcloud $installed_version must be upgraded through each intervening major release before image 35.0.0 can be installed." >&2
        exit 1
        ;;
esac
