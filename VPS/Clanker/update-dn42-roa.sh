#!/bin/sh

# Refresh DN42's generated BIRD 2 ROA tables safely.
#
# Intended install location:
#   /usr/local/sbin/update-dn42-roa
#
# Example cron:
#   */15 * * * * root /usr/local/sbin/update-dn42-roa

set -eu

ROA4_URL="https://dn42.burble.com/roa/dn42_roa_bird2_4.conf"
ROA6_URL="https://dn42.burble.com/roa/dn42_roa_bird2_6.conf"

ROA4="/etc/bird/roa_dn42.conf"
ROA6="/etc/bird/roa_dn42_v6.conf"

TMP4="$(mktemp)"
TMP6="$(mktemp)"
BACKUP4=""
BACKUP6=""

cleanup() {
    rm -f "$TMP4" "$TMP6"

    if [ -n "$BACKUP4" ]; then
        rm -f "$BACKUP4"
    fi

    if [ -n "$BACKUP6" ]; then
        rm -f "$BACKUP6"
    fi
}

restore_previous() {
    if [ -n "$BACKUP4" ] && [ -f "$BACKUP4" ]; then
        cp "$BACKUP4" "$ROA4"
    else
        rm -f "$ROA4"
    fi

    if [ -n "$BACKUP6" ] && [ -f "$BACKUP6" ]; then
        cp "$BACKUP6" "$ROA6"
    else
        rm -f "$ROA6"
    fi
}

trap cleanup EXIT HUP INT TERM

/usr/bin/curl -fsSL "$ROA4_URL" -o "$TMP4"
/usr/bin/curl -fsSL "$ROA6_URL" -o "$TMP6"

IPV4_COUNT="$(grep -c '^route ' "$TMP4" || true)"
IPV6_COUNT="$(grep -c '^route ' "$TMP6" || true)"

# Don't replace working ROA data with an error page, truncated download, etc.
if [ "$IPV4_COUNT" -lt 1000 ]; then
    logger -t dn42-roa \
        "IPv4 ROA update rejected: suspiciously few routes ($IPV4_COUNT)"
    exit 1
fi

if [ "$IPV6_COUNT" -lt 1000 ]; then
    logger -t dn42-roa \
        "IPv6 ROA update rejected: suspiciously few routes ($IPV6_COUNT)"
    exit 1
fi

# The common case: nothing changed, so don't make BIRD reconfigure itself
# just because cron ran.
if [ -f "$ROA4" ] &&
   [ -f "$ROA6" ] &&
   cmp -s "$TMP4" "$ROA4" &&
   cmp -s "$TMP6" "$ROA6"
then
    logger -t dn42-roa \
        "ROA tables unchanged: IPv4=$IPV4_COUNT IPv6=$IPV6_COUNT"
    exit 0
fi

if [ -f "$ROA4" ]; then
    BACKUP4="$(mktemp)"
    cp "$ROA4" "$BACKUP4"
fi

if [ -f "$ROA6" ]; then
    BACKUP6="$(mktemp)"
    cp "$ROA6" "$BACKUP6"
fi

install -m 0644 "$TMP4" "$ROA4"
install -m 0644 "$TMP6" "$ROA6"

if ! /usr/sbin/bird -p -c /etc/bird/bird.conf; then
    restore_previous

    logger -t dn42-roa \
        "New ROA files failed BIRD validation; restored previous files"

    exit 1
fi

if ! /usr/sbin/birdc configure >/dev/null; then
    restore_previous

    # Best effort: put the running daemon back onto the restored files.
    /usr/sbin/birdc configure >/dev/null 2>&1 || true

    logger -t dn42-roa \
        "BIRD rejected the new ROA configuration; restored previous files"

    exit 1
fi

logger -t dn42-roa \
    "ROA tables updated: IPv4=$IPV4_COUNT IPv6=$IPV6_COUNT"
