# Deployed build inputs of repo.cylo.net/nextcloud:27.1.5 (sha256:3e0c085f...)

`repo.cylo.net/nextcloud@sha256:3e0c085feeef8cddbc150598fc2c71c6aef242892ca03aaafbe203d3771d54fe`
(built 2024-04-30, Ubuntu 22.04, NEXTCLOUD_VER=27.1.5, php-fpm8.1) is the
newest Ubuntu 22.04 Nextcloud image and the base of
`overlays/jammy-27.1.5-1`. No Git source exists for it. Recorded here:

| File | SHA-256 | Same as in the image |
| --- | --- | --- |
| `30_installer.sh` | `4ff6ed5a04c0e653c02774b0ccea54a59db1bb60bc56e9d4abe2c819197aa7d7` | `/etc/my_init.d/30_installer.sh` |

`image-history.tsv` is `docker image history --no-trunc` of the digest, with
password values redacted; it shows the Dockerfile instructions.

The installer has no "installed version is newer" guard: on every container
recreate it downloads `nextcloud-$NEXTCLOUD_VER.zip`, unpacks it over
`public_html` and runs `occ upgrade`. The overlay's
`29_keep_installed_nextcloud.sh` sets `NEXTCLOUD_VER` to the installed
version before this installer runs.
