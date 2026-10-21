#!/bin/sh
# Usage (inside the image): changelog-fixes.sh <php source package> [<CVE id>...]
#
# Prints the installed version of <source>-common, the newest version in its
# Debian changelog, and whether each CVE id appears in that changelog.
set -eu

src=$1
shift
log=/usr/share/doc/$src-common/changelog.Debian.gz
installed=$(dpkg-query -W -f='${Version}' "$src-common")
[ -f "$log" ] || { echo "missing $log" >&2; exit 1; }
top=$(zcat "$log" | sed -n '1s/^[^ ]* (\([^)]*\)).*/\1/p')
echo "installed $installed"
echo "changelog $top"
for id in "$@"; do
    if zcat "$log" | grep -q -- "$id"; then
        echo "present $id"
    else
        echo "absent $id"
    fi
done
