#!/usr/bin/env bash
set -eu

export LC_ALL=C

logdir=/var/log/network-link-recorder
ringdir=/run/network-link-recorder
target=
interface=
duration=480
interval=1
burst=15
keep=7
stopping=0
manual=0
capture_pid=
capture_error=

usage() {
  cat <<'EOF'
Usage: network-link-recorder [options]

Probe one interface at a fixed interval. When probes fail, record interface
state, counters and the packets leading up to the failure. Every probe, burst
and capture is bound to the monitored interface.

  --target ADDRESS    Address to probe. Defaults to the gateway of the
                      monitored interface.
  --interface NAME    Interface to monitor. Defaults to the interface that
                      routes to --target, otherwise the interface holding the
                      default route.
  --duration MINUTES  Length of the run. Defaults to 480.
  --interval SECONDS  Seconds between probes. Defaults to 1.
  --burst MINUTES     Minutes between bursts of one thousand large pings. Zero
                      disables them. Defaults to 15.
  --keep DAYS         Delete logs and captures older than this at startup.
                      Zero keeps everything. Defaults to 7.
  --logdir DIRECTORY  Directory for logs and summaries. Defaults to
                      /var/log/network-link-recorder.
  --ringdir DIRECTORY Directory for the rotating packet capture, which is
                      written continuously and copied out on each event.
                      Defaults to /run/network-link-recorder, a tmpfs.
  -h, --help          Show this message.

Send SIGUSR1 to record an event immediately, for a failure you observe
rather than one the probes detect:

  systemctl kill -s SIGUSR1 --kill-who=main network-link-recorder
EOF
}

die() {
  printf 'network-link-recorder: %s\n' "$*" >&2
  exit 1
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --target)
        target=${2?--target needs an address}
        shift 2
        ;;
      --interface)
        interface=${2?--interface needs a name}
        shift 2
        ;;
      --duration)
        duration=${2:?--duration needs minutes}
        shift 2
        ;;
      --interval)
        interval=${2:?--interval needs seconds}
        shift 2
        ;;
      --burst)
        burst=${2:?--burst needs minutes}
        shift 2
        ;;
      --keep)
        keep=${2:?--keep needs days}
        shift 2
        ;;
      --logdir)
        logdir=${2:?--logdir needs a directory}
        shift 2
        ;;
      --ringdir)
        ringdir=${2:?--ringdir needs a directory}
        shift 2
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        usage >&2
        die "unknown argument: $1"
        ;;
    esac
  done

  case "$duration" in
    '' | *[!0-9]*) die "--duration takes whole minutes" ;;
  esac
  case "$interval" in
    '' | *[!0-9]*) die "--interval takes whole seconds" ;;
  esac
  case "$burst" in
    '' | *[!0-9]*) die "--burst takes whole minutes" ;;
  esac
  case "$keep" in
    '' | *[!0-9]*) die "--keep takes whole days" ;;
  esac
  [ "$interval" -gt 0 ] || die "--interval must be at least 1"
  [ "$duration" -gt 0 ] || die "--duration must be at least 1"
}

now() {
  date +%s
}

stamp() {
  date -u +%Y%m%dT%H%M%SZ
}

iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

read_value() {
  cat "$1" 2>/dev/null || true
}

read_counter() {
  local value
  value=$(read_value "/sys/class/net/$interface/statistics/$1")
  printf '%s' "${value:-0}"
}

retrans_count() {
  local value
  value=$({ nstat -az 2>/dev/null || true; } | sed -n 's/^TcpRetransSegs[[:space:]]\{1,\}\([0-9]\{1,\}\).*/\1/p' | head -n 1)
  printf '%s' "${value:-0}"
}

counters_line() {
  {
    ethtool -S "$interface" 2>/dev/null || true
  } | {
    grep -iE 'error|drop|fifo|missed|overflow|carrier|collision' || true
  } | {
    grep -v ': 0$' || true
  } | tr '\n' ' '
}

to_centiseconds() {
  local whole=${1%%.*}
  local fraction
  case "$1" in
    *.*) fraction=${1#*.} ;;
    *) fraction=0 ;;
  esac
  fraction=${fraction}00
  printf '%s' "$((whole * 100 + 10#${fraction:0:2}))"
}

