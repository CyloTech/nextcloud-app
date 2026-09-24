#!/usr/bin/env bash
set -euo pipefail

expected_ref=repo.cylo.net/nextcloud:35.0.0-2
if [ "$#" -ne 1 ] || [ "$1" != "$expected_ref" ]; then
    echo "Usage: $0 $expected_ref" >&2
    exit 2
fi
image_ref=$1
test_name="nextcloud-release-gate-$$"

cleanup() {
    docker rm -f "$test_name" >/dev/null 2>&1 || true
}
trap cleanup EXIT

platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image_ref")
[ "$platform" = linux/amd64 ] || { echo "Wrong image platform: $platform" >&2; exit 1; }

docker run --rm --entrypoint /bin/bash "$image_ref" -ec '
    php -v | head -n 1 | grep -q "PHP 8.3"
    php-fpm8.3 -v | head -n 1 | grep -q "PHP 8.3"
    nginx -v 2>&1 | grep -Eq "nginx/1\.30\."
    mysqld --version | grep -q "8.4."
    [ "$(php -r "echo ini_get(\"memory_limit\");")" = 3G ]
    [ "$(php-fpm8.3 -i 2>/dev/null | sed -n "s/^memory_limit => \([^ ]*\) =>.*/\1/p" | head -n 1)" = 3G ]
    test -f /app-sources/nextcloud-35.0.0.zip
    /app-sources/verify-nextcloud-archive.sh 35.0.0
    php -m | grep -Eq "^(apcu|APCu)$"
    php -m | grep -q pdo_mysql
    php -m | grep -q imagick
'

docker run -d --name "$test_name" --hostname "$test_name" \
    --memory 4g --memory-swap 4g --tmpfs /ssl \
    -e "HOSTNAME=$test_name" -e APP_APEX_CALLBACK=false \
    "$image_ref" >/dev/null

# Appbox supplies these files as a mount. Use a short-lived synthetic
# certificate in the disposable container so nginx can validate both sites.
docker exec "$test_name" openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout /ssl/key.pem -out /ssl/cert.pem \
    -subj "/CN=$test_name" -days 1 >/dev/null 2>&1

wait_for_install() {
    local attempt
    for attempt in $(seq 1 180); do
        if [ "$(docker inspect --format '{{.State.Running}}' "$test_name")" != true ]; then
            echo 'Fresh-install container exited before completion.' >&2
            return 1
        fi
        if docker exec "$test_name" test -f /etc/app_installer_completed; then
            return 0
        fi
        sleep 5
    done
    echo 'Fresh-install container did not complete within 15 minutes.' >&2
    return 1
}

wait_for_health() {
    local attempt
    for attempt in $(seq 1 60); do
        if docker exec "$test_name" /bin/bash -ec '
            curl -fsS --max-time 10 http://localhost/status.php | grep -q "35.0.0"
            su -s /bin/sh -c "cd /home/appbox/public_html && php occ status --output=json" appbox | grep -q "\"installed\":true"
        ' >/dev/null 2>&1; then
            return 0
        fi
        sleep 5
    done
    echo 'Nextcloud did not become healthy within 5 minutes after installer completion.' >&2
    return 1
}

wait_for_install
wait_for_health
docker exec "$test_name" /bin/bash -ec '
    [ "$(php -r "echo ini_get(\"memory_limit\");")" = 3G ]
    grep -q php-fpm8.3 /etc/service/phpfpm/run
    grep -q php8.3-fpm.sock /home/appbox/config/nginx/sites-enabled/nextcloud.conf
    php-fpm8.3 -tt --fpm-config /home/appbox/config/php-fpm/php-fpm.conf 2>&1 | grep -F "php_admin_value[memory_limit] = 3G" >/dev/null
    nginx -t -c /home/appbox/config/nginx/nginx.conf
    curl -fsS http://localhost/status.php | grep -q "35.0.0"
    su -s /bin/sh -c "cd /home/appbox/public_html && php occ status --output=json" appbox | grep -q "\"installed\":true"
'

# Confirm a Nextcloud .user.ini override cannot lower the web PHP limit.
docker exec "$test_name" /bin/bash -ec '
    cp /home/appbox/public_html/.user.ini /tmp/cylo-user.ini.backup
    printf "\nmemory_limit=128M\n" >> /home/appbox/public_html/.user.ini
    printf "<?php echo ini_get(\"memory_limit\");\n" > /home/appbox/public_html/cylo-memory-probe.php
    chown appbox:appbox /home/appbox/public_html/cylo-memory-probe.php
    test "$(curl -fsS http://localhost/cylo-memory-probe.php)" = 3G
    rm /home/appbox/public_html/cylo-memory-probe.php
    cp /tmp/cylo-user.ini.backup /home/appbox/public_html/.user.ini
    chown appbox:appbox /home/appbox/public_html/.user.ini
    rm /tmp/cylo-user.ini.backup
'

docker restart "$test_name" >/dev/null
# Docker clears tmpfs contents on restart; Appbox's real /ssl mount persists.
# Restore the test certificate before checking nginx after the restart.
docker exec "$test_name" openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout /ssl/key.pem -out /ssl/cert.pem \
    -subj "/CN=$test_name" -days 1 >/dev/null 2>&1
wait_for_install
wait_for_health
docker exec "$test_name" /bin/bash -ec '
    curl -fsS http://localhost/status.php | grep -q "35.0.0"
    [ "$(php -r "echo ini_get(\"memory_limit\");")" = 3G ]
    php-fpm8.3 -tt --fpm-config /home/appbox/config/php-fpm/php-fpm.conf 2>&1 | grep -F "php_admin_value[memory_limit] = 3G" >/dev/null
'

set +e
registry_result=$(docker manifest inspect "$image_ref" 2>&1)
registry_status=$?
set -e
if [ "$registry_status" -eq 0 ]; then
    echo "Registry tag already exists: $image_ref" >&2
    exit 1
fi
if [ "$registry_status" -ne 1 ] || [ "$registry_result" != "no such manifest: $image_ref" ]; then
    echo "Registry precondition indeterminate: $registry_result" >&2
    exit 1
fi

echo "Release gate passed: fresh install, restart, PHP 3G, and unused tag $image_ref"
