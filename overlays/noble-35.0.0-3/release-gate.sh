#!/usr/bin/env bash
# Release gate for repo.cylo.net/nextcloud:35.0.0-3, the deployed Ubuntu 24.04
# 35.0.0-2 image with only its php8.3 packages upgraded.
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
#
# Against the deployed base digest it checks: one added layer, identical
# runtime configuration (env including NEXTCLOUD_VER, command, ports, user),
# identical non-php8.3 packages, the same set of php8.3 packages, identical
# installer, /app-sources, PHP, nginx and service files, and identical CLI and
# FPM module lists. It also runs php-fpm8.3 -t, nginx -t, a multipart upload
# with the CLI server, and a PHP page plus multipart upload served through
# nginx and php-fpm8.3. Finally it runs the 35.0.0-2 release checks on the
# new image: a fresh install, the 3G PHP memory limit, a multipart upload
# through the installed site, and a restart.
set -euo pipefail

release_ref=repo.cylo.net/nextcloud:35.0.0-3
trial_ref=local/nextcloud-trial:35.0.0-3
base_ref=repo.cylo.net/nextcloud@sha256:e840fc9dcf952c7555872534c2c12e7cea16cd00e556be542e570ea400ae3b2e
php_source=php8.3
php_cli=php8.3
php_fpm=php-fpm8.3
min_arg=PHP83_MIN_VERSION
compared_paths="/etc/php /etc/my_init.d /app-sources /etc/nginx /etc/service /etc/container_environment /etc/cron.d /etc/ssh/sshd_config /scripts /sbin/my_init"
gate_dir=$(cd "$(dirname "$0")" && pwd)

usage() {
    echo "Usage: $0 $release_ref  (or $trial_ref for a trial build)" >&2
    exit 2
}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[ "$#" -eq 1 ] || usage
case "$1" in
    "$release_ref") mode=release ;;
    "$trial_ref") mode=trial ;;
    *) usage ;;
esac
image_ref=$1

