#!/usr/bin/env bash
set -eu

export LC_ALL=C

logdir=$HOME/network-link-recorder
duration=480
interval=1
burst=15
ssh_user=
ssh_interval=5
ssh_deadline=20
ping_command=${NETWORK_LINK_RECORDER_PING:-/sbin/ping}
route_command=${NETWORK_LINK_RECORDER_ROUTE:-/usr/sbin/route}
ssh_command=${NETWORK_LINK_RECORDER_SSH:-/usr/bin/ssh}
arp_command=${NETWORK_LINK_RECORDER_ARP:-/usr/sbin/arp}
netstat_command=${NETWORK_LINK_RECORDER_NETSTAT:-/usr/sbin/netstat}
ifconfig_command=${NETWORK_LINK_RECORDER_IFCONFIG:-/sbin/ifconfig}
stopping=0
manual=0
targets=()
workers=()
runid=
started=
events_file=
done_file=
worker_address=
worker_summary_file=
worker_summary_written=0
worker_samples=0
worker_losses=0
worker_consecutive=0
worker_rtt_sum=0
worker_rtt_min=
worker_rtt_max=
worker_ssh_attempts=0
worker_ssh_failures=0
worker_ssh_consecutive=0
worker_ssh_slowest=0

usage() {
  cat <<'EOF'
Usage: network-link-recorder-client [options]

Probe each path from this machine to the board, and optionally open a short SSH
session to each target, recording what this machine was doing when either fails.
Writes log files; installs nothing and needs no privileges. Run it in a
terminal and leave it, under caffeinate if the machine may sleep.

  --target ADDRESS      Address to probe. Repeat once per path. Required.
  --duration MINUTES    Length of the run. Defaults to 480.
  --interval SECONDS    Seconds between pings. Defaults to 1.
  --burst MINUTES       Minutes between bursts of one hundred pings of 1472
                        bytes per target. Zero disables them. Defaults to 15.
  --ssh-user USER       Run an SSH command as USER on each target every
                        --ssh-interval minutes. Disabled when unset.
  --ssh-interval MINUTES
                        Minutes between SSH probes. Defaults to 5.
  --logdir DIRECTORY    Directory for logs and summaries. Defaults to
                        ~/network-link-recorder.
  -h, --help            Show this message.

Each target writes probe-RUN-ADDRESS.log, summary-RUN-ADDRESS.txt and, when
pings or SSH fail, events-RUN-ADDRESS.log. summary-RUN.txt combines them.
SIGHUP records an event for every target; Ctrl-C stops and writes final
summaries.
EOF
}

die() {
  printf 'network-link-recorder-client: %s\n' "$*" >&2
  exit 1
}

require_bash_4() {
  if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    die "bash 4 or newer is required; macOS ships 3.2, so use the development shell"
  fi
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --target)
        targets+=("${2?--target needs an address}")
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
      --ssh-user)
        ssh_user=${2:?--ssh-user needs a user}
        shift 2
        ;;
      --ssh-interval)
        ssh_interval=${2:?--ssh-interval needs minutes}
        shift 2
        ;;
      --logdir)
        logdir=${2:?--logdir needs a directory}
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

  [ "${#targets[@]}" -gt 0 ] || die "pass at least one --target"
  case "$duration" in
    '' | *[!0-9]*) die "--duration takes whole minutes" ;;
  esac
  case "$interval" in
    '' | *[!0-9]*) die "--interval takes whole seconds" ;;
  esac
  case "$burst" in
    '' | *[!0-9]*) die "--burst takes whole minutes" ;;
  esac
  case "$ssh_interval" in
    '' | *[!0-9]*) die "--ssh-interval takes whole minutes" ;;
  esac
  [ "$interval" -gt 0 ] || die "--interval must be at least 1"
  [ "$duration" -gt 0 ] || die "--duration must be at least 1"
  if [ -n "$ssh_user" ] && [ "$ssh_interval" -eq 0 ]; then
    die "--ssh-interval must be at least 1"
  fi
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

detect_interface() {
  { "$route_command" -n get "$1" 2>/dev/null || true; } \
    | sed -n 's/^[[:space:]]*interface: //p' \
    | head -n 1
}

