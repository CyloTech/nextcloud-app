#!/bin/sh
# Usage: registry-absent.sh <registry>/<repository>:<tag>
#
# Exits 0 only when the registry, queried with the builder's stored
# credentials, definitively reports that the tag does not exist
# (HTTP 404 with MANIFEST_UNKNOWN). Any other answer fails closed.
set -eu

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[ "$#" -eq 1 ] || fail "usage: $0 <registry>/<repository>:<tag>"
target_ref=$1
case "$target_ref" in
    ''|*[!A-Za-z0-9._/:-]*|*@*) fail "invalid image reference: $target_ref" ;;
esac
registry=${target_ref%%/*}
repository_and_tag=${target_ref#*/}
repository=${repository_and_tag%:*}
tag=${repository_and_tag##*:}
[ "$repository" != "$repository_and_tag" ] || fail "image reference has no tag"

command -v jq >/dev/null 2>&1 || fail "jq is required for the registry check"
registry_auth=$(jq -r --arg host "$registry" '.auths[$host].auth // empty' "$HOME/.docker/config.json")
[ -n "$registry_auth" ] || fail "no stored credentials for $registry"

registry_body=$(mktemp)
trap 'rm -f "$registry_body"' EXIT

registry_get() {
    printf 'header = "Authorization: Basic %s"\n' "$registry_auth" \
        | curl -sS --max-time 30 -K - -o "$registry_body" -w '%{http_code}' \
            -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json' \
            "https://$registry$1"
}

api_status=$(registry_get /v2/) || fail "registry unreachable"
[ "$api_status" = 200 ] || fail "registry API check returned HTTP $api_status"

manifest_status=$(registry_get "/v2/$repository/manifests/$tag") || fail "registry unreachable"
case "$manifest_status" in
    200) fail "$target_ref already exists in the registry" ;;
    404)
        grep -q 'MANIFEST_UNKNOWN' "$registry_body" \
            || fail "registry returned 404 without MANIFEST_UNKNOWN: $(head -c 300 "$registry_body")"
        echo "$target_ref is not in the registry yet"
        ;;
    *) fail "registry returned HTTP $manifest_status for $target_ref" ;;
esac
