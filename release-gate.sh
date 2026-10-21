#!/usr/bin/env bash
# Release gate for repo.cylo.net/nextcloud:35.0.0-3.
#
# Usage: ./release-gate.sh repo.cylo.net/nextcloud:35.0.0-3   (release)
#        ./release-gate.sh local/nextcloud-trial:35.0.0-3     (trial)
#
# Release mode requires the image to have been built with the php8.3 minimum
# pinned in the Dockerfile (ARG PHP83_MIN_VERSION). Trial mode accepts the
# minimum the trial image was built with (--build-arg PHP83_MIN_VERSION=<the
# current version>), so every other check can be exercised before Ubuntu
# publishes the fix. Release mode also requires every CVE id listed in
# release/required-fixes.txt to appear in the php8.3-common changelog; trial
# mode only reports them. Trial images are never pushed. Both modes require
# the release tag to be absent from the registry.
set -euo pipefail

release_ref=repo.cylo.net/nextcloud:35.0.0-3
trial_ref=local/nextcloud-trial:35.0.0-3
# The deployed 35.0.0-2 image; the PHP module lists must not change.
deployed_ref=repo.cylo.net/nextcloud@sha256:e840fc9dcf952c7555872534c2c12e7cea16cd00e556be542e570ea400ae3b2e
gate_dir=$(cd "$(dirname "$0")" && pwd)

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 $release_ref  (or $trial_ref for a trial build)" >&2
    exit 2
fi
case "$1" in
    "$release_ref") mode=release ;;
    "$trial_ref") mode=trial ;;
    *)
        echo "Usage: $0 $release_ref  (or $trial_ref for a trial build)" >&2
        exit 2
        ;;
esac
image_ref=$1
test_name="nextcloud-release-gate-$$"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

