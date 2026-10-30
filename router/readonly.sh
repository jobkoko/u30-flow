#!/bin/sh
# Forced command for a dedicated monitoring key; never evaluates client input.
set -u
. /usr/libexec/u30-monitor-common
load_monitor_config || { echo 'Monitor configuration is not ready.' >&2; exit 1; }
snapshot() {
    rx=0 tx=0 up=0
    read -r rx < "/sys/class/net/$DEVICE/statistics/rx_bytes" 2>/dev/null || rx=0
    read -r tx < "/sys/class/net/$DEVICE/statistics/tx_bytes" 2>/dev/null || tx=0
    read -r up rest < /proc/uptime
    vpn=0; grep -q '^ENABLE=1$' /etc/mu300/vpn.conf 2>/dev/null && vpn=1
    usage=null; [ ! -s "$STORE/usage.json" ] || usage=$(cat "$STORE/usage.json")
    stale=0; [ ! -e "$RUN/last-error" ] || stale=1
    printf '{"uptime":%s,"rx":%s,"tx":%s,"vpn":%s,"metadata_error":%s,"subscription":%s,"utc_offset":%s}\n' "$up" "$rx" "$tx" "$vpn" "$stale" "$usage" "$OFFSET"
}
case ${SSH_ORIGINAL_COMMAND:-} in
    u30-status) snapshot ;;
    u30-stream) while :; do snapshot || exit 1; sleep 3; done ;;
    *) echo 'This key permits monitor status only.' >&2; exit 77 ;;
esac
