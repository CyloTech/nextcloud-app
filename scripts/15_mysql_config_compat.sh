#!/bin/bash
set -euo pipefail

for config in /sources/mysqld.cnf /home/appbox/config/mysql/mysqld.cnf; do
    [ -f "$config" ] || continue
    days=$(sed -nE 's/^[[:space:]]*expire_logs_days[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*$/\1/p' "$config")
    if [ -z "$days" ]; then
        if grep -Eq '^[[:space:]]*expire_logs_days[[:space:]]*=' "$config"; then
            echo "Unrecognized expire_logs_days value in $config" >&2
            exit 1
        fi
        continue
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
    if [ "$config" = /home/appbox/config/mysql/mysqld.cnf ] && [ ! -e "$config.pre-nextcloud35" ]; then
        cp -p "$config" "$config.pre-nextcloud35"
    fi
    sed -i -E "s/^[[:space:]]*expire_logs_days[[:space:]]*=[[:space:]]*[0-9]+[[:space:]]*$/binlog_expire_logs_seconds = $seconds/" "$config"
done
