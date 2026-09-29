#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

[[ "$(id -u)" == 0 ]] || { printf '%s\n' 'Run this bootstrap only while provisioning a new image or VM as root.' >&2; exit 1; }
. /etc/os-release
case "$ID:$VERSION_CODENAME" in
  ubuntu:jammy|ubuntu:noble|debian:bookworm) ;;
  *) printf '%s\n' 'Unsupported nginx bootstrap distribution.' >&2; exit 1 ;;
esac

nginx_version=1.30.5
njs_version=1.0.1
fingerprint=8540A6F18833A80E9C1653A42FD21310B49F6B46
scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
chmod 700 "$scratch"
export GNUPGHOME="$scratch/gnupg"
mkdir -m 700 "$GNUPGHOME"
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg
curl --fail --silent --show-error --proto '=https' --tlsv1.2 --max-time 60 \
  https://nginx.org/keys/nginx_signing.key -o "$scratch/signing.key"
gpg --batch --quiet --import "$scratch/signing.key"
gpg --batch --with-colons --fingerprint "$fingerprint" | grep -q "^fpr:::::::::$fingerprint:"
gpg --batch --export "$fingerprint" > "$scratch/keyring.gpg"
install -m 644 "$scratch/keyring.gpg" /usr/share/keyrings/byok-nginx.gpg
printf 'deb [signed-by=/usr/share/keyrings/byok-nginx.gpg] https://nginx.org/packages/%s %s nginx\n' "$ID" "$VERSION_CODENAME" > /etc/apt/sources.list.d/byok-nginx.list
apt-get update
apt-get install -y --no-install-recommends \
  "nginx=$nginx_version-1~$VERSION_CODENAME" \
  "nginx-module-njs=$nginx_version+$njs_version-1~$VERSION_CODENAME"
test -f /usr/lib/nginx/modules/ngx_http_js_module.so
mkdir -p /etc/nginx/modules-enabled
printf '%s\n' 'load_module /usr/lib/nginx/modules/ngx_http_js_module.so;' > /etc/nginx/modules-enabled/50-byok-http-js.conf
if ! grep -Eq '^[[:space:]]*include[[:space:]]+/etc/nginx/modules-enabled/\*\.conf;' /etc/nginx/nginx.conf; then
  sed -i '1i include /etc/nginx/modules-enabled/*.conf;' /etc/nginx/nginx.conf
fi
nginx -t
printf '%s\n' 'BYOK_NGINX_NJS_INSTALLED'