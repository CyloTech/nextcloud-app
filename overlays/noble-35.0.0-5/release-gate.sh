#!/usr/bin/env bash
# Release gate for repo.cylo.net/nextcloud:35.0.0-5, the released 35.0.0-4
# image with PHP 8.4 in place of PHP 8.3, Redis for file locking and the
# distributed cache, and support for installations still on MySQL 8.0.
#
# Usage: ./release-gate.sh repo.cylo.net/nextcloud:35.0.0-5   (release)
#        ./release-gate.sh local/nextcloud-trial:35.0.0-5     (trial)
#
# Release mode requires the image to have been built with the php8.4 minimum
# pinned in the Dockerfile (ARG PHP84_MIN_VERSION) and every CVE id in
# release/required-fixes.txt to appear in the php8.4-common changelog. Trial
# mode accepts the minimum the trial image was built with and only reports
# missing CVE ids. Trial images are never pushed. Both modes require the
# release tag to be absent from the registry.
#
# Against the 35.0.0-4 base it checks:
#   - one added layer and identical runtime configuration;
#   - php8.4 at or above the pinned minimum, no php8.3 or php8.5, nothing
#     from the PPA other than php8.4 packages and php-common, and exactly the
#     package additions, removals and upgrades in release/package-changes.txt;
#   - exactly the file changes in release/file-changes.txt (outside
#     /etc/php), the overlay's own scripts and Redis files in place, and the
#     edits to base files exactly as in release/base-edits.diff;
#   - the CLI and FPM module lists of 35.0.0-4 without geos and sass (no 8.4
#     builds) and with http and raphf (which 35.0.0-4 fails to load);
#   - php-fpm8.4 -t, nginx -t, multipart uploads through the CLI server and
#     through nginx and php-fpm8.4, Imagick SVG support, smbclient and Redis.
# It then installs Nextcloud and checks the 3G PHP limit, an upload through
# the installed site, PHP 8.4 behind nginx, Redis on its socket only, the
# setup checks for the PHP version, database version, file locking and
# memcache, and a restart. Finally it runs the update tests on host
# directories mounted as Appbox mounts them (release/recreate-regression.sh
# and release/mysql80-upgrade.sh):
#   - new image installed, recreated, recreated again with the installed
#     version reporting newer than the image;
#   - 35.0.0-4 installed and updated to the new image: config.php gains only
#     the Redis entries, no setup check gets worse, and the four checks above
#     pass; recreated once more without changes;
#   - 35.0.0-2 installed and updated to the new image;
#   - 31.0.4-2 installed (MySQL 8.0), Nextcloud upgraded in place to 35.0.2,
#     stopped cleanly, updated to the new image (MySQL 8.4 upgrade), then
#     taken back to 31.0.4-2 from the MySQL 8.0 copy;
#   - the same installation killed instead of stopped, then updated.
set -euo pipefail

release_ref=repo.cylo.net/nextcloud:35.0.0-5
trial_ref=local/nextcloud-trial:35.0.0-5
# 35.0.0-4, the image this overlay is built on and the current default.
base_ref=repo.cylo.net/nextcloud@sha256:5ffeef884defcb09fd788d04aa2fb6560d4d1c559e49d9691b5ccccab4e819e3
# 35.0.0-2, still used by one installation.
deployed_ref=repo.cylo.net/nextcloud@sha256:e840fc9dcf952c7555872534c2c12e7cea16cd00e556be542e570ea400ae3b2e
# 31.0.4-2, with Ubuntu's MySQL 8.0.
mysql80_ref=repo.cylo.net/nextcloud@sha256:2fbf3f58f6df25fed7f7842e149a7526fea7f1ebe1b388246967f4f09f38a52b
php_source=php8.4
php_cli=php8.4
php_fpm=php-fpm8.4
min_arg=PHP84_MIN_VERSION
compared_paths="/etc/my_init.d /app-sources /etc/nginx /etc/service /etc/runit /etc/container_environment /etc/cron.d /etc/ssh/sshd_config /scripts /sources /sbin/my_init /etc/apt /usr/share/keyrings /etc/nextcloud-redis.conf /etc/redis"
edited_base_files="/scripts/nginx_php7.sh /scripts/mysql.sh /sources/php-fpm.conf /sources/www.conf /app-sources/nextcloud.conf"
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
recreate_test=$gate_dir/release/recreate-regression.sh
mysql80_test=$gate_dir/release/mysql80-upgrade.sh
scenario_dirs=()
cleanup() {
    docker rm -f "$test_name" >/dev/null 2>&1 || true
    local dir
    for dir in "${scenario_dirs[@]}"; do
        [ ! -d "$dir" ] || "$recreate_test" "$dir" cleanup "$base_ref" \
            || echo "Remove $dir and its container by hand" >&2
        docker ps -aq --filter "label=net.cylo.recreate-regression=$(basename "$dir")" \
            | xargs -r docker rm -f >/dev/null 2>&1 || true
    done
    rm -rf "$work"
}
trap cleanup EXIT

