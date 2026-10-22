#!/bin/bash
# Copies a MySQL 8.0 data directory once, before MySQL 8.4 first starts on it
# (the base 20_installer.sh runs mysqld --upgrade=FORCE next). MySQL 8.0
# cannot open a data directory that 8.4 has upgraded, so this copy is the way
# back to an image with MySQL 8.0. When the volume has too little free space
# the copy is skipped with a message and the upgrade goes ahead without it.
#
# Going back: stop the container, move data.mysql80-backup to data (keeping
# the upgraded directory aside), remove the 'redis', 'memcache.locking' and
# 'memcache.distributed' entries from config.php, and start the earlier image.
set -euo pipefail

datadir=/home/appbox/mysql/data
backup=/home/appbox/mysql/data.mysql80-backup
partial=$backup.partial

# Only a MySQL 8.0 data directory: 8.0 records its version in
# mysql_upgrade_info; MySQL 8.4 records its upgrades in mysql_upgrade_history.
[ -f "$datadir/mysql.ibd" ] || exit 0
[ -f "$datadir/mysql_upgrade_info" ] || exit 0
grep -Eq '^8\.0\.[0-9]+' "$datadir/mysql_upgrade_info" || exit 0
[ ! -e "$datadir/mysql_upgrade_history" ] || exit 0

if [ -e "$backup" ]; then
    echo "A copy of the MySQL 8.0 data directory is already in $backup"
    exit 0
fi
rm -rf "$partial"

needed_kb=$(( $(du -sk "$datadir" | cut -f1) * 11 / 10 ))
avail_kb=$(df -Pk "$(dirname "$datadir")" | awk 'NR == 2 {print $4}')
if [ "$avail_kb" -lt "$needed_kb" ]; then
    echo "Not copying the MySQL 8.0 data directory before the MySQL 8.4 upgrade: it needs ${needed_kb} KB and ${avail_kb} KB are free" >&2
    exit 0
fi

echo "Copying the MySQL 8.0 data directory to $backup before the MySQL 8.4 upgrade"
if cp -a --reflink=auto "$datadir" "$partial"; then
    mv "$partial" "$backup"
    echo "MySQL 8.0 data directory copied to $backup"
else
    rm -rf "$partial"
    echo "Copying the MySQL 8.0 data directory failed; continuing without a copy" >&2
fi
