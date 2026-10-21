# Deployed build inputs of repo.cylo.net/nextcloud:latest (sha256:419685ef...)

`repo.cylo.net/nextcloud@sha256:419685ef50d19dadc8f55e34c652961506098fdcc9bce5b633ac51e87578de0d`
(built 2025-12-20, Ubuntu 24.04, NEXTCLOUD_VER=31.0.4, php-fpm8.3) runs most
Nextcloud 31 containers and is the base of `overlays/noble-31.0.4-1`. It was
built from an uncommitted working tree; these are the inputs that can be
proven from the image itself:

| File | SHA-256 | Same as in the image |
| --- | --- | --- |
| `scripts/30_installer.sh` | `132f8c91f4821f1a1c0eb86ceedd326ad3b721147b5741f50fd2cfda346480b0` | `/etc/my_init.d/30_installer.sh` |
| `sources/nextcloud.conf` | `3037db2df34e95ca891c542cbca497f4faf345b324efc067c92f21fde501a800` | `/app-sources/nextcloud.conf` |
| `sources/crontab` | `1c7db3f87785319844d8e16da4e8c566d63d409f59ffd678e016494bb481c8b7` | `/app-sources/crontab` |
| `sources/sshd_config` | `70fb138fc5b798c87641a6a87dfcfc264fc2c8bf0381afcff18ce81bff3b2ac9` | `/app-sources/sshd_config`, `/etc/ssh/sshd_config` |

`image-history.tsv` is `docker image history --no-trunc` of the digest, with
password values redacted; it shows the Dockerfile instructions. The
Dockerfile itself is not recorded because it is not in the image and could
not be matched byte for byte. The working tree also flattened a nested clone
of `files_excludedirs` into `/app-sources` (`appinfo/`, `lib/`, `tests/`,
`composer.json`, `LICENSE`, `README.md`); it is unused and not recorded.