probe() {
  local output
  output=$({ "$ping_command" -n -q -c 1 -t 1 "$1" 2>&1 || true; })
  printf '%s' "$output" | sed -n 's/^round-trip [^=]*= \([0-9.]\{1,\}\).*/\1/p'
}

received_count() {
  local output=$1
  local received
  received=$(printf '%s' "$output" | sed -n 's/^[0-9]\{1,\} packets transmitted, \([0-9]\{1,\}\) packets received.*/\1/p')
  if [ -z "$received" ]; then
    received=$(printf '%s' "$output" | sed -n 's/^[0-9]\{1,\} packets transmitted, \([0-9]\{1,\}\) received.*/\1/p')
  fi
  printf '%s' "$received"
}

snapshot() {
  local file=$1
  local reason=$2
  local address=$3
  local interface
  interface=$(detect_interface "$address")
  {
    printf '== event %s reason=%s target=%s interface=%s\n' "$(iso)" "$reason" "$address" "${interface:-unknown}"
    printf -- '-- arp\n'
    "$arp_command" -an 2>/dev/null || true
    printf -- '-- routes\n'
    "$netstat_command" -rn -f inet 2>/dev/null || true
    printf -- '-- interface\n'
    [ -n "$interface" ] && "$ifconfig_command" "$interface" 2>/dev/null || true
    printf -- '-- tcp counters\n'
    "$netstat_command" -s -p tcp 2>/dev/null || true
    printf -- '-- ping\n'
    "$ping_command" -n -c 5 "$address" 2>&1 || true
    printf '\n'
  } >>"$file"
  printf '%s event reason=%s target=%s\n' "$(iso)" "$reason" "$address"
}

run_burst() {
  local address=$1
  local logfile=$2
  local output
  local transmitted=
  local received=
  local loss=
  local rtt=
  output=$({ "$ping_command" -n -q -c 100 -s 1472 -i 0.2 -t 30 "$address" 2>&1 || true; })
  transmitted=$(printf '%s' "$output" | sed -n 's/^\([0-9]\{1,\}\) packets transmitted.*/\1/p')
  received=$(received_count "$output")
  loss=$(printf '%s' "$output" | sed -n 's/.*, \([0-9.]\{1,\}\)% packet loss.*/\1/p')
  rtt=$(printf '%s' "$output" | sed -n 's/^round-trip [^=]*= \(.*\)/\1/p')
  printf '%s burst transmitted=%s received=%s loss=%s rtt=%s\n' \
    "$(iso)" "${transmitted:-unknown}" "${received:-unknown}" "${loss:-unknown}" "${rtt:-none}" >>"$logfile"
  if [ -n "$transmitted" ] && [ "$transmitted" != "${received:-}" ]; then
    {
      printf '%s burst output\n' "$(iso)"
      printf '%s\n' "$output"
    } >>"$logfile"
    snapshot "$events_file" burst "$address"
  fi
}

run_with_deadline() {
  local deadline=$1
  shift
  local pid
  local waited=0
  local status=0

  "$@" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$deadline" ]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid" || status=$?
  return "$status"
}

ssh_probe() {
  local address=$1
  local logfile=$2
  local start
  local status=0
  local output=
  local seconds

  start=$(now)
  output=$(run_with_deadline "$ssh_deadline" \
    "$ssh_command" \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    -o ServerAliveInterval=5 \
    -o ServerAliveCountMax=2 \
    -o StrictHostKeyChecking=accept-new \
    "$ssh_user@$address" true 2>&1) || status=$?
  seconds=$(( $(now) - start ))
  worker_ssh_attempts=$((worker_ssh_attempts + 1))
  if [ "$seconds" -gt "$worker_ssh_slowest" ]; then
    worker_ssh_slowest=$seconds
  fi

  if [ "$status" -eq 0 ]; then
    worker_ssh_consecutive=0
    printf '%s ssh target=%s status=0 seconds=%s\n' "$(iso)" "$address" "$seconds" >>"$logfile"
    return 0
  fi

  worker_ssh_failures=$((worker_ssh_failures + 1))
  printf '%s ssh target=%s status=%s seconds=%s error=%s\n' \
    "$(iso)" "$address" "$status" "$seconds" \
    "$(printf '%s' "$output" | tr '\n' ' ' | cut -c1-200)" >>"$logfile"
  worker_ssh_consecutive=$((worker_ssh_consecutive + 1))
  if [ "$worker_ssh_consecutive" -eq 1 ]; then
    snapshot "$events_file" ssh "$address"
  fi
}

