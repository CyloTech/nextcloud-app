#!/bin/bash
# MySQL 8.4 compatibility for a mysqld.cnf written for MySQL 8.0. Runs before
# the base 20_installer.sh, whose mysql.sh copies /sources/mysqld.cnf over the
# volume copy and starts MySQL 8.4 on the existing data directory.
set -euo pipefail

expire_re='expire[-_]logs[-_]days'

# Keep the volume copy as it was before this image first changed it.
save_original() {
    if [ "$1" = /home/appbox/config/mysql/mysqld.cnf ] && [ ! -e "$1.pre-nextcloud35" ]; then
        cp -p "$1" "$1.pre-nextcloud35"
    fi
}

for config in /sources/mysqld.cnf /home/appbox/config/mysql/mysqld.cnf; do
    [ -f "$config" ] || continue

    # MySQL 8.4 refuses to start with expire_logs_days in either spelling.
    days=$(sed -nE "s/^[[:space:]]*${expire_re}[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*\$/\\1/p" "$config")
    if [ -z "$days" ]; then
        if grep -Eq "^[[:space:]]*${expire_re}[[:space:]]*=" "$config"; then
            echo "Unrecognized expire_logs_days value in $config" >&2
            exit 1
        fi
    else
        if [ "$(printf '%s\n' "$days" | wc -l)" -ne 1 ]; then
            echo "More than one expire_logs_days line in $config" >&2
            exit 1
        fi
        if [[ ! $days =~ ^[0-9]+$ ]]; then
            echo "Invalid expire_logs_days value in $config" >&2
            exit 1
        fi
        seconds=$((10#$days * 86400))
        if [ "$seconds" -gt 4294967295 ]; then
            echo "expire_logs_days exceeds the MySQL 8.4 range in $config" >&2
            exit 1
        fi
        save_original "$config"
        sed -i -E "s/^[[:space:]]*${expire_re}[[:space:]]*=[[:space:]]*[0-9]+[[:space:]]*\$/binlog_expire_logs_seconds = $seconds/" "$config"
    fi

    # Nextcloud 31 and older created its database user with
    # mysql_native_password, which MySQL 8.4 only loads when this is set.
    if ! grep -Eq '^[[:space:]]*mysql[-_]native[-_]password[[:space:]]*=' "$config"; then
        if ! grep -Eq '^[[:space:]]*\[mysqld\][[:space:]]*$' "$config"; then
            echo "No [mysqld] section in $config" >&2
            exit 1
        fi
        save_original "$config"
        sed -i -E '/^[[:space:]]*\[mysqld\][[:space:]]*$/a mysql_native_password = ON' "$config"
    fi

    # MySQL 8.4 keeps its error messages in /usr/share/mysql-8.4.
    if grep -Eq '^[[:space:]]*lc-messages-dir[[:space:]]*=[[:space:]]*/usr/share/mysql/?[[:space:]]*$' "$config" \
        && [ ! -f /usr/share/mysql/english/errmsg.sys ] && [ -f /usr/share/mysql-8.4/english/errmsg.sys ]; then
        save_original "$config"
        sed -i -E 's#^([[:space:]]*lc-messages-dir[[:space:]]*=[[:space:]]*)/usr/share/mysql/?[[:space:]]*$#\1/usr/share/mysql-8.4#' "$config"
    fi
done