format_centiseconds() {
  if [ "${1:-}" = "" ]; then
    printf '%s' '-'
  else
    printf '%d.%02d' "$(( $1 / 100 ))" "$(( $1 % 100 ))"
  fi
}

default_routes() {
  { ip -o route show default 2>/dev/null || true; }
}

detect_interface_for_target() {
  [ -n "$target" ] || return 0
  { ip -o route get "$target" 2>/dev/null || true; } \
    | sed -n 's/.* dev \([^ ]\{1,\}\).*/\1/p' \
    | head -n 1
}

detect_interface() {
  default_routes | sed -n 's/.* dev \([^ ]\{1,\}\).*/\1/p' | head -n 1
}

detect_target() {
  default_routes \
    | { grep -E " dev ${interface}( |$)" || true; } \
    | sed -n 's/.* via \([^ ]\{1,\}\).*/\1/p' \
    | head -n 1
}

prune_old_runs() {
  [ "$keep" -gt 0 ] || return 0
  find "$logdir" -maxdepth 1 -type f -mtime "+$keep" -delete 2>/dev/null || true
  find "$logdir/events" -maxdepth 1 -mindepth 1 -type d -mtime "+$keep" -exec rm -rf {} + 2>/dev/null || true
}

probe() {
  local output
  output=$({ ping -I "$interface" -n -q -c 1 -W 1 "$target" 2>&1 || true; })
  printf '%s' "$output" | sed -n 's/^rtt [^=]*= \([0-9.]\{1,\}\).*/\1/p'
}

start_capture() {
  mkdir -p "$ringdir"
  : >"$ringdir/tcpdump.log"
  tcpdump -p -i "$interface" -s 128 -U -C 8 -W 4 -w "$ringdir/ring.pcap" \
    'arp or icmp or icmp6 or tcp port 22' >>"$ringdir/tcpdump.log" 2>&1 &
  capture_pid=$!
  sleep 1
  if ! kill -0 "$capture_pid" 2>/dev/null; then
    capture_error="tcpdump exited: $(tr '\n' ' ' <"$ringdir/tcpdump.log")"
    printf '%s capture-failed %s\n' "$(iso)" "$capture_error" >>"$logfile"
    capture_pid=
  else
    printf '%s capture-started interface=%s filter=arp,icmp,icmp6,tcp/22 promiscuous=no\n' "$(iso)" "$interface" >>"$logfile"
  fi
}

stop_capture() {
  if [ -n "$capture_pid" ]; then
    kill -TERM "$capture_pid" 2>/dev/null || true
    wait "$capture_pid" 2>/dev/null || true
    capture_pid=
  fi
}

write_context() {
  {
    printf '%s context generation=%s\n' "$(iso)" "$(readlink -f /run/current-system 2>/dev/null || echo unknown)"
    printf '%s context boot=%s kernel=%s\n' "$(iso)" "$(read_value /proc/sys/kernel/random/boot_id)" "$(read_value /proc/sys/kernel/osrelease)"
    printf -- '-- addresses\n'
    ip -brief addr show 2>/dev/null || true
    printf -- '-- routes\n'
    ip route show 2>/dev/null || true
    printf -- '-- link\n'
    {
      ethtool "$interface" 2>/dev/null || true
    } | grep -E 'Speed|Duplex|Auto-negotiation|Supported link modes|Advertised link modes' || true
    printf -- '-- eee\n'
    ethtool --show-eee "$interface" 2>/dev/null || true
  } >>"$logfile"
}