in_image() {
    local ref=$1
    shift
    docker run --rm --network none -v "$gate_dir/release:/release:ro" --entrypoint sh "$ref" "$@"
}

echo "== Image and base ($mode)"
for ref in "$base_ref" "$deployed_ref" "$mysql80_ref"; do
    docker image inspect "$ref" >/dev/null 2>&1 || docker pull -q "$ref" >/dev/null
done
platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image_ref")
[ "$platform" = linux/amd64 ] || fail "wrong image platform: $platform"

config_filter='{Env, Cmd, Entrypoint, User, WorkingDir, ExposedPorts, Volumes, StopSignal, Shell, Healthcheck}'
diff -u <(docker image inspect --format '{{json .Config}}' "$base_ref" | jq -S "$config_filter") \
    <(docker image inspect --format '{{json .Config}}' "$image_ref" | jq -S "$config_filter") \
    || fail "runtime configuration differs from 35.0.0-4"
docker image inspect --format '{{json .Config.Env}}' "$image_ref" | jq -r '.[]' | grep '^NEXTCLOUD_VER='

docker image inspect --format '{{json .RootFS.Layers}}' "$base_ref" | jq -r '.[]' > "$work/base-layers"
docker image inspect --format '{{json .RootFS.Layers}}' "$image_ref" | jq -r '.[]' > "$work/image-layers"
[ "$(wc -l < "$work/image-layers")" -eq "$(( $(wc -l < "$work/base-layers") + 1 ))" ] \
    || fail "expected exactly one layer on top of 35.0.0-4"
head -n "$(wc -l < "$work/base-layers")" "$work/image-layers" | cmp -s - "$work/base-layers" \
    || fail "image is not built on the 35.0.0-4 layers"
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
    [ -n "$fixes" ] || fail "release/required-fixes.txt lists no CVE ids"
    [ -z "$missing" ] || fail "the $php_source changelog does not mention: $missing"
elif [ -z "$fixes" ]; then
    echo "TRIAL: release/required-fixes.txt lists no CVE ids, so release mode would refuse"
elif [ -n "$missing" ]; then
    echo "TRIAL: not in this image: $missing"
fi

echo "== Package changes against 35.0.0-4"
dpkg_list='dpkg-query -W -f="\${db:Status-Abbrev}|\${binary:Package}|\${Version}\n"'
in_image "$base_ref" -c "$dpkg_list" | awk -F'|' '$1 ~ /^ii/ {print $2 "|" $3}' | sort > "$work/base-dpkg"
in_image "$image_ref" -c "$dpkg_list" | awk -F'|' '$1 ~ /^ii/ {print $2 "|" $3}' | sort > "$work/image-dpkg"
# Packages left removed with their configuration (rc) must be those of 35.0.0-4.
diff -u <(in_image "$base_ref" -c "$dpkg_list" | awk -F'|' '$1 !~ /^ii/' | sort) \
    <(in_image "$image_ref" -c "$dpkg_list" | awk -F'|' '$1 !~ /^ii/' | sort) \
    || fail "packages that are not fully installed differ from 35.0.0-4"
