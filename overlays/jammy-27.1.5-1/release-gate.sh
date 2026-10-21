#!/usr/bin/env bash
# Release gate for repo.cylo.net/nextcloud:27.1.5-1, the newest deployed
# Ubuntu 22.04 image (nextcloud:27.1.5) with only its php8.1 packages upgraded
# and a startup script that keeps the installed Nextcloud version.
#
# Usage: ./release-gate.sh repo.cylo.net/nextcloud:27.1.5-1   (release)
#        ./release-gate.sh local/nextcloud-trial:27.1.5-1     (trial)
#
# Release mode requires the image to have been built with the php8.1 minimum
# pinned in the Dockerfile (ARG PHP81_MIN_VERSION). Trial mode accepts the
# minimum the trial image was built with (--build-arg PHP81_MIN_VERSION=<the
# current version>), so every other check can be exercised before Ubuntu
# publishes the fix. Release mode also requires every CVE id listed in
# release/required-fixes.txt to appear in the php8.1-common changelog; trial
# mode only reports them. Trial images are never pushed. Both modes require
# the release tag to be absent from the registry.
#
# Against the deployed base digest it checks: two added layers, identical
# runtime configuration (env including NEXTCLOUD_VER, command, ports, user),
# identical non-php8.1 packages, the same set of php8.1 packages, identical
# installer, /app-sources, PHP, nginx and service files apart from the added
# version-pin script, and identical CLI and FPM module lists. It also runs
# php-fpm8.1 -t, nginx -t, a multipart upload (CLI server, and a PHP page plus
# upload served through nginx and php-fpm8.1), the version-pin cases, and a my_init run
# that proves the pinned version reaches 30_installer.sh.
set -euo pipefail

release_ref=repo.cylo.net/nextcloud:27.1.5-1
trial_ref=local/nextcloud-trial:27.1.5-1
base_ref=repo.cylo.net/nextcloud@sha256:3e0c085feeef8cddbc150598fc2c71c6aef242892ca03aaafbe203d3771d54fe
php_source=php8.1
php_cli=php8.1
php_fpm=php-fpm8.1
min_arg=PHP81_MIN_VERSION
added_layers=2
pin_script=/etc/my_init.d/29_keep_installed_nextcloud.sh
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

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

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
[ "$(wc -l < "$work/image-layers")" -eq "$(( $(wc -l < "$work/base-layers") + added_layers ))" ] \
    || fail "expected exactly $added_layers layers on top of the deployed base"
head -n "$(wc -l < "$work/base-layers")" "$work/image-layers" | cmp -s - "$work/base-layers" \
    || fail "image is not built on the deployed base layers"
echo "$added_layers layers on top of $base_ref"

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

echo "== Installer, sources and configuration unchanged apart from $pin_script"
# shellcheck disable=SC2086
in_image "$base_ref" /release/file-manifest.sh $compared_paths > "$work/base-files"
# shellcheck disable=SC2086
in_image "$image_ref" /release/file-manifest.sh $compared_paths > "$work/image-files"
pin_hash=$(sha256sum < "$gate_dir/29_keep_installed_nextcloud.sh" | cut -c1-64)
printf 'file 755 root root %s %s\n' "$pin_hash" "$pin_script" > "$work/expected-added"
diff "$work/base-files" "$work/image-files" | sed -n 's/^> //p' > "$work/added" || true
diff "$work/base-files" "$work/image-files" | sed -n 's/^< //p' > "$work/removed" || true
[ ! -s "$work/removed" ] || { cat "$work/removed" >&2; fail "files changed or removed compared with the deployed base"; }
diff -u "$work/expected-added" "$work/added" \
    || fail "the only added path must be $pin_script with the checked-in contents"
echo "$(wc -l < "$work/base-files") paths identical; added $pin_script"

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

echo "== Version pin cases"
# $1: installed $OC_VersionString value, or 'none' for no version.php
# $2: 'completed' to simulate a restart of an installed container, else 'recreate'
# $3: expected /etc/container_environment/NEXTCLOUD_VER, or 'unset'
pin_case() {
    local result
    result=$(docker run --rm --network none --entrypoint sh "$image_ref" -c '
        set -eu
        rm -f /etc/container_environment/NEXTCLOUD_VER /etc/app_installer_completed
        mkdir -p /home/appbox/public_html
        rm -f /home/appbox/public_html/version.php
        if [ "$1" != none ]; then
            printf "<?php\n\$OC_Version = array(1,2,3,4);\n\$OC_VersionString = '\''%s'\'';\n\$OC_Edition = '\'''\'';\n" "$1" \
                > /home/appbox/public_html/version.php
        fi
        [ "$2" = completed ] && touch /etc/app_installer_completed
        '"$pin_script"' >/dev/null
        cat /etc/container_environment/NEXTCLOUD_VER 2>/dev/null || echo unset
    ' sh "$1" "$2") || fail "version pin: the script failed for installed '$1' ($2)"
    [ "$result" = "$3" ] || fail "version pin: installed '$1' ($2) gave NEXTCLOUD_VER=$result, expected $3"
    echo "installed '$1' ($2) -> $result"
}
pin_case 28.0.14 recreate 28.0.14
pin_case 29.0.5 recreate 29.0.5
pin_case 27.1.11 recreate 27.1.11
pin_case 27.0.1 recreate 27.0.1
pin_case 27.1.5 recreate 27.1.5
pin_case none recreate unset
pin_case '28.0.0 RC1' recreate unset
pin_case 27.1 recreate unset
pin_case abc recreate unset
pin_case 28.0.14 completed unset

echo "== Pinned version reaches 30_installer.sh through my_init"
# Replace the installer with a probe in a disposable container and run the
# real my_init startup sequence.
my_init_case() {
    local result
    result=$(docker run --rm --network none --entrypoint sh "$image_ref" -c '
        set -eu
        rm -f /etc/app_installer_completed /home/appbox/public_html/version.php
        mkdir -p /home/appbox/public_html /tmp/my_init.d.saved
        if [ "$1" != none ]; then
            printf "<?php\n\$OC_VersionString = '\''%s'\'';\n" "$1" > /home/appbox/public_html/version.php
        fi
        mv /etc/my_init.d/* /tmp/my_init.d.saved/
        cp /tmp/my_init.d.saved/29_keep_installed_nextcloud.sh /etc/my_init.d/
        printf "#!/bin/sh\nprintf %%s \"\$NEXTCLOUD_VER\" > /tmp/nextcloud_ver_seen_by_installer\n" > /etc/my_init.d/30_installer.sh
        chmod 755 /etc/my_init.d/30_installer.sh
        /sbin/my_init --skip-runit -- cat /tmp/nextcloud_ver_seen_by_installer 2>/dev/null
    ' sh "$1" | tail -n 1) || fail "my_init run failed for installed '$1'"
    [ "$result" = "$2" ] || fail "my_init: installed '$1' gave the installer NEXTCLOUD_VER=$result, expected $2"
    echo "installed '$1' -> installer sees NEXTCLOUD_VER=$result"
}
my_init_case 28.0.14 28.0.14
my_init_case 27.0.1 27.0.1
my_init_case none 27.1.5

echo "== Registry tag must not exist"
"$gate_dir/release/registry-absent.sh" "$release_ref" \
    || fail "registry precondition for $release_ref not met"

if [ "$mode" = trial ]; then
    echo "TRIAL PASSED: $image_ref ($php_source at the trial minimum $check_min; $release_ref absent). Not releasable: built without the release pin $pinned_min."
else
    echo "PASS: $release_ref ($php_source >= $check_min, version pin verified, everything else as deployed, tag absent)"
fi