copy_capture() {
  local ts=$1
  local file
  local copied=0
  local total=0
  local packets=0
  local failures=0
  local found=
  local message=

  if [ -n "$capture_pid" ] && ! kill -0 "$capture_pid" 2>/dev/null; then
    capture_error="tcpdump exited: $(tr '\n' ' ' <"$ringdir/tcpdump.log")"
    printf '%s capture-failed %s\n' "$(iso)" "$capture_error" >>"$logfile"
    capture_pid=
  fi

  if [ -z "$capture_pid" ]; then
    printf 'capture: unavailable (%s)\n' "${capture_error:-not running}" >>"$directory/events.log"
    return 0
  fi

  for file in "$ringdir"/ring.pcap*; do
    [ -e "$file" ] || continue
    found=yes
    message=$(cp "$file" "$directory/$ts-$(basename "$file")" 2>&1) || {
      printf '%s capture-copy-failed file=%s error=%s\n' \
        "$(iso)" "$file" "$(printf '%s' "$message" | tr '\n' ' ')" >>"$logfile"
      failures=$((failures + 1))
      continue
    }
    copied=$((copied + 1))
    total=$((total + $(read_counter_bytes "$file")))
  done

  if [ -z "$found" ]; then
    printf 'capture: running, no capture files written yet\n' >>"$directory/events.log"
    return 0
  fi

  for file in "$directory/$ts-ring.pcap"*; do
    [ -e "$file" ] || continue
    packets=$((packets + $( { tcpdump -nr "$file" 2>/dev/null || true; } | wc -l )))
  done
  printf 'capture: %s files, %s bytes, %s packets, %s copy failures\n' \
    "$copied" "$total" "$packets" "$failures" >>"$directory/events.log"
}

read_counter_bytes() {
  wc -c <"$1" 2>/dev/null || printf '0'
}

capture_event() {
  local trigger=$1
  local ts
  ts=$(stamp)
  directory="$logdir/events/$runid"
  mkdir -p "$directory"

  {
    printf '== event %s trigger=%s\n' "$ts" "$trigger"
    printf 'date: %s\n' "$(iso)"
    printf 'target: %s interface: %s\n' "$target" "$interface"
    printf 'operstate: %s carrier: %s\n' \
      "$(read_value "/sys/class/net/$interface/operstate")" \
      "$(read_value "/sys/class/net/$interface/carrier")"
    printf 'speed: %s\n' "$({ ethtool "$interface" 2>/dev/null || true; } | sed -n 's/^[[:space:]]*Speed: //p')"
    printf -- '-- ip -s link\n'
    ip -s link show "$interface" 2>/dev/null || true
    printf -- '-- counters\n'
    counters_line
    printf '\n'
    printf -- '-- neighbours\n'
    ip neigh show dev "$interface" 2>/dev/null || true
    printf -- '-- softnet\n'
    read_value /proc/net/softnet_stat
    printf -- '-- pressure\n'
    printf 'cpu: %s\n' "$(read_value /proc/pressure/cpu)"
    printf 'io: %s\n' "$(read_value /proc/pressure/io)"
    printf 'memory: %s\n' "$(read_value /proc/pressure/memory)"
    printf -- '-- load\n'
    printf 'loadavg: %s\n' "$(read_value /proc/loadavg)"
    printf 'meminfo: %s\n' "$( { grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree)' /proc/meminfo 2>/dev/null || true; } | tr '\n' ' ')"
    printf -- '-- kernel messages\n'
    { dmesg -T 2>/dev/null || true; } | tail -n 40
  } >>"$directory/events.log"

  copy_capture "$ts"

  logger -t network-link-recorder "event $ts trigger=$trigger interface=$interface details $directory"
}

run_burst() {
  local output
  local transmitted=
  local received=
  local loss=
  local rtt=
  output=$({ ping -I "$interface" -n -q -c 1000 -s 1472 -i 0.02 -W 2 "$target" 2>&1 || true; })
  transmitted=$(printf '%s' "$output" | sed -n 's/^\([0-9]\{1,\}\) packets transmitted.*/\1/p')
  received=$(printf '%s' "$output" | sed -n 's/^[0-9]\{1,\} packets transmitted, \([0-9]\{1,\}\) received.*/\1/p')
  loss=$(printf '%s' "$output" | sed -n 's/.*, \([0-9.]\{1,\}\)% packet loss.*/\1/p')
  rtt=$(printf '%s' "$output" | sed -n 's/^rtt [^=]*= \(.*\)/\1/p')
  printf '%s burst transmitted=%s received=%s loss=%s rtt=%s\n' \
    "$(iso)" "${transmitted:-unknown}" "${received:-unknown}" "${loss:-unknown}" "${rtt:-none}" >>"$logfile"
  printf '%s burst counters %s\n' "$(iso)" "$(counters_line)" >>"$logfile"
  if [ -n "$transmitted" ] && [ "$transmitted" != "${received:-}" ]; then
    {
      printf '%s burst output\n' "$(iso)"
      printf '%s\n' "$output"
    } >>"$logfile"
    capture_event burst
    events=$((events + 1))
  fi
}

