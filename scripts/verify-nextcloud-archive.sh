#!/bin/bash
set -euo pipefail

version=${1:-}
if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo 'Expected a Nextcloud numeric release version.' >&2
    exit 2
fi

archive_name="nextcloud-$version.zip"
archive="/app-sources/$archive_name"
checksum_file="$archive.sha256"
test -f "$archive"
test -f "$checksum_file"
expected=$(awk -v archive="$archive_name" '$2 == archive { print $1 }' "$checksum_file")
if [[ ! $expected =~ ^[0-9a-f]{64}$ ]]; then
    echo "No unique SHA-256 checksum for $archive_name" >&2
    exit 1
fi
printf '%s  %s\n' "$expected" "$archive" | sha256sum -c -
