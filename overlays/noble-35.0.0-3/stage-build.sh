#!/usr/bin/env bash
# Staged build of repo.cylo.net/nextcloud:35.0.0-3 on the dedicated builder, following the
# staged flow in app-fixes-and-builds.md: archive the exact pushed commit,
# transfer it to a fresh directory under /home/appbox/builds, build with
# --no-cache for linux/amd64, run the checked-in release gate, and (release
# mode only) push.
#
# Usage: ./stage-build.sh release
#            Build repo.cylo.net/nextcloud:35.0.0-3 with the php minimum pinned in the
#            Dockerfile, run the gate, and push only if the gate passes.
#        ./stage-build.sh trial <PHP83_MIN_VERSION value>
#            Build local/nextcloud-trial:35.0.0-3 with the given minimum (for example the version
#            available today) and run the gate in trial mode. Never pushes.
#
# Runs locally on the operator's machine from this worktree. The branch must be
# pushed and the worktree clean: the build input is the pushed commit only.
set -euo pipefail

repo_slug=nextcloud-app
branch=php-multipart-fix-35
image_tag=35.0.0-3
release_ref=repo.cylo.net/nextcloud:35.0.0-3
trial_ref=local/nextcloud-trial:35.0.0-3
context_path=overlays/noble-35.0.0-3
min_arg=PHP83_MIN_VERSION
gate=release-gate.sh
builder=appbox@builder1.builder.appboxes.co
builder_port=10112
control_dir=$(mktemp -d /private/tmp/cylo-ssh.XXXXXX)
# One multiplexed connection for every ssh/scp call keeps the number of new
# connections to the builder low.
ssh_opts=(-o "Port=$builder_port" -i /Users/rid/.ssh/appbox_ubuntuvps2_webtop -o IdentitiesOnly=yes
    -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=yes -o ServerAliveInterval=30
    -o ControlMaster=auto -o "ControlPath=$control_dir/%C" -o ControlPersist=300)
poll_seconds=30

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
job_started=0
job_finished=0
cleanup() {
    case "$stage" in /private/tmp/cylo-app-build.??????) rm -rf "$stage" ;; esac
    case "$remote_dir" in
        "$remote_prefix".[[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]])
            if [ "$job_started" -eq 1 ] && [ "$job_finished" -ne 1 ]; then
                echo "The builder job may still be running; its log is $builder:$remote_dir/build.log. Remove $remote_dir by hand when it has finished." >&2
            else
                ssh "${ssh_opts[@]}" "$builder" "rm -rf '$remote_dir'" \
                    || echo "Remove $remote_dir on the builder by hand" >&2
            fi
            ;;
    esac
    ssh "${ssh_opts[@]}" -O exit "$builder" >/dev/null 2>&1 || true
    case "$control_dir" in /private/tmp/cylo-ssh.??????) rm -rf "$control_dir" ;; esac
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

remote_dir=$(ssh "${ssh_opts[@]}" "$builder" "mktemp -d '$remote_prefix.XXXXXX'")
case "$remote_dir" in
    "$remote_prefix".[[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]]) ;;
    *) remote_dir=""; fail "unexpected remote directory" ;;
esac
echo "builder directory $remote_dir"
scp "${ssh_opts[@]}" "$archive" "$builder:$remote_dir/context.tgz"
ssh "${ssh_opts[@]}" "$builder" "cd '$remote_dir' && \
    printf '%s  context.tgz\n' '$archive_sha' | sha256sum -c - && \
    mkdir context && tar xzf context.tgz -C context && test -x 'context/$gate'"

if [ "$mode" = trial ]; then
    build_ref=$trial_ref
    remote_job="cd context && docker build --progress=plain --platform linux/amd64 --no-cache --build-arg '$min_arg=$trial_min' -t '$build_ref' . && './$gate' '$build_ref'"
else
    build_ref=$release_ref
    remote_job="cd context && docker build --progress=plain --platform linux/amd64 --no-cache -t '$build_ref' . && './$gate' '$build_ref' && docker push '$build_ref' && docker image inspect --format '{{json .RepoDigests}}' '$build_ref'"
fi

# Build, gate and (release mode) push run as one joined command in a detached
# session on the builder, so a dropped SSH connection cannot interrupt them
# between the gate and the push. The last log line records the exit status.
boot_id=$(ssh "${ssh_opts[@]}" "$builder" "cat /proc/sys/kernel/random/boot_id")
ssh "${ssh_opts[@]}" "$builder" "cd '$remote_dir' && \
    { nohup setsid bash -c \"$remote_job; echo STAGE-BUILD-EXIT=\\\$?\" > build.log 2>&1 < /dev/null & } && echo 'builder job started'"
job_started=1

exit_line=""
while [ -z "$exit_line" ]; do
    sleep "$poll_seconds"
    if ! progress=$(ssh "${ssh_opts[@]}" "$builder" "cat /proc/sys/kernel/random/boot_id; tail -n 2 '$remote_dir/build.log'"); then
        echo "$(date -u +%H:%M:%S) builder unreachable; retrying" >&2
        continue
    fi
    if [ "$(printf '%s\n' "$progress" | head -n 1)" != "$boot_id" ]; then
        job_finished=1
        fail "the builder rebooted during the job; nothing was pushed by this run unless its log says so"
    fi
    progress=$(printf '%s\n' "$progress" | tail -n +2)
    echo "$(date -u +%H:%M:%S) $(printf '%s' "$progress" | tail -n 1 | cut -c1-200)"
    exit_line=$(printf '%s\n' "$progress" | sed -n 's/^STAGE-BUILD-EXIT=\([0-9][0-9]*\)$/\1/p')
done
job_finished=1

echo "===== builder log ($remote_dir/build.log)"
ssh "${ssh_opts[@]}" "$builder" "cat '$remote_dir/build.log'"
echo "===== end of builder log"
[ "$exit_line" -eq 0 ] || fail "builder job exited with status $exit_line"
if [ "$mode" = trial ]; then
    echo "Trial finished: $trial_ref (not pushed) from $commit"
else
    echo "Pushed $release_ref from $commit; record the digest above"
fi
