#!/usr/bin/env bash

services=(
  randomsteam
  cloudflared
  happygopher
)

format_bytes() {
  local bytes="$1"

  if [[ "$bytes" =~ ^[0-9]+$ ]]; then
    awk -v bytes="$bytes" 'BEGIN {
      printf "%.2f MB", bytes / 1024 / 1024
    }'
  else
    printf "N/A"
  fi
}

printf "%-15s %-10s %14s %14s\n" \
  "Service" "State" "Current" "Peak"

printf "%-15s %-10s %14s %14s\n" \
  "---------------" "----------" "--------------" "--------------"

for service in "${services[@]}"; do
  state=$(systemctl is-active "$service" 2>/dev/null || true)
  current=$(systemctl show "$service" -p MemoryCurrent --value 2>/dev/null)
  peak=$(systemctl show "$service" -p MemoryPeak --value 2>/dev/null)

  printf "%-15s %-10s %14s %14s\n" \
    "$service" \
    "${state:-unknown}" \
    "$(format_bytes "$current")" \
    "$(format_bytes "$peak")"
done

echo
sudo docker stats --no-stream \
  --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}'

echo
free -h