write_summary() {
  local directory="$logdir/events/$runid"
  local average=0

  if [ "$probes_ok" -gt 0 ]; then
    average=$((rtt_sum / probes_ok))
  fi

  {
    printf 'network-link-recorder summary\n'
    printf 'run: %s\n' "$runid"
    printf 'target: %s\n' "$target"
    printf 'interface: %s\n' "$interface"
    printf 'started: %s\n' "$started"
    printf 'updated: %s\n' "$(iso)"
    printf 'duration minutes: %s\n' "$duration"
    printf 'probe interval seconds: %s\n' "$interval"
    printf 'burst period minutes: %s\n' "$burst"
    printf 'generation: %s\n' "$(readlink -f /run/current-system 2>/dev/null || echo unknown)"
    printf 'boot: %s\n' "$(read_value /proc/sys/kernel/random/boot_id)"
    printf '\n'
    printf 'probes: %s\n' "$probes"
    printf 'lost: %s\n' "$probes_lost"
    printf 'rtt ms min/avg/max: %s/%s/%s\n' \
      "$(format_centiseconds "${rtt_min:-}")" \
      "$(format_centiseconds "$average")" \
      "$(format_centiseconds "${rtt_max:-}")"
    printf 'rtt buckets under 1/5/10/25/50/100/250/above: %s/%s/%s/%s/%s/%s/%s/%s\n' \
      "$bucket_1" "$bucket_5" "$bucket_10" "$bucket_25" \
      "$bucket_50" "$bucket_100" "$bucket_250" "$bucket_above"
    printf 'events: %s\n' "$events"
    if [ "$events" -gt 0 ]; then
      sed -n 's/^== event /  event /p' "$directory/events.log" 2>/dev/null || true
    fi
    printf '\n'
    printf 'rx packets: %s -> %s\n' "$rx_packets_start" "$(read_counter rx_packets)"
    printf 'tx packets: %s -> %s\n' "$tx_packets_start" "$(read_counter tx_packets)"
    printf 'rx errors: %s -> %s\n' "$rx_errors_start" "$(read_counter rx_errors)"
    printf 'rx dropped: %s -> %s\n' "$rx_dropped_start" "$(read_counter rx_dropped)"
    printf 'tx errors: %s -> %s\n' "$tx_errors_start" "$(read_counter tx_errors)"
    printf 'tx dropped: %s -> %s\n' "$tx_dropped_start" "$(read_counter tx_dropped)"
    printf 'collisions: %s -> %s\n' "$collisions_start" "$(read_counter collisions)"
    printf 'tcp retransmits: %s -> %s\n' "$retrans_start" "$(retrans_count)"
  } >"$summary.tmp"
  mv "$summary.tmp" "$summary"
}

finish() {
  local status=$?
  stopping=1
  stop_capture
  write_summary || true
  logger -t network-link-recorder "run $runid stopped: $probes probes, $probes_lost lost, $events events; summary $summary"
  return "$status"
}

