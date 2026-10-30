#!/bin/sh
set -u
umask 077
. /usr/libexec/u30-monitor-common
mkdir -p "$STORE" "$RUN"
chmod 700 "$STORE" "$RUN"
trap 'rm -f "$RUN/curl.conf" "$RUN/headers" "$RUN/fetch-error"' EXIT
trap 'exit 0' TERM INT HUP
poll() {
    load_monitor_config || return 2
    if [ -n "$SUBSCRIPTION_URL_FILE" ]; then
        [ -f "$SUBSCRIPTION_URL_FILE" ] && [ ! -L "$SUBSCRIPTION_URL_FILE" ] || return 2
        urls=$(cat "$SUBSCRIPTION_URL_FILE")
    else
        [ -n "$PROFILE" ] && [ -f "$PROFILE" ] || return 2
        # Only the simple, single-provider YAML style used by mu300 profiles.
        # Multiple URLs are refused instead of guessing which account to charge.
        urls=$(awk '/^proxy-providers:/ {p=1;next} p && /^[^ ]/ {p=0} p && /^    url:/ {sub(/^    url:[[:space:]]*/, ""); print}' "$PROFILE")
    fi
    [ "$(printf '%s\n' "$urls" | wc -l | tr -d ' ')" = 1 ] || return 2
    url=$(printf '%s' "$urls" | sed "s/^['\"]//;s/['\"]$//")
    case $url in https://*) ;; *) return 2 ;; esac
    # Reject whitespace/config metacharacters. A real URL must percent-encode them.
    printf '%s' "$url" | LC_ALL=C grep -q '[[:space:]"\\]' && return 2
    fingerprint=$(printf '%s' "$url" | sha256sum | cut -c1-24)
    printf 'url = "%s"\n' "$url" > "$RUN/curl.conf"
    if ! curl --config "$RUN/curl.conf" --silent --show-error --fail --location --head \
        --proto '=https' --proto-redir '=https' --max-redirs 3 --connect-timeout 8 --max-time 25 \
        --user-agent clash --dump-header "$RUN/headers" --output /dev/null 2> "$RUN/fetch-error"; then
        rm -f "$RUN/curl.conf" "$RUN/headers" "$RUN/fetch-error"
        return 3
    fi
    rm -f "$RUN/curl.conf"
    info=$(tr -d '\r' < "$RUN/headers" | awk 'tolower($0) ~ /^subscription-userinfo:/ {sub(/^[^:]*:[[:space:]]*/, ""); x=$0} END {print x}')
    values=$(printf '%s' "$info" | awk -F';' '{for(i=1;i<=NF;i++){split($i,a,"=");gsub(/[[:space:]]/,"",a[1]);gsub(/[[:space:]]/,"",a[2]);if(a[2]~/^[0-9]+$/ && length(a[2])<=16)v[a[1]]=a[2]} if("upload" in v && "download" in v && "total" in v && v["total"]>0) printf "%.0f %.0f %.0f\n",v["upload"]+v["download"],v["total"],v["expire"]+0}')
    rm -f "$RUN/headers" "$RUN/fetch-error"
    [ -n "$values" ] || return 4
    set -- $values
    used=$1 total=$2 expire=$3
    now=$(date +%s)
    day=$(date -u -d "@$((now+OFFSET))" +%F) || return 5
    midnight=$(( (now+OFFSET)/86400*86400-OFFSET ))
    [ -f "$STORE/state.tsv" ] || : > "$STORE/state.tsv"
    awk -v day="$day" -v now="$now" -v midnight="$midnight" -v used="$used" -v total="$total" \
        -v expire="$expire" -v fingerprint="$fingerprint" -f /usr/libexec/u30-usage-state.awk \
        "$STORE/state.tsv" > "$STORE/state.next" || return 5
    [ -s "$STORE/state.next" ] || return 5
    mv "$STORE/state.next" "$STORE/state.tsv" || return 5
    { [ ! -f "$STORE/history.tsv" ] || awk -F '\t' -v d="$day" '$1!=d' "$STORE/history.tsv"; cat "$STORE/state.tsv"; } | tail -n 90 > "$STORE/history.next"
    mv "$STORE/history.next" "$STORE/history.tsv" || return 5
    awk -F '\t' '{r=$9-$4;if(r<0)r=0;printf "{\"date\":\"%s\",\"first\":%s,\"updated\":%s,\"used\":%s,\"today\":%s,\"partial\":%s,\"reset\":%s,\"total\":%s,\"expire\":%s,\"remaining\":%.0f}\n",$1,$2,$3,$4,$5,$6,$7,$9,$10,r}' "$STORE/state.tsv" > "$STORE/usage.next" || return 5
    mv "$STORE/usage.next" "$STORE/usage.json" || return 5
    rm -f "$RUN/last-error"
}
case ${1:-run} in
    once) poll ;;
    run)
        while :; do
            INTERVAL=300 OFFSET=28800
            if poll; then :; else
                status=$?
                INTERVAL=300 OFFSET=28800
                printf 'metadata unavailable (%s)\n' "$status" > "$RUN/last-error"
            fi
            now=$(date +%s); until_midnight=$((86400-(now+OFFSET)%86400))
            wait_s=$INTERVAL; [ "$until_midnight" -ge "$wait_s" ] || wait_s=$until_midnight
            sleep "$wait_s"
        done ;;
    *) exit 2 ;;
esac
