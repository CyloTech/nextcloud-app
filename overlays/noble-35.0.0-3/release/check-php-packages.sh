#!/bin/sh
# Usage: check-php-packages.sh <php source package> <minimum version>
#
# Exits 0 only when every installed binary package built from the given
# Ubuntu source package (for example php8.3) is at one single version and
# that version is at least the minimum. Used by the Dockerfile while building
# and by the release gate against the finished image.
set -eu

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <php source package> <minimum version>" >&2
    exit 2
fi
source_pkg=$1
min_version=$2
case "$source_pkg" in
    php[0-9].[0-9]) ;;
    *) echo "unexpected source package name: $source_pkg" >&2; exit 2 ;;
esac
case "$min_version" in
    ''|*[!A-Za-z0-9.+~-]*) echo "invalid minimum version: $min_version" >&2; exit 2 ;;
esac

installed=$(dpkg-query -W -f='${db:Status-Abbrev}|${binary:Package}|${source:Package}|${Version}\n' \
    | awk -F'|' -v src="$source_pkg" '$1 ~ /^ii/ && $3 == src {print $2 " " $4}' | sort)
if [ -z "$installed" ]; then
    echo "no installed packages are built from $source_pkg" >&2
    exit 1
fi
echo "$installed"

versions=$(printf '%s\n' "$installed" | awk '{print $2}' | sort -u)
if [ "$(printf '%s\n' "$versions" | wc -l)" -ne 1 ]; then
    echo "$source_pkg packages are not all at one version:" >&2
    printf '%s\n' "$versions" >&2
    exit 1
fi
if ! dpkg --compare-versions "$versions" ge "$min_version"; then
    echo "$source_pkg $versions is older than the required minimum $min_version" >&2
    exit 1
fi
echo "$(printf '%s\n' "$installed" | wc -l) $source_pkg packages at $versions (minimum $min_version)"
