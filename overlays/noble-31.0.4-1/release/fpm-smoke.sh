#!/bin/sh
# Usage (inside the image): fpm-smoke.sh <php-fpm binary>
#
# Serves a PHP page through the image's nginx and php-fpm, then posts a
# multipart upload to it. php-fpm loads the image's own FPM php.ini and
# extensions; only the pool and the nginx server block are minimal ones
# written here, so the test does not depend on the Nextcloud installer.
# Prints the SAPI and PHP version that answered.
set -eu

fpm_bin=${1:?usage: fpm-smoke.sh <php-fpm binary>}
work=$(mktemp -d)
nginx_pid=
fpm_pid=
cleanup() {
    [ -z "$nginx_pid" ] || kill "$nginx_pid" 2>/dev/null || true
    [ -z "$fpm_pid" ] || kill "$fpm_pid" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$work/www"
cat > "$work/www/info.php" <<'PHP'
<?php echo 'ok ', PHP_SAPI, ' ', PHP_VERSION;
PHP
cat > "$work/www/upload.php" <<'PHP'
<?php echo count($_FILES), ':', $_FILES['f']['size'] ?? -1, ':', $_POST['a'] ?? '';
PHP
printf 'hello' > "$work/upload.txt"
chmod -R a+rX "$work"

cat > "$work/fpm.conf" <<EOF
[global]
error_log = $work/fpm.log
daemonize = no

[smoke]
user = nobody
group = nogroup
listen = 127.0.0.1:9071
pm = static
pm.max_children = 2
catch_workers_output = yes
EOF

cat > "$work/nginx.conf" <<EOF
user nobody nogroup;
worker_processes 1;
daemon off;
pid $work/nginx.pid;
error_log $work/nginx-error.log;
events {}
http {
    access_log off;
    client_body_temp_path $work/body;
    fastcgi_temp_path $work/fastcgi;
    proxy_temp_path $work/proxy;
    uwsgi_temp_path $work/uwsgi;
    scgi_temp_path $work/scgi;
    server {
        listen 127.0.0.1:8091;
        root $work/www;
        location ~ \.php\$ {
            include /etc/nginx/fastcgi_params;
            fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
            fastcgi_pass 127.0.0.1:9071;
        }
    }
}
EOF

"$fpm_bin" -t -y "$work/fpm.conf" >/dev/null 2>&1 || { "$fpm_bin" -t -y "$work/fpm.conf"; exit 1; }
nginx -t -c "$work/nginx.conf" >/dev/null 2>&1 || { nginx -t -c "$work/nginx.conf"; exit 1; }

"$fpm_bin" -F -y "$work/fpm.conf" &
fpm_pid=$!
nginx -c "$work/nginx.conf" &
nginx_pid=$!

# Wait until php-fpm answers through nginx (a 502 means it is not ready yet).
page=
attempt=0
while [ "$attempt" -lt 60 ]; do
    page=$(curl -fs --max-time 5 http://127.0.0.1:8091/info.php) && [ -n "$page" ] && break
    page=
    attempt=$((attempt + 1))
    sleep 0.5
done
case "$page" in
    "ok fpm-fcgi "*) ;;
    *)
        echo "PHP page through nginx and $fpm_bin returned '$page'" >&2
        cat "$work/fpm.log" "$work/nginx-error.log" >&2 2>/dev/null || true
        exit 1
        ;;
esac

result=$(curl -s --max-time 10 -F a=b -F "f=@$work/upload.txt" http://127.0.0.1:8091/upload.php)
if [ "$result" != "1:5:b" ]; then
    echo "multipart upload through nginx and $fpm_bin returned '$result', expected '1:5:b'" >&2
    cat "$work/fpm.log" "$work/nginx-error.log" >&2 2>/dev/null || true
    exit 1
fi
echo "PHP page served ($page) and multipart upload parsed through nginx and $fpm_bin"