awk -F'|' 'NR == FNR { old[$1] = $2; next } { new[$1] = $2 }
    END {
        for (p in new) if (!(p in old)) print "+ " p " " new[p]
        for (p in old) if (!(p in new)) print "- " p " " old[p]
        for (p in new) if ((p in old) && old[p] != new[p]) print "~ " p " " old[p] " -> " new[p]
    }' "$work/base-dpkg" "$work/image-dpkg" | LC_ALL=C sort -k2,2 -k1,1 > "$work/package-changes"
diff -u "$gate_dir/release/package-changes.txt" "$work/package-changes" \
    || fail "package changes differ from release/package-changes.txt"
if grep -E '^php8\.(3|5)' "$work/image-dpkg"; then
    fail "php8.3 or php8.5 packages are installed"
fi
if awk -F'|' '$2 ~ /deb\.sury\.org/ && $1 !~ /^php8\.4/ && $1 != "php-common"' "$work/image-dpkg" | grep .; then
    fail "packages other than php8.4 and php-common come from the PPA"
fi
echo "$(grep -c '^+' "$work/package-changes") added, $(grep -c '^-' "$work/package-changes") removed, $(grep -c '^~' "$work/package-changes") upgraded, as recorded"

echo "== File changes against 35.0.0-4"
# shellcheck disable=SC2086
in_image "$base_ref" /release/file-manifest.sh $compared_paths > "$work/base-files"
# shellcheck disable=SC2086
in_image "$image_ref" /release/file-manifest.sh $compared_paths > "$work/image-files"
diff "$work/base-files" "$work/image-files" | grep '^[<>]' > "$work/file-changes" || true
diff -u "$gate_dir/release/file-changes.txt" "$work/file-changes" \
    || fail "file changes differ from release/file-changes.txt"
for pair in 15_mysql_config_compat.sh:/etc/my_init.d/15_mysql_config_compat.sh \
    16_mysql80_backup.sh:/etc/my_init.d/16_mysql80_backup.sh \
    30_installer.sh:/etc/my_init.d/30_installer.sh \
    redis/run:/etc/service/redis/run redis/nextcloud.conf:/etc/nextcloud-redis.conf; do
    docker run --rm --network none --entrypoint cat "$image_ref" "${pair#*:}" | cmp -s - "$gate_dir/${pair%%:*}" \
        || fail "${pair#*:} is not this overlay's ${pair%%:*}"
done
: > "$work/base-edits"
for file in $edited_base_files; do
    docker run --rm --network none --entrypoint cat "$base_ref" "$file" > "$work/base-file"
    docker run --rm --network none --entrypoint cat "$image_ref" "$file" > "$work/image-file"
    diff -u --label "base$file" --label "image$file" "$work/base-file" "$work/image-file" >> "$work/base-edits" || true
done
cmp -s "$work/base-edits" "$gate_dir/release/base-edits.diff" \
    || { diff -u "$gate_dir/release/base-edits.diff" "$work/base-edits" || true; \
         fail "the base file edits are not exactly release/base-edits.diff"; }
echo "$(wc -l < "$work/file-changes") manifest lines changed as recorded; overlay files in place; base edits as in release/base-edits.diff"

echo "== PHP modules"
expected_modules() {
    sed -e '/^geos$/d' -e '/^sass$/d' | awk '
        { print }
        /^hash$/ { print "http" }
        /^random$/ { print "raphf" }'
}
diff -u <(docker run --rm --network none --entrypoint php-fpm8.3 "$base_ref" -m | expected_modules) \
    <(docker run --rm --network none --entrypoint "$php_fpm" "$image_ref" -m) \
    || fail "$php_fpm module list is not the 35.0.0-4 list without geos and sass and with http and raphf"
