#!/bin/sh
# Parse a root-owned data file; never source/eval its contents.
STORE=/etc/u30-monitor
RUN=/run/u30-monitor
config_value() {
    value=$(awk -v key="$1" 'index($0,key "=")==1 {v=substr($0,length(key)+2)} END {print v}' "$STORE/config" 2>/dev/null)
    printf '%s' "${value:-$2}"
}
load_monitor_config() {
    [ -f "$STORE/config" ] && [ ! -L "$STORE/config" ] || return 1
    PROFILE=$(config_value PROFILE '')
    SUBSCRIPTION_URL_FILE=$(config_value SUBSCRIPTION_URL_FILE '')
    DEVICE=$(config_value CELLULAR_INTERFACE sipa_eth0)
    INTERVAL=$(config_value POLL_INTERVAL 300)
    OFFSET=$(config_value UTC_OFFSET 28800)
    printf '%s\n' "$DEVICE" | LC_ALL=C grep -Eq '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,14}$' || return 1
    case $INTERVAL in ''|*[!0-9]*) return 1 ;; esac
    [ "$INTERVAL" -ge 60 ] && [ "$INTERVAL" -le 86400 ] || return 1
    printf '%s\n' "$OFFSET" | grep -Eq '^-?[0-9]{1,5}$' || return 1
    [ "$OFFSET" -ge -50400 ] && [ "$OFFSET" -le 50400 ] || return 1
}
