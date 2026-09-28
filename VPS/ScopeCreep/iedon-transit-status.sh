#!/usr/bin/env bash
set -u

IFACE="wg-dn42-iedon"
BGP="iedon_dal"
TABLE="2190"
TC="/usr/sbin/tc"

hr() { printf '%s\n' '------------------------------------------------------------'; }
section() { printf '\n%s\n' "$1"; hr; }

section "iEdon Transit Status"
date
hostname

section "BGP"
sudo birdc show protocol "$BGP" 2>/dev/null || true
echo
sudo birdc show protocols all "$BGP" 2>/dev/null | \
  grep -E 'Name|BGP state:|Neighbor address:|Neighbor AS:|Local AS:|Channel ipv[46]|Routes:' || true

section "Policy Routing"
echo "IPv4 rule:"
ip rule show | grep -E "(^| )21880:|iif ${IFACE}.*lookup ${TABLE}" || echo "MISSING"
echo
echo "IPv6 rule:"
ip -6 rule show | grep -E "(^| )21880:|iif ${IFACE}.*lookup ${TABLE}" || echo "MISSING"

echo
echo "Kernel table $TABLE route counts:"
printf 'IPv4: '
ip -4 route show table "$TABLE" 2>/dev/null | wc -l
printf 'IPv6: '
ip -6 route show table "$TABLE" 2>/dev/null | wc -l

echo
echo "iEdon health-path lookups:"
ip route get 172.23.91.112 from 172.23.91.180 iif "$IFACE" 2>/dev/null || true
ip -6 route get fd42:4242:2189:ac:6::1 from fd42:4242:2189:180::1 iif "$IFACE" 2>/dev/null || true

section "WireGuard"
echo "Endpoint:"
sudo wg show "$IFACE" endpoints 2>/dev/null || true
echo "Latest handshake (epoch):"
sudo wg show "$IFACE" latest-handshakes 2>/dev/null || true
echo "Transfer counters (bytes RX/TX):"
sudo wg show "$IFACE" transfer 2>/dev/null || true

section "50 Mbps Rate Limit"
if [[ -x "$TC" ]]; then
  echo "Egress qdisc:"
  sudo "$TC" -s qdisc show dev "$IFACE" 2>/dev/null || true
  echo
  echo "Ingress policer:"
  sudo "$TC" -s filter show dev "$IFACE" ingress 2>/dev/null || true
else
  echo "tc not found at $TC"
fi

section "Transit Firewall Rules"
sudo ufw status numbered 2>/dev/null | grep 'DN42 transit iEdon' || echo "No matching UFW transit rules found"

section "Persistence Services"
for svc in dn42-iedon-transit-policy.service dn42-iedon-rate-limit.service; do
  printf '%-42s ' "$svc"
  systemctl is-active "$svc" 2>/dev/null || true
  printf '%-42s ' ""
  systemctl is-enabled "$svc" 2>/dev/null || true
done