diff -u <(docker run --rm --network none --entrypoint php8.3 "$base_ref" -m 2>/dev/null | expected_modules) \
    <(docker run --rm --network none --entrypoint "$php_cli" "$image_ref" -m) \
    || fail "$php_cli module list is not the 35.0.0-4 list without geos and sass and with http and raphf"
echo "CLI and FPM module lists as expected"

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

echo "== Image checks"
docker run --rm --network none --entrypoint /bin/bash "$image_ref" -ec '
    php -v | head -n 1 | grep -q "PHP 8.4"
    php-fpm8.4 -v | head -n 1 | grep -q "PHP 8.4"
    [ "$(readlink -f /usr/bin/php)" = /usr/bin/php8.4 ]
    test ! -e /usr/bin/php8.3 && test ! -e /usr/sbin/php-fpm8.3 && test ! -d /etc/php/8.3
    nginx -v 2>&1 | grep -Eq "nginx/1\.30\."
    mysqld --version | grep -Eq " 8\.4\.[0-9]+ "
    [ "$(php -r "echo ini_get(\"memory_limit\");")" = 3G ]
    [ "$(php-fpm8.4 -i 2>/dev/null | sed -n "s/^memory_limit => \([^ ]*\) =>.*/\1/p" | head -n 1)" = 3G ]
    [ "$(php -r "echo ini_get(\"apc.enable_cli\");")" = 1 ]
    php -r "exit(in_array(\"SVG\", Imagick::queryFormats(\"SVG\"), true) ? 0 : 1);"
    php -r "exit(function_exists(\"smbclient_state_new\") ? 0 : 1);"
    php -r "exit(version_compare(phpversion(\"redis\"), \"6\", \">=\") ? 0 : 1);"
    redis-server --version | grep -q "v=7\."
    test -f /app-sources/nextcloud-35.0.0.zip
    /app-sources/verify-nextcloud-archive.sh 35.0.0
    if grep -nE "^apt " /scripts/mysql.sh; then exit 1; fi
    [ -z "$(apt-get -s autoremove 2>/dev/null | grep "^Remv" || true)" ]
'
mysql_min=$(sed -n 's/^ARG MYSQL84_MIN_VERSION=\([A-Za-z0-9.+~-]*\)$/\1/p' "$gate_dir/Dockerfile")
[ -n "$mysql_min" ] || fail "could not read ARG MYSQL84_MIN_VERSION from $gate_dir/Dockerfile"
mysql_versions=$(awk -F'|' '$1 ~ /^mysql-/ && $2 ~ /^8\.4\./ {print $2}' "$work/image-dpkg" | sort -u)
[ "$(printf '%s\n' "$mysql_versions" | grep -c .)" -eq 1 ] || fail "MySQL 8.4 packages are not at one version: $mysql_versions"
in_image "$image_ref" -c "dpkg --compare-versions '$mysql_versions' ge '$mysql_min'" \
    || fail "MySQL $mysql_versions is older than the pinned minimum $mysql_min"
echo "PHP 8.4, nginx 1.30, MySQL $mysql_versions (minimum $mysql_min), 3G limits, APCu CLI, Imagick SVG, smbclient, phpredis, Redis 7, no runtime apt"

echo "== Fresh install and restart"
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
            sv status redis | grep -q "^run: redis"
        ' >/dev/null 2>&1; then
            return 0
        fi
        sleep 5
    done
    echo 'Nextcloud did not become healthy within 5 minutes after installer completion.' >&2
    return 1
}

check_setup() {
    docker exec "$test_name" su -s /bin/sh -c "cd /home/appbox/public_html && php occ setupchecks --output=json" appbox \
        > "$work/setupchecks.json" || true
    local check severity
    for check in PhpOutdated SupportedDatabase FileLocking MemcacheConfigured PhpModules; do
        severity=$(jq -r --arg c "OCA\\Settings\\SetupChecks\\$check" \
            '[.[] | to_entries[] | select(.key == $c) | .value.severity][0] // "missing"' "$work/setupchecks.json")
        [ "$severity" = success ] || fail "setup check $check reports $severity"
    done
}

wait_for_install || fail "fresh install did not finish"
wait_for_health || fail "fresh install is not healthy"
docker exec "$test_name" /bin/bash -ec '
    [ "$(php -r "echo ini_get(\"memory_limit\");")" = 3G ]
    grep -q php-fpm8.4 /etc/service/phpfpm/run
    grep -q php8.4-fpm.sock /home/appbox/config/nginx/sites-enabled/nextcloud.conf
    php-fpm8.4 -tt --fpm-config /home/appbox/config/php-fpm/php-fpm.conf 2>&1 | grep -F "php_admin_value[memory_limit] = 3G" >/dev/null
    nginx -t -c /home/appbox/config/nginx/nginx.conf
    curl -fsS http://localhost/status.php | grep -q "35.0.0"
    su -s /bin/sh -c "cd /home/appbox/public_html && php occ status --output=json" appbox | grep -q "\"installed\":true"
    [ "$(ps -o user= -C redis-server)" = appbox ]
    [ "$(stat -c "%U %a" /run/redis/redis.sock)" = "appbox 770" ]
    [ "$(redis-cli -s /run/redis/redis.sock config get port | tail -n 1)" = 0 ]
    if grep -q ":18EB " /proc/net/tcp /proc/net/tcp6; then exit 1; fi
    occ() { su -s /bin/sh -c "cd /home/appbox/public_html && php occ $*" appbox; }
    [ "$(occ config:system:get memcache.locking)" = "\\OC\\Memcache\\Redis" ]
    [ "$(occ config:system:get memcache.distributed)" = "\\OC\\Memcache\\Redis" ]
    [ "$(occ config:system:get memcache.local)" = "\\OC\\Memcache\\APCu" ]
    [ "$(occ config:system:get redis host)" = /run/redis/redis.sock ]
    [ "$(occ files_external:list --output=json | php -r "echo implode(\" \", array_column(json_decode(stream_get_contents(STDIN), true), \"mount_point\"));")" = "/apps /storage" ]
' || fail "fresh install checks failed"
check_setup
echo "fresh install: PHP 8.4 behind nginx, Redis as appbox on its socket only, Redis locking and cache configured, mounts /apps /storage, setup checks pass"

# Confirm a Nextcloud .user.ini override cannot lower the web PHP limit, and
# that php-fpm8.4 answers through nginx.
docker exec "$test_name" /bin/bash -ec '
    cp /home/appbox/public_html/.user.ini /tmp/cylo-user.ini.backup
    cp /home/appbox/public_html/status.php /tmp/cylo-status.php.backup
    printf "\nmemory_limit=128M\n" >> /home/appbox/public_html/.user.ini
    printf "<?php echo ini_get(\"memory_limit\"), \" \", PHP_SAPI, \" \", PHP_VERSION;\n" > /home/appbox/public_html/status.php
    chown appbox:appbox /home/appbox/public_html/status.php
    sv restart phpfpm
    result=
    for attempt in $(seq 1 20); do
        result=$(curl -fsS http://localhost/status.php) && break
        sleep 1
    done
    case "$result" in "3G fpm-fcgi 8.4."*) ;; *) echo "web PHP reported \"$result\"" >&2; exit 1 ;; esac
    cp /tmp/cylo-status.php.backup /home/appbox/public_html/status.php
    cp /tmp/cylo-user.ini.backup /home/appbox/public_html/.user.ini
    chown appbox:appbox /home/appbox/public_html/status.php /home/appbox/public_html/.user.ini
    rm /tmp/cylo-status.php.backup /tmp/cylo-user.ini.backup
' || fail "web PHP limit or version check failed"

# A multipart upload through the installed nginx site and php-fpm8.4. The
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
        echo "multipart upload through nginx and php-fpm8.4 returned \"$result\", expected 1:5:b" >&2
        exit 1
    fi
    echo "multipart upload parsed through the installed nginx site and php-fpm8.4"
' || fail "multipart upload through the installed site failed"

docker restart "$test_name" >/dev/null
# Docker clears tmpfs contents on restart; Appbox's real /ssl mount persists.
# Restore the test certificate before checking nginx after the restart.
docker exec "$test_name" openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout /ssl/key.pem -out /ssl/cert.pem \
    -subj "/CN=$test_name" -days 1 >/dev/null 2>&1
wait_for_install || fail "installer did not finish after the restart"
wait_for_health || fail "Nextcloud is not healthy after the restart"
docker exec "$test_name" /bin/bash -ec '
    curl -fsS http://localhost/status.php | grep -q "35.0.0"
    [ "$(php -r "echo ini_get(\"memory_limit\");")" = 3G ]
    php-fpm8.4 -tt --fpm-config /home/appbox/config/php-fpm/php-fpm.conf 2>&1 | grep -F "php_admin_value[memory_limit] = 3G" >/dev/null
' || fail "checks after the restart failed"
check_setup
docker rm -f "$test_name" >/dev/null
echo "restart: healthy, setup checks pass"

echo "== Update tests on Appbox host directories"
# Created in this shell (not in a $(...) subshell) so that cleanup sees them.
new_dir() {
    local dir
    dir=$(mktemp -d /dev/shm/nextcloud-recreate.XXXXXX)
    scenario_dirs+=("$dir")
    printf -v "$1" '%s' "$dir"
}
new_dir same_dir
new_dir base_dir
new_dir deployed_dir
new_dir mysql80_dir
new_dir mysql80_kill_dir

setupchecks_of() {
    docker exec "$(cat "$1/name")" su -s /bin/sh -c "cd /home/appbox/public_html && php occ setupchecks --output=json" appbox || true
}

# A fresh install with the new image, recreated from the same image, then
# recreated again with the installed version reporting newer than the image.
scenario_same_image() {
    "$recreate_test" "$same_dir" install "$image_ref" \
        && "$recreate_test" "$same_dir" recreate "$image_ref" \
        && "$recreate_test" "$same_dir" bump \
        && "$recreate_test" "$same_dir" recreate "$image_ref"
}

# The production update: a 35.0.0-4 installation updated to the new image.
# No setup check may get worse; the PHP version, database version, file
# locking and memcache checks must pass. A further recreate must keep
# config.php byte-identical.
scenario_from_base() {
    "$recreate_test" "$base_dir" install "$base_ref" || return 1
    setupchecks_of "$base_dir" > "$base_dir/setupchecks-before.json"
    "$recreate_test" "$base_dir" recreate "$image_ref" || return 1
    setupchecks_of "$base_dir" > "$base_dir/setupchecks-after.json"
    jq -e 'type == "object" and length > 0' "$base_dir/setupchecks-before.json" >/dev/null \
        && jq -e 'type == "object" and length > 0' "$base_dir/setupchecks-after.json" >/dev/null \
        || { echo "FAIL: occ setupchecks did not return results" >&2; return 1; }
    jq -n --slurpfile before "$base_dir/setupchecks-before.json" --slurpfile after "$base_dir/setupchecks-after.json" -r '
        def rank: {"success": 0, "info": 1, "warning": 2, "error": 3}[.] // 3;
        def flat($x): [$x[0][] | to_entries[]] | map({(.key): .value.severity}) | add;
        flat($before) as $b | flat($after) as $a
        | ($a | to_entries[] | select(($b[.key] // "success" | rank) < (.value | rank)) | "WORSE \(.key): \($b[.key] // "absent") -> \(.value)"),
          (["PhpOutdated", "SupportedDatabase", "FileLocking", "MemcacheConfigured"][] as $c
            | "OCA\\Settings\\SetupChecks\\\($c)" as $k
            | if $a[$k] == "success" then "OK \($c): \($b[$k]) -> success" else "NOT PASSING \($c): \($a[$k])" end)' \
        | tee "$base_dir/setupchecks-compare.txt"
    if grep -qE '^(WORSE|NOT PASSING)' "$base_dir/setupchecks-compare.txt"; then
        echo "FAIL: setup checks after updating 35.0.0-4 to the new image" >&2
        return 1
    fi
    "$recreate_test" "$base_dir" recreate "$image_ref"
}

# The single 35.0.0-2 installation updated to the new image.
scenario_from_deployed() {
    "$recreate_test" "$deployed_dir" install "$deployed_ref" \
        && "$recreate_test" "$deployed_dir" recreate "$image_ref"
}

# 31.0.4-2 with MySQL 8.0, Nextcloud upgraded to 35.0.2 in place, stopped
# cleanly, updated to the new image, then taken back to 31.0.4-2.
scenario_mysql80() {
    "$recreate_test" "$mysql80_dir" install "$mysql80_ref" \
        && "$mysql80_test" "$mysql80_dir" nc-upgrade \
        && "$recreate_test" "$mysql80_dir" recreate "$image_ref" \
        && "$mysql80_test" "$mysql80_dir" check-84 "$image_ref" \
        && "$mysql80_test" "$mysql80_dir" rollback "$mysql80_ref"
}

# The same, with MySQL 8.0 killed instead of shut down before the update.
scenario_mysql80_kill() {
    "$recreate_test" "$mysql80_kill_dir" install "$mysql80_ref" \
        && "$mysql80_test" "$mysql80_kill_dir" nc-upgrade \
        && "$mysql80_test" "$mysql80_kill_dir" kill \
        && "$recreate_test" "$mysql80_kill_dir" recreate "$image_ref" \
        && "$mysql80_test" "$mysql80_kill_dir" check-84 "$image_ref"
}

# Each MySQL 8.4 server takes about 14,000 of the host's asynchronous I/O
# contexts (fs.aio-max-nr is 65536 on builder1), so at most three scenarios
# run at a time and each scenario's container is stopped when it finishes.
scenarios="same-image from-base from-deployed mysql80 mysql80-kill"
failed=
declare -A scenario_dir=([same-image]=$same_dir [from-base]=$base_dir [from-deployed]=$deployed_dir \
    [mysql80]=$mysql80_dir [mysql80-kill]=$mysql80_kill_dir)
run_batch() {
    local scenario status
    declare -A scenario_pid
    for scenario in "$@"; do
        "scenario_${scenario//-/_}" > "$work/scenario-$scenario.log" 2>&1 &
        scenario_pid[$scenario]=$!
    done
    for scenario in "$@"; do
        status=0
        wait "${scenario_pid[$scenario]}" || status=$?
        echo "--- $scenario (exit $status)"
        grep -vE '^ *- |^[[:space:]]*$|^ +[0-9]+ \[' "$work/scenario-$scenario.log" | tail -n 60
        [ "$status" -eq 0 ] || failed="$failed $scenario"
        # A finished scenario's MySQL must not hold I/O contexts the next
        # batch needs.
        docker ps -q --filter "label=net.cylo.recreate-regression=$(basename "${scenario_dir[$scenario]}")" \
            | xargs -r docker stop -t 60 >/dev/null || true
    done
}
run_batch same-image from-base from-deployed
run_batch mysql80 mysql80-kill
[ -z "$failed" ] || fail "update tests failed:$failed"
echo "update tests passed: $scenarios"

echo "== Registry tag must not exist"
"$gate_dir/release/registry-absent.sh" "$release_ref" \
    || fail "registry precondition for $release_ref not met"

if [ "$mode" = trial ]; then
    echo "TRIAL PASSED: $image_ref ($php_source at the trial minimum $check_min; $release_ref absent)."
else
    echo "PASS: $release_ref ($php_source >= $check_min with $fixes, recorded package and file changes, fresh install, restart, setup checks, update tests including MySQL 8.0, tag absent)"
fi
