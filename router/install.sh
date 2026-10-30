#!/bin/sh
# Run locally on the router. DESTDIR supports isolated packaging/tests without services.
set -eu
umask 077
base=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
prefix=${DESTDIR:-}
key= profile= url_file=
die() { printf '%s\n' "$1" >&2; exit 1; }
while [ $# -gt 0 ]; do
    case $1 in
        --public-key) [ $# -ge 2 ] || die 'Missing public key path'; key=$2; shift 2 ;;
        --profile) [ $# -ge 2 ] || die 'Missing profile path'; profile=$2; shift 2 ;;
        --subscription-url-file) [ $# -ge 2 ] || die 'Missing URL file path'; url_file=$2; shift 2 ;;
        -h|--help) echo 'install.sh --public-key FILE [--profile ROUTER_PATH | --subscription-url-file ROUTER_PATH]'; exit 0 ;;
        *) die 'Unknown argument' ;;
    esac
done
case $prefix in ''|/*) ;; *) die 'DESTDIR must be absolute' ;; esac
[ -n "$prefix" ] || [ "$(id -u)" = 0 ] || die 'Run as root on the router'
[ -n "$key" ] && [ -f "$key" ] && [ ! -L "$key" ] || die 'Provide a dedicated Ed25519 public key file'
[ "$(wc -l < "$key" | tr -d ' ')" = 1 ] || die 'Public key must contain exactly one line'
LC_ALL=C grep -Eq '^ssh-ed25519 [A-Za-z0-9+/=]+( [A-Za-z0-9._@ -]+)?$' "$key" || die 'Invalid public key format'
[ -z "$profile" ] || [ -z "$url_file" ] || die 'Choose a profile OR a URL file'
for path in "$profile" "$url_file"; do
    [ -z "$path" ] || { printf '%s\n' "$path" | LC_ALL=C grep -Eq '^/[A-Za-z0-9_./-]+$'; } || die 'Invalid router file path'
done
store=$prefix/etc/u30-monitor
auth=$prefix/etc/dropbear/authorized_keys
marker=$store/installed-by-u30-flow
for file in "$auth" "$store/config" "$marker"; do [ ! -L "$file" ] || die 'Refusing a symlink'; done
for file in /usr/libexec/u30-menubar-readonly /usr/libexec/u30-monitor-collector /usr/libexec/u30-monitor-common /usr/libexec/u30-usage-state.awk /etc/init.d/u30-monitor; do
    [ ! -L "$prefix$file" ] || die 'Refusing an existing symlink'
    [ ! -e "$prefix$file" ] || [ -f "$marker" ] || die 'An unrecognized installation exists; inspect before upgrading'
done
if [ ! -f "$store/config" ]; then
    [ -n "$profile$url_file" ] || die 'Choose a profile or root-only URL file for the initial configuration'
fi
for file in common.sh collector.sh readonly.sh u30-monitor.init; do /bin/sh -n "$base/$file"; done
key_blob=$(awk '{print $2}' "$key")
forced='command="/usr/libexec/u30-menubar-readonly",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty '
key_line=$forced$(cat "$key")
if [ -f "$auth" ] && grep -Fq -- "$key_blob" "$auth"; then
    grep -Fxq -- "$key_line" "$auth" || die 'This key is already authorized differently; generate a new dedicated monitor key'
fi
mkdir -p "$prefix/root" "$prefix/usr/libexec" "$prefix/etc/init.d" "$prefix/etc/dropbear" "$store"
chmod 700 "$store"
backup=$(mktemp -d "$prefix/root/u30-flow-backup.XXXXXX")
chmod 700 "$backup"
for file in "$auth" "$store/config" "$prefix/usr/libexec/u30-menubar-readonly" "$prefix/usr/libexec/u30-monitor-collector" "$prefix/usr/libexec/u30-monitor-common" "$prefix/usr/libexec/u30-usage-state.awk" "$prefix/etc/init.d/u30-monitor"; do
    [ ! -f "$file" ] || cp -p "$file" "$backup/$(basename "$file")"
done
cp "$base/common.sh" "$prefix/usr/libexec/u30-monitor-common"
cp "$base/collector.sh" "$prefix/usr/libexec/u30-monitor-collector"
cp "$base/readonly.sh" "$prefix/usr/libexec/u30-menubar-readonly"
cp "$base/usage-state.awk" "$prefix/usr/libexec/u30-usage-state.awk"
cp "$base/u30-monitor.init" "$prefix/etc/init.d/u30-monitor"
chmod 755 "$prefix/usr/libexec/u30-monitor-collector" "$prefix/usr/libexec/u30-menubar-readonly" "$prefix/etc/init.d/u30-monitor"
chmod 644 "$prefix/usr/libexec/u30-monitor-common" "$prefix/usr/libexec/u30-usage-state.awk"
if [ -n "$profile$url_file" ]; then
    printf 'PROFILE=%s\nSUBSCRIPTION_URL_FILE=%s\nCELLULAR_INTERFACE=sipa_eth0\nPOLL_INTERVAL=300\nUTC_OFFSET=28800\n' "$profile" "$url_file" > "$store/config"
fi
chmod 600 "$store/config"
if [ -f "$auth" ]; then cat "$auth" > "$auth.next"; printf '\n' >> "$auth.next"; else : > "$auth.next"; fi
if ! grep -Fxq -- "$key_line" "$auth.next"; then printf '%s\n' "$key_line" >> "$auth.next"; fi
chmod 600 "$auth.next"
mv "$auth.next" "$auth"
printf '%s\n' "$key_line" > "$marker.next"
chmod 600 "$marker.next"
mv "$marker.next" "$marker"
if [ -z "$prefix" ]; then
    /etc/init.d/u30-monitor enable
    /etc/init.d/u30-monitor restart
fi
echo 'Installed U30 Flow monitor. Existing network and VPN services were not restarted.'