test_name="nextcloud-release-gate-$$"
work=$(mktemp -d)
cleanup() {
    docker rm -f "$test_name" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

in_image() {
    local ref=$1
    shift
    docker run --rm --network none -v "$gate_dir/release:/release:ro" --entrypoint sh "$ref" "$@"
}

echo "== Image and base ($mode)"
docker image inspect "$base_ref" >/dev/null 2>&1 || docker pull -q "$base_ref" >/dev/null
platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image_ref")
[ "$platform" = linux/amd64 ] || fail "wrong image platform: $platform"

config_filter='{Env, Cmd, Entrypoint, User, WorkingDir, ExposedPorts, Volumes, StopSignal, Shell, Healthcheck}'
diff -u <(docker image inspect --format '{{json .Config}}' "$base_ref" | jq -S "$config_filter") \
    <(docker image inspect --format '{{json .Config}}' "$image_ref" | jq -S "$config_filter") \
    || fail "runtime configuration differs from the deployed base"
docker image inspect --format '{{json .Config.Env}}' "$image_ref" | jq -r '.[]' | grep '^NEXTCLOUD_VER='

docker image inspect --format '{{json .RootFS.Layers}}' "$base_ref" | jq -r '.[]' > "$work/base-layers"
docker image inspect --format '{{json .RootFS.Layers}}' "$image_ref" | jq -r '.[]' > "$work/image-layers"
[ "$(wc -l < "$work/image-layers")" -eq "$(( $(wc -l < "$work/base-layers") + 1 ))" ] \
    || fail "expected exactly one layer on top of the deployed base"
head -n "$(wc -l < "$work/base-layers")" "$work/image-layers" | cmp -s - "$work/base-layers" \
    || fail "image is not built on the deployed base layers"
echo "one layer on top of $base_ref"

echo "== $php_source packages"
pinned_min=$(sed -n "s/^ARG $min_arg=\\([A-Za-z0-9.+~-]*\\)\$/\\1/p" "$gate_dir/Dockerfile")
[ -n "$pinned_min" ] && [ "$(printf '%s\n' "$pinned_min" | wc -l)" -eq 1 ] \
    || fail "could not read one ARG $min_arg from $gate_dir/Dockerfile"
built_min=$(docker image inspect --format '{{index .Config.Labels "net.cylo.php-min-version"}}' "$image_ref")
[ -n "$built_min" ] || fail "image has no net.cylo.php-min-version label"
if [ "$mode" = release ]; then
    [ "$built_min" = "$pinned_min" ] \
        || fail "image was built with $min_arg=$built_min; the pinned release minimum is $pinned_min"
    check_min=$pinned_min
else
    check_min=$built_min
fi
in_image "$image_ref" /release/check-php-packages.sh "$php_source" "$check_min" \
    || fail "$php_source packages do not satisfy the minimum $check_min"
if [ "$mode" = trial ]; then
    if in_image "$image_ref" /release/check-php-packages.sh "$php_source" "$pinned_min" >/dev/null 2>&1; then
        echo "TRIAL: this image already satisfies the release pin $pinned_min"
    else
        echo "TRIAL: this image does not satisfy the release pin $pinned_min, so release mode would refuse it"
    fi
fi

echo "== Required fixes in the $php_source changelog"
fixes=$(sed -e 's/#.*//' "$gate_dir/release/required-fixes.txt" | grep -o 'CVE-[0-9]\{4\}-[0-9]\{4,\}' | sort -u) || true
# shellcheck disable=SC2086
in_image "$image_ref" /release/changelog-fixes.sh "$php_source" $fixes > "$work/fixes" \
    || fail "cannot read the $php_source changelog"
cat "$work/fixes"
[ "$(sed -n 's/^installed //p' "$work/fixes")" = "$(sed -n 's/^changelog //p' "$work/fixes")" ] \
    || fail "the $php_source-common changelog does not match the installed version"
missing=$(sed -n 's/^absent //p' "$work/fixes" | tr '\n' ' ')
if [ "$mode" = release ]; then
    [ -n "$fixes" ] || fail "release/required-fixes.txt lists no CVE ids; add the ids from the Ubuntu security notice"
    [ -z "$missing" ] || fail "the $php_source changelog does not mention: $missing"
elif [ -z "$fixes" ]; then
    echo "TRIAL: release/required-fixes.txt lists no CVE ids, so release mode would refuse"
elif [ -n "$missing" ]; then
    echo "TRIAL: not in this image (expected before Ubuntu publishes the fix): $missing"
fi

echo "== Other packages unchanged"
dpkg_list='dpkg-query -W -f="\${db:Status-Abbrev}|\${binary:Package}|\${source:Package}|\${Version}\n"'
in_image "$base_ref" -c "$dpkg_list" | sort > "$work/base-dpkg"
in_image "$image_ref" -c "$dpkg_list" | sort > "$work/image-dpkg"
diff -u <(awk -F'|' '{print $1 "|" $2}' "$work/base-dpkg") <(awk -F'|' '{print $1 "|" $2}' "$work/image-dpkg") \
    || fail "installed package set differs from the deployed base"
diff -u <(awk -F'|' -v src="$php_source" '$3 != src' "$work/base-dpkg") \
    <(awk -F'|' -v src="$php_source" '$3 != src' "$work/image-dpkg") \
    || fail "packages not built from $php_source changed"
changed_php=$(awk -F'|' -v src="$php_source" 'NR == FNR { if ($3 == src) old[$2] = $4; next }
    $3 == src && old[$2] != $4 { n++ } END { print n + 0 }' "$work/base-dpkg" "$work/image-dpkg")
echo "$(wc -l < "$work/image-dpkg") packages; $changed_php $php_source packages upgraded, nothing else changed"

echo "== Installer, sources and configuration unchanged"
# shellcheck disable=SC2086
in_image "$base_ref" /release/file-manifest.sh $compared_paths > "$work/base-files"
# shellcheck disable=SC2086
in_image "$image_ref" /release/file-manifest.sh $compared_paths > "$work/image-files"
diff -u "$work/base-files" "$work/image-files" \
    || fail "files under $compared_paths differ from the deployed base"
echo "$(wc -l < "$work/image-files") paths identical"

echo "== PHP modules"
diff -u <(docker run --rm --network none --entrypoint "$php_fpm" "$base_ref" -m) \
    <(docker run --rm --network none --entrypoint "$php_fpm" "$image_ref" -m) \
    || fail "$php_fpm module list differs from the deployed base"
diff -u <(docker run --rm --network none --entrypoint "$php_cli" "$base_ref" -m) \
    <(docker run --rm --network none --entrypoint "$php_cli" "$image_ref" -m) \
    || fail "$php_cli module list differs from the deployed base"
echo "CLI and FPM module lists identical"

echo "== FPM and nginx configuration"
docker run --rm --network none --entrypoint "$php_fpm" "$image_ref" -t \
    || fail "$php_fpm configuration test failed"
docker run --rm --network none --entrypoint nginx "$image_ref" -t \
    || fail "nginx configuration test failed"

echo "== Multipart upload"
in_image "$image_ref" /release/multipart-smoke.sh "$php_cli" \
    || fail "multipart upload smoke test failed"

echo "== PHP page and multipart upload through nginx and $php_fpm"
in_image "$image_ref" /release/fpm-smoke.sh "$php_fpm" \
    || fail "nginx and $php_fpm smoke test failed"

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

# A multipart upload through the installed nginx site and php-fpm8.3. The
# container restart below discards the swapped status.php from opcache.
docker exec "$test_name" /bin/bash -ec '
    cp /home/appbox/public_html/status.php /tmp/cylo-status.php.backup
    printf "<?php echo count(\$_FILES), \":\", \$_FILES[\"f\"][\"size\"] ?? -1, \":\", \$_POST[\"a\"] ?? \"\";\n" > /home/appbox/public_html/status.php
    chown appbox:appbox /home/appbox/public_html/status.php
    printf hello > /tmp/cylo-upload.txt
    sv restart phpfpm >/dev/null
    result=
    for attempt in $(seq 1 20); do
        result=$(curl -sS --max-time 10 -F a=b -F f=@/tmp/cylo-upload.txt http://localhost/status.php) && [ "$result" = 1:5:b ] && break
        sleep 1
    done
    cp /tmp/cylo-status.php.backup /home/appbox/public_html/status.php
    chown appbox:appbox /home/appbox/public_html/status.php
    rm /tmp/cylo-status.php.backup /tmp/cylo-upload.txt
    if [ "$result" != 1:5:b ]; then
        echo "multipart upload through nginx and php-fpm8.3 returned \"$result\", expected 1:5:b" >&2
        exit 1
    fi
    echo "multipart upload parsed through the installed nginx site and php-fpm8.3"
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
    echo "TRIAL PASSED: $image_ref ($php_source at the trial minimum $check_min; $release_ref absent). Not releasable: built without the release pin $pinned_min."
else
    echo "PASS: $release_ref ($php_source >= $check_min, everything else as deployed, fresh install, restart, PHP 3G, uploads, tag absent)"
fi