worker_summary() {
  {
    printf 'network-link-recorder-client summary\n'
    printf 'run: %s\n' "$runid"
    printf 'target: %s\n' "$worker_address"
    printf 'started: %s\n' "$started"
    printf 'updated: %s\n' "$(iso)"
    printf 'duration minutes: %s\n' "$duration"
    printf 'probe interval seconds: %s\n' "$interval"
    printf 'burst period minutes: %s\n' "$burst"
    printf 'ssh user: %s\n' "${ssh_user:-none}"
    printf 'ssh interval minutes: %s\n' "$ssh_interval"
    printf '\n'
    printf 'probes: %s\n' "$worker_samples"
    printf 'lost: %s\n' "$worker_losses"
    printf 'rtt ms min/avg/max: %s/%s/%s\n' \
      "$(format_centiseconds "${worker_rtt_min:-}")" \
      "$(format_centiseconds "$((worker_samples > worker_losses ? worker_rtt_sum / (worker_samples - worker_losses) : 0))")" \
      "$(format_centiseconds "${worker_rtt_max:-}")"
    printf 'ssh attempts: %s\n' "$worker_ssh_attempts"
    printf 'ssh failures: %s\n' "$worker_ssh_failures"
    printf 'ssh slowest seconds: %s\n' "$worker_ssh_slowest"
  } >"$worker_summary_file.tmp"
  mv "$worker_summary_file.tmp" "$worker_summary_file"
}

worker_finish() {
  if [ "$worker_summary_written" -eq 0 ]; then
    worker_summary_written=1
    worker_summary
    : >"$done_file"
    write_combined_summary
  fi
}

worker() {
  local address=$1
  local logfile=$2
  local summary=$3
  local events=$4
  local done=$5

  worker_address=$address
  worker_summary_file=$summary
  worker_summary_written=0
  worker_samples=0
  worker_losses=0
  worker_consecutive=0
  worker_rtt_sum=0
  worker_rtt_min=
  worker_rtt_max=
  worker_ssh_attempts=0
  worker_ssh_failures=0
  worker_ssh_consecutive=0
  worker_ssh_slowest=0
  events_file=$events
  done_file=$done

  local value=
  local centiseconds=
  local end=
  local window_start=
  local window_samples=0
  local window_losses=0
  local next_burst=
  local next_ssh=
  local ticks=0

  trap 'stopping=1; worker_finish' TERM INT
  trap 'worker_finish' EXIT

  end=$(( $(now) + duration * 60 ))
  window_start=$(now)
  next_burst=$(( $(now) + burst * 60 ))
  next_ssh=$(( $(now) + ssh_interval * 60 ))

  printf '%s start target=%s interface=%s duration=%s interval=%s burst=%s ssh=%s\n' \
    "$(iso)" "$address" "$(detect_interface "$address")" "$duration" "$interval" "$burst" "${ssh_user:-none}" >>"$logfile"

  while [ "$(now)" -lt "$end" ] && [ "$stopping" -eq 0 ]; do
    value=$(probe "$address")
    worker_samples=$((worker_samples + 1))
    window_samples=$((window_samples + 1))

    if [ -z "$value" ]; then
      worker_losses=$((worker_losses + 1))
      window_losses=$((window_losses + 1))
      worker_consecutive=$((worker_consecutive + 1))
      if [ "$worker_consecutive" -ge 2 ]; then
        snapshot "$events_file" probe "$address"
        worker_consecutive=0
      fi
    else
      worker_consecutive=0
      centiseconds=$(to_centiseconds "$value")
      worker_rtt_sum=$((worker_rtt_sum + centiseconds))
      if [ -z "$worker_rtt_min" ] || [ "$centiseconds" -lt "$worker_rtt_min" ]; then
        worker_rtt_min=$centiseconds
      fi
      if [ -z "$worker_rtt_max" ] || [ "$centiseconds" -gt "$worker_rtt_max" ]; then
        worker_rtt_max=$centiseconds
      fi
    fi

    ticks=$((ticks + 1))
    if [ $(( $(now) - window_start )) -ge 300 ]; then
      printf '%s window=%s probes=%s lost=%s ssh_failures=%s\n' \
        "$(iso)" "$(( $(now) - window_start ))" "$window_samples" "$window_losses" "$worker_ssh_failures"
      printf '%s window=%s probes=%s lost=%s ssh_failures=%s\n' \
        "$(iso)" "$(( $(now) - window_start ))" "$window_samples" "$window_losses" "$worker_ssh_failures" >>"$logfile"
      window_start=$(now)
      window_samples=0
      window_losses=0
      worker_summary
    fi

    if [ "$burst" -gt 0 ] && [ "$(now)" -ge "$next_burst" ]; then
      run_burst "$address" "$logfile"
      next_burst=$(( $(now) + burst * 60 ))
    fi

    if [ -n "$ssh_user" ] && [ "$(now)" -ge "$next_ssh" ]; then
      ssh_probe "$address" "$logfile"
      next_ssh=$(( $(now) + ssh_interval * 60 ))
    fi

    sleep "$interval"
  done

  worker_finish
}