work=$(mktemp -d)
cleanup() {
    docker rm -f "$test_name" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image_ref")
[ "$platform" = linux/amd64 ] || { echo "Wrong image platform: $platform" >&2; exit 1; }

echo "== php8.3 packages ($mode)"
pinned_min=$(sed -n 's/^ARG PHP83_MIN_VERSION=\([A-Za-z0-9.+~-]*\)$/\1/p' "$gate_dir/Dockerfile")
[ -n "$pinned_min" ] && [ "$(printf '%s\n' "$pinned_min" | wc -l)" -eq 1 ] \
    || fail "could not read one ARG PHP83_MIN_VERSION from $gate_dir/Dockerfile"
built_min=$(docker image inspect --format '{{index .Config.Labels "net.cylo.php-min-version"}}' "$image_ref")
[ -n "$built_min" ] || fail "image has no net.cylo.php-min-version label"
if [ "$mode" = release ]; then
    [ "$built_min" = "$pinned_min" ] \
        || fail "image was built with PHP83_MIN_VERSION=$built_min; the pinned release minimum is $pinned_min"
    check_min=$pinned_min
else
    check_min=$built_min
fi
docker run --rm --network none -v "$gate_dir/release:/release:ro" --entrypoint sh "$image_ref" \
    /release/check-php-packages.sh php8.3 "$check_min" \
    || fail "php8.3 packages do not satisfy the minimum $check_min"
if [ "$mode" = trial ]; then
    if docker run --rm --network none -v "$gate_dir/release:/release:ro" --entrypoint sh "$image_ref" \
        /release/check-php-packages.sh php8.3 "$pinned_min" >/dev/null 2>&1; then
        echo "TRIAL: this image already satisfies the release pin $pinned_min"
    else
        echo "TRIAL: this image does not satisfy the release pin $pinned_min, so release mode would refuse it"
    fi
fi

echo "== Required fixes in the php8.3 changelog"
fixes=$(sed -e 's/#.*//' "$gate_dir/release/required-fixes.txt" | grep -o 'CVE-[0-9]\{4\}-[0-9]\{4,\}' | sort -u) || true
# shellcheck disable=SC2086
docker run --rm --network none -v "$gate_dir/release:/release:ro" --entrypoint sh "$image_ref" \
    /release/changelog-fixes.sh php8.3 $fixes > "$work/fixes" \
    || fail "cannot read the php8.3 changelog"
cat "$work/fixes"
[ "$(sed -n 's/^installed //p' "$work/fixes")" = "$(sed -n 's/^changelog //p' "$work/fixes")" ] \
    || fail "the php8.3-common changelog does not match the installed version"
missing=$(sed -n 's/^absent //p' "$work/fixes" | tr '\n' ' ')
if [ "$mode" = release ]; then
    [ -n "$fixes" ] || fail "release/required-fixes.txt lists no CVE ids; add the ids from the Ubuntu security notice"
    [ -z "$missing" ] || fail "the php8.3 changelog does not mention: $missing"
elif [ -z "$fixes" ]; then
    echo "TRIAL: release/required-fixes.txt lists no CVE ids, so release mode would refuse"
elif [ -n "$missing" ]; then
    echo "TRIAL: not in this image (expected before Ubuntu publishes the fix): $missing"
fi

echo "== PHP modules against the deployed 35.0.0-2 image"
docker image inspect "$deployed_ref" >/dev/null 2>&1 || docker pull -q "$deployed_ref" >/dev/null
diff -u <(docker run --rm --network none --entrypoint php-fpm8.3 "$deployed_ref" -m) \
    <(docker run --rm --network none --entrypoint php-fpm8.3 "$image_ref" -m) \
    || fail "php-fpm8.3 module list differs from the deployed image"
diff -u <(docker run --rm --network none --entrypoint php8.3 "$deployed_ref" -m) \
    <(docker run --rm --network none --entrypoint php8.3 "$image_ref" -m) \
    || fail "php8.3 CLI module list differs from the deployed image"

echo "== Multipart upload"
docker run --rm --network none -v "$gate_dir/release:/release:ro" --entrypoint sh "$image_ref" \
    /release/multipart-smoke.sh php8.3 \
    || fail "multipart upload smoke test failed"

echo "== Image checks, fresh install and restart"

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
    for attempt in $(seq 1 360); do
        if [ "$(docker inspect --format '{{.State.Running}}' "$test_name")" != true ]; then
            echo 'Fresh-install container exited before completion.' >&2
            return 1
        fi
        if docker exec "$test_name" test -f /etc/app_installer_completed; then
            return 0
        fi
        sleep 5
    done
    echo 'Fresh-install container did not complete within 30 minutes.' >&2
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
    cp /home/appbox/public_html/status.php /tmp/cylo-status.php.backup
    printf "\nmemory_limit=128M\n" >> /home/appbox/public_html/.user.ini
    printf "<?php echo ini_get(\"memory_limit\");\n" > /home/appbox/public_html/status.php
    chown appbox:appbox /home/appbox/public_html/status.php
    sv restart phpfpm
    test "$(curl -fsS http://localhost/status.php)" = 3G
    cp /tmp/cylo-status.php.backup /home/appbox/public_html/status.php
    cp /tmp/cylo-user.ini.backup /home/appbox/public_html/.user.ini
    chown appbox:appbox /home/appbox/public_html/status.php /home/appbox/public_html/.user.ini
    rm /tmp/cylo-status.php.backup /tmp/cylo-user.ini.backup
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

echo "== Registry tag must not exist"
"$gate_dir/release/registry-absent.sh" "$release_ref" \
    || fail "registry precondition for $release_ref not met"

if [ "$mode" = trial ]; then
    echo "TRIAL PASSED: $image_ref (fresh install, restart, PHP 3G, php8.3 at the trial minimum $check_min, modules, multipart upload; $release_ref absent). Not releasable: built without the release pin."
else
    echo "Release gate passed: fresh install, restart, PHP 3G, php8.3 >= $check_min, modules, multipart upload, and unused tag $release_ref"
fi
