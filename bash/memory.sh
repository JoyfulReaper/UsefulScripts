#!/usr/bin/env bash

services=(
  randomsteam
  cloudflared
  happygopher
  happyfinger
  happyecho
)

declare -A cpu_before
declare -A cpu_after

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

format_service_cpu() {
  local before="$1"
  local after="$2"
  local elapsed_ns="$3"

  if [[ "$before" =~ ^[0-9]+$ ]] &&
     [[ "$after" =~ ^[0-9]+$ ]] &&
     (( elapsed_ns > 0 )); then
    awk \
      -v before="$before" \
      -v after="$after" \
      -v elapsed="$elapsed_ns" \
      'BEGIN {
        delta = after - before

        if (delta < 0) {
          printf "N/A"
        } else {
          printf "%.2f%%", (delta / elapsed) * 100
        }
      }'
  else
    printf "N/A"
  fi
}

read_system_cpu() {
  local cpu user nice system idle iowait irq softirq steal guest guest_nice

  read -r cpu user nice system idle iowait irq softirq steal guest guest_nice \
    < /proc/stat

  SYSTEM_CPU_IDLE=$((idle + iowait))
  SYSTEM_CPU_TOTAL=$((user + nice + system + idle + iowait + irq + softirq + steal))
}

# First CPU sample.
read_system_cpu
system_total_before=$SYSTEM_CPU_TOTAL
system_idle_before=$SYSTEM_CPU_IDLE

start_ns=$(date +%s%N)

for service in "${services[@]}"; do
  cpu_before["$service"]=$(
    systemctl show "$service" \
      --property=CPUUsageNSec \
      --value \
      2>/dev/null
  )
done

sleep 1

# Second CPU sample.
read_system_cpu
system_total_after=$SYSTEM_CPU_TOTAL
system_idle_after=$SYSTEM_CPU_IDLE

end_ns=$(date +%s%N)

for service in "${services[@]}"; do
  cpu_after["$service"]=$(
    systemctl show "$service" \
      --property=CPUUsageNSec \
      --value \
      2>/dev/null
  )
done

elapsed_ns=$((end_ns - start_ns))

total_delta=$((system_total_after - system_total_before))
idle_delta=$((system_idle_after - system_idle_before))

overall_cpu=$(
  awk \
    -v total="$total_delta" \
    -v idle="$idle_delta" \
    'BEGIN {
      if (total <= 0) {
        printf "N/A"
      } else {
        printf "%.2f%%", ((total - idle) / total) * 100
      }
    }'
)

printf "Overall CPU usage: %s\n\n" "$overall_cpu"

printf "%-15s %-10s %9s %14s %14s\n" \
  "Service" "State" "CPU" "Current" "Peak"

printf "%-15s %-10s %9s %14s %14s\n" \
  "---------------" "----------" "---------" "--------------" "--------------"

for service in "${services[@]}"; do
  state=$(systemctl is-active "$service" 2>/dev/null || true)

  current=$(
    systemctl show "$service" \
      --property=MemoryCurrent \
      --value \
      2>/dev/null
  )

  peak=$(
    systemctl show "$service" \
      --property=MemoryPeak \
      --value \
      2>/dev/null
  )

  cpu=$(
    format_service_cpu \
      "${cpu_before[$service]}" \
      "${cpu_after[$service]}" \
      "$elapsed_ns"
  )

  printf "%-15s %-10s %9s %14s %14s\n" \
    "$service" \
    "${state:-unknown}" \
    "$cpu" \
    "$(format_bytes "$current")" \
    "$(format_bytes "$peak")"
done

echo
echo "Docker containers:"
sudo docker stats --no-stream \
  --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}'

echo
echo "System memory:"
free -h

echo
echo "Disk Usage:"
df -h /dev/vda1