main() {
  parse_args "$@"

  [ -n "$interface" ] || interface=$(detect_interface_for_target)
  [ -n "$interface" ] || interface=$(detect_interface)
  [ -n "$interface" ] || die "no default route found; pass --interface"
  [ -n "$target" ] || target=$(detect_target)
  [ -n "$target" ] || die "no default route on $interface; pass --target"

  mkdir -p "$logdir/events" "$ringdir"
  prune_old_runs

  runid=$(stamp)
  logfile="$logdir/probe-$runid.log"
  summary="$logdir/summary-$runid.txt"
  started=$(iso)

  probes=0
  probes_ok=0
  probes_lost=0
  rtt_sum=0
  rtt_min=
  rtt_max=
  events=0
  consecutive_losses=0
  bucket_1=0
  bucket_5=0
  bucket_10=0
  bucket_25=0
  bucket_50=0
  bucket_100=0
  bucket_250=0
  bucket_above=0

  rx_packets_start=$(read_counter rx_packets)
  rx_errors_start=$(read_counter rx_errors)
  rx_dropped_start=$(read_counter rx_dropped)
  tx_packets_start=$(read_counter tx_packets)
  tx_errors_start=$(read_counter tx_errors)
  tx_dropped_start=$(read_counter tx_dropped)
  collisions_start=$(read_counter collisions)
  retrans_start=$(retrans_count)

  trap 'stopping=1' TERM INT HUP
  trap 'manual=1' USR1
  trap finish EXIT

  {
    printf '%s start target=%s interface=%s duration=%s interval=%s burst=%s\n' \
      "$started" "$target" "$interface" "$duration" "$interval" "$burst"
  } >>"$logfile"

  write_context
  start_capture

  local end
  local window_start
  local window_probes=0
  local window_lost=0
  local next_burst
  local value
  local centiseconds
  local summary_ticks=0

  end=$(( $(now) + duration * 60 ))
  window_start=$(now)
  next_burst=$(( $(now) + burst * 60 ))

  write_summary

  while [ "$(now)" -lt "$end" ] && [ "$stopping" -eq 0 ]; do
    value=$(probe)
    probes=$((probes + 1))
    window_probes=$((window_probes + 1))

    if [ -z "$value" ]; then
      probes_lost=$((probes_lost + 1))
      window_lost=$((window_lost + 1))
      consecutive_losses=$((consecutive_losses + 1))
      if [ "$consecutive_losses" -ge 2 ]; then
        capture_event probe
        events=$((events + 1))
        consecutive_losses=0
      fi
    else
      consecutive_losses=0
      probes_ok=$((probes_ok + 1))
      centiseconds=$(to_centiseconds "$value")
      rtt_sum=$((rtt_sum + centiseconds))
      if [ -z "$rtt_min" ] || [ "$centiseconds" -lt "$rtt_min" ]; then
        rtt_min=$centiseconds
      fi
      if [ -z "$rtt_max" ] || [ "$centiseconds" -gt "$rtt_max" ]; then
        rtt_max=$centiseconds
      fi
      if [ "$centiseconds" -lt 100 ]; then
        bucket_1=$((bucket_1 + 1))
      elif [ "$centiseconds" -lt 500 ]; then
        bucket_5=$((bucket_5 + 1))
      elif [ "$centiseconds" -lt 1000 ]; then
        bucket_10=$((bucket_10 + 1))
      elif [ "$centiseconds" -lt 2500 ]; then
        bucket_25=$((bucket_25 + 1))
      elif [ "$centiseconds" -lt 5000 ]; then
        bucket_50=$((bucket_50 + 1))
      elif [ "$centiseconds" -lt 10000 ]; then
        bucket_100=$((bucket_100 + 1))
      elif [ "$centiseconds" -lt 25000 ]; then
        bucket_250=$((bucket_250 + 1))
      else
        bucket_above=$((bucket_above + 1))
      fi
    fi

    if [ "$manual" -eq 1 ]; then
      manual=0
      capture_event manual
      events=$((events + 1))
    fi

    if [ $(( $(now) - window_start )) -ge 300 ]; then
      printf '%s window=%s probes=%s lost=%s retrans=%s counters=%s\n' \
        "$(iso)" "$(( $(now) - window_start ))" "$window_probes" "$window_lost" \
        "$(retrans_count)" "$(counters_line)" >>"$logfile"
      window_start=$(now)
      window_probes=0
      window_lost=0
      write_summary
      summary_ticks=0
    elif [ "$summary_ticks" -ge 10 ]; then
      write_summary
      summary_ticks=0
    fi
    summary_ticks=$((summary_ticks + 1))

    if [ "$burst" -gt 0 ] && [ "$(now)" -ge "$next_burst" ]; then
      run_burst
      next_burst=$(( $(now) + burst * 60 ))
    fi

    sleep "$interval"
  done
}

main "$@"