workers_missing() {
  local address
  local missing=0
  for address in "${targets[@]}"; do
    [ -f "$logdir/.done-$runid-$address" ] || missing=$((missing + 1))
  done
  printf '%s' "$missing"
}

workers_running() {
  local pid
  local running=0
  for pid in "${workers[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      running=$((running + 1))
    fi
  done
  printf '%s' "$running"
}

write_combined_summary() {
  local address
  local temporary="$logdir/.combined-$BASHPID.tmp"
  {
    printf 'network-link-recorder-client combined summary\n'
    printf 'run: %s\n' "$runid"
    printf 'started: %s\n' "$started"
    printf 'updated: %s\n' "$(iso)"
    printf 'workers outstanding: %s\n' "$(workers_missing)"
    printf '\n'
    for address in "${targets[@]}"; do
      if [ -f "$logdir/summary-$runid-$address.txt" ]; then
        cat "$logdir/summary-$runid-$address.txt"
      else
        printf 'target %s: no summary written\n' "$address"
      fi
      printf '\n'
    done
  } >"$temporary"
  mv "$temporary" "$logdir/summary-$runid.txt"
}

main() {
  parse_args "$@"
  require_bash_4

  mkdir -p "$logdir"
  runid=$(stamp)
  started=$(iso)

  printf 'network-link-recorder-client run %s\n' "$runid"
  printf 'targets: %s\n' "${targets[*]}"
  if [ -n "$ssh_user" ]; then
    printf 'ssh probes: %s every %s minutes\n' "$ssh_user" "$ssh_interval"
  fi
  printf 'logs: %s\n' "$logdir"

  trap 'stopping=1' TERM INT
  trap 'manual=1' HUP
  trap 'write_combined_summary' EXIT

  local address
  for address in "${targets[@]}"; do
    rm -f "$logdir/.done-$runid-$address"
    worker "$address" \
      "$logdir/probe-$runid-$address.log" \
      "$logdir/summary-$runid-$address.txt" \
      "$logdir/events-$runid-$address.log" \
      "$logdir/.done-$runid-$address" &
    workers+=("$!")
  done

  local pid
  while :; do
    if [ "$stopping" -eq 1 ]; then
      for pid in "${workers[@]}"; do
        kill "$pid" 2>/dev/null || true
      done
    fi
    if [ "$manual" -eq 1 ]; then
      manual=0
      for address in "${targets[@]}"; do
        snapshot "$logdir/events-$runid-manual.log" manual "$address"
      done
    fi
    write_combined_summary
    [ "$(workers_running)" -eq 0 ] && break
    sleep 5
  done

  local status=0
  local worker_status
  for pid in "${workers[@]}"; do
    worker_status=0
    wait "$pid" || worker_status=$?
    case "$worker_status" in
      0) ;;
      130 | 143) printf 'network-link-recorder-client: worker %s stopped\n' "$pid" ;;
      *)
        printf 'network-link-recorder-client: worker %s failed with status %s\n' "$pid" "$worker_status" >&2
        status=1
        ;;
    esac
  done

  write_combined_summary
  printf 'summary: %s\n' "$logdir/summary-$runid.txt"
  return "$status"
}

main "$@"
