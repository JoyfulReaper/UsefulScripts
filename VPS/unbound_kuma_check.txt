#!/bin/bash

set -u

source /etc/unbound-kuma-check.env

if timeout 5 dig @127.0.0.1 -p 5335 example.com A +short | grep -q .; then
    curl -fsS --max-time 5 \
        "${PUSH_URL}?status=up&msg=DNS_OK" >/dev/null
else
    curl -fsS --max-time 5 \
        "${PUSH_URL}?status=down&msg=DNS_FAILED" >/dev/null
fi