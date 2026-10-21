#!/bin/sh
# Usage (inside an image): file-manifest.sh <path>...
#
# Prints one sorted line per file, directory and symlink under the given
# paths: type, mode, owner, group, SHA-256 (or link target) and path. The
# release gate diffs this between the deployed base image and the new image.
set -eu

for root in "$@"; do
    [ -e "$root" ] || [ -L "$root" ] || { echo "absent - - - - $root"; continue; }
    find "$root" -xdev \( -type f -o -type l -o -type d \) -print
done | LC_ALL=C sort | while IFS= read -r path; do
    meta=$(stat -c '%a %U %G' "$path")
    if [ -L "$path" ]; then
        echo "link $meta $(readlink "$path") $path"
    elif [ -d "$path" ]; then
        echo "dir $meta - $path"
    else
        echo "file $meta $(sha256sum < "$path" | cut -c1-64) $path"
    fi
done
