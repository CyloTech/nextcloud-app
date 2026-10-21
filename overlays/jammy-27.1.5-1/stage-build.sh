#!/usr/bin/env bash
# Staged build of repo.cylo.net/nextcloud:27.1.5-1 on the dedicated builder, following the
# staged flow in app-fixes-and-builds.md: archive the exact pushed commit,
# transfer it to a fresh directory under /home/appbox/builds, build with
# --no-cache for linux/amd64, run the checked-in release gate, and (release
# mode only) push.
#
# Usage: ./stage-build.sh release
#            Build repo.cylo.net/nextcloud:27.1.5-1 with the php minimum pinned in the
#            Dockerfile, run the gate, and push only if the gate passes.
#        ./stage-build.sh trial <PHP81_MIN_VERSION value>
#            Build local/nextcloud-trial:27.1.5-1 with the given minimum (for example the version
#            available today) and run the gate in trial mode. Never pushes.
#
# Runs locally on the operator's machine from this worktree. The branch must be
# pushed and the worktree clean: the build input is the pushed commit only.
set -euo pipefail

repo_slug=nextcloud-app
branch=php-multipart-fix-27
image_tag=27.1.5-1
release_ref=repo.cylo.net/nextcloud:27.1.5-1
trial_ref=local/nextcloud-trial:27.1.5-1
context_path=overlays/jammy-27.1.5-1
min_arg=PHP81_MIN_VERSION
gate=release-gate.sh
builder=appbox@builder.grant.appboxes.co
ssh_opts=(-i /Users/rid/.ssh/appbox_ubuntuvps2_webtop -o IdentitiesOnly=yes -o BatchMode=yes
    -o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o ServerAliveInterval=30)

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

mode=${1:-}
case "$mode" in
    release)
        [ "$#" -eq 1 ] || fail "usage: $0 release"
        ;;
    trial)
        [ "$#" -eq 2 ] || fail "usage: $0 trial <$min_arg value>"
        trial_min=$2
        case "$trial_min" in ''|*[!A-Za-z0-9.+~-]*) fail "invalid version: $trial_min" ;; esac
        ;;
    *) fail "usage: $0 release | $0 trial <$min_arg value>" ;;
esac
case "$image_tag" in ''|*[!A-Za-z0-9._-]*) fail "bad tag" ;; esac

repo_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
git -C "$repo_root" fetch -q origin "$branch"
commit=$(git -C "$repo_root" rev-parse HEAD)
[ "$(git -C "$repo_root" rev-parse --abbrev-ref HEAD)" = "$branch" ] || fail "not on branch $branch"
[ "$commit" = "$(git -C "$repo_root" rev-parse "origin/$branch")" ] \
    || fail "HEAD $commit is not the pushed origin/$branch; commit and push first"
[ -z "$(git -C "$repo_root" status --porcelain)" ] || fail "worktree has uncommitted changes"
if [ "$context_path" = . ]; then gate_path=$gate; else gate_path=$context_path/$gate; fi
git -C "$repo_root" cat-file -e "$commit:$gate_path" 2>/dev/null || fail "$gate_path is not in $commit"
echo "commit $commit ($branch), context '$context_path', mode $mode"

stage=$(mktemp -d /private/tmp/cylo-app-build.XXXXXX)
remote_prefix="/home/appbox/builds/$repo_slug.$image_tag"
remote_dir=""
cleanup() {
    case "$stage" in /private/tmp/cylo-app-build.??????) rm -rf "$stage" ;; esac
    case "$remote_dir" in
        "$remote_prefix".[[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]])
            ssh -p 12246 "${ssh_opts[@]}" "$builder" "rm -rf '$remote_dir'" \
                || echo "Remove $remote_dir on the builder by hand" >&2
            ;;
    esac
}
trap cleanup EXIT

archive="$stage/context.tgz"
if [ "$context_path" = . ]; then
    git -C "$repo_root" archive --format=tar.gz --output="$archive" "$commit"
else
    git -C "$repo_root" archive --format=tar.gz --output="$archive" "$commit:$context_path"
fi
tar -tzvf "$archive"
archive_sha=$(shasum -a 256 "$archive" | awk '{print $1}')
echo "archive sha256 $archive_sha"

remote_dir=$(ssh -p 12246 "${ssh_opts[@]}" "$builder" "mktemp -d '$remote_prefix.XXXXXX'")
case "$remote_dir" in
    "$remote_prefix".[[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]]) ;;
    *) remote_dir=""; fail "unexpected remote directory" ;;
esac
scp -P 12246 "${ssh_opts[@]}" "$archive" "$builder:$remote_dir/context.tgz"
ssh -p 12246 "${ssh_opts[@]}" "$builder" "cd '$remote_dir' && \
    printf '%s  context.tgz\n' '$archive_sha' | sha256sum -c - && \
    mkdir context && tar xzf context.tgz -C context && test -x 'context/$gate'"

if [ "$mode" = trial ]; then
    ssh -p 12246 "${ssh_opts[@]}" "$builder" "cd '$remote_dir/context' && \
        docker build --progress=plain --platform linux/amd64 --no-cache \
            --build-arg '$min_arg=$trial_min' -t '$trial_ref' . && \
        './$gate' '$trial_ref'"
    echo "Trial finished: $trial_ref (not pushed) from $commit"
else
    ssh -p 12246 "${ssh_opts[@]}" "$builder" "cd '$remote_dir/context' && \
        docker build --progress=plain --platform linux/amd64 --no-cache -t '$release_ref' . && \
        './$gate' '$release_ref' && \
        docker push '$release_ref' && \
        docker image inspect --format '{{json .RepoDigests}}' '$release_ref'"
    echo "Pushed $release_ref from $commit; record the digest above"
fi
