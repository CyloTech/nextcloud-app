#!/bin/bash
set -euo pipefail

package_default=/etc/nginx/conf.d/default.conf
if [ -f "$package_default" ]; then
    if ! grep -Eq '^[[:space:]]*root[[:space:]]+/usr/share/nginx/html;' "$package_default"; then
        echo 'Unexpected nginx default site; refusing to replace it.' >&2
        exit 1
    fi
    rm -f "$package_default"
fi
