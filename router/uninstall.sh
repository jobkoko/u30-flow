#!/bin/sh
set -eu
umask 077
prefix=${DESTDIR:-}
case $prefix in ''|/*) ;; *) echo 'DESTDIR must be absolute' >&2; exit 1 ;; esac
[ -n "$prefix" ] || [ "$(id -u)" = 0 ] || exit 1
store=$prefix/etc/u30-monitor
marker=$store/installed-by-u30-flow
auth=$prefix/etc/dropbear/authorized_keys
[ -f "$marker" ] && [ ! -L "$marker" ] && [ ! -L "$auth" ] || { echo 'No recognized installation'; exit 1; }
[ "$(wc -l < "$marker" | tr -d ' ')" = 1 ] || { echo 'Invalid installation marker'; exit 1; }
owned=$(cat "$marker")
case $owned in
    'command="/usr/libexec/u30-menubar-readonly",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty ssh-ed25519 '*) ;;
    *) echo 'Invalid installation marker'; exit 1 ;;
esac
if [ -z "$prefix" ]; then
    /etc/init.d/u30-monitor stop
    /etc/init.d/u30-monitor disable
fi
if [ -f "$auth" ]; then
    awk -v owned="$owned" '$0!=owned' "$auth" > "$auth.next"
    chmod 600 "$auth.next"; mv "$auth.next" "$auth"
fi
rm -f "$prefix/usr/libexec/u30-monitor-common" "$prefix/usr/libexec/u30-monitor-collector" "$prefix/usr/libexec/u30-menubar-readonly" "$prefix/usr/libexec/u30-usage-state.awk" "$prefix/etc/init.d/u30-monitor" "$marker"
echo 'Removed monitor and its key. Retained root-only configuration/history for manual recovery.'
