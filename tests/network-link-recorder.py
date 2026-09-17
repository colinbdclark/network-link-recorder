import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


SOURCE = Path(sys.argv.pop(1)).read_text()
LIBRARY, ENTRYPOINT = SOURCE.rsplit('\nmain "$@"', 1)
assert not ENTRYPOINT.strip()

MOCKS = r'''
ip() {
  case "$*" in
    *"route get"*) printf '%s\n' "$ROUTE_GET" ;;
    *"route show default"*) cat "$ROUTES_FILE" ;;
    *) : ;;
  esac
}

date() {
  case "$*" in
    *"+%s")
      clock=$(cat "$CLOCK_FILE")
      clock=$((clock + STEP))
      printf '%s' "$clock" > "$CLOCK_FILE"
      printf '%s' "$clock"
      ;;
    *"%Y%m%dT%H%M%SZ") printf '20260101T000000Z' ;;
    *) printf '2026-01-01T00:00:00Z' ;;
  esac
}

sleep() {
  if [ -n "${SLEEP_DELAY:-}" ]; then
    command sleep "$SLEEP_DELAY"
  fi
}

ping() {
  printf '%s\n' "$*" >> "$PING_LOG"
  case "$*" in
    *"-c 1000"*)
      cat "$BURST_OUTPUT"
      return 0
      ;;
  esac
  index=$(cat "$INDEX_FILE")
  printf '%s' "$((index + 1))" > "$INDEX_FILE"
  reply=$(sed -n "${index}p" "$PING_FILE")
  [ -n "$reply" ] || reply=$DEFAULT_REPLY
  case "$reply" in
    loss) return 1 ;;
    *) printf 'rtt min/avg/max/mdev = %s/%s/%s/0.000 ms\n' "$reply" "$reply" "$reply" ;;
  esac
}

tcpdump() {
  printf 'tcpdump %s\n' "$*" >> "$TCPDUMP_LOG"
  case "$*" in
    *"-w"*)
      if [ "${CAPTURE_FAILS:-0}" = 1 ]; then
        printf 'tcpdump: test failure\n' >&2
        return 1
      fi
      while [ "$#" -gt 0 ]; do
        if [ "$1" = "-w" ]; then
          printf 'x' > "$2"0
        fi
        shift
      done
      command sleep 600
      ;;
    *) : ;;
  esac
}

ethtool() { :; }
nstat() { :; }
logger() { :; }
'''

OK_REPLY = "1.500"
SLOW_REPLY = "7.250"
LOSS = "loss"
ROUTE_END0 = "default via 192.168.1.1 dev end0 proto dhcp src 192.168.1.9 metric 100"
ROUTE_WLAN0 = "default via 192.168.1.254 dev wlan0 proto dhcp src 192.168.1.16 metric 600"
BURST_CLEAN = (
    "--- 192.168.1.1 ping statistics ---\n"
    "1000 packets transmitted, 1000 received, 0% packet loss, time 20000ms\n"
    "rtt min/avg/max/mdev = 0.900/1.400/9.000/0.300 ms\n"
)
BURST_LOSSY = (
    "--- 192.168.1.1 ping statistics ---\n"
    "1000 packets transmitted, 999 received, 0.1% packet loss, time 20000ms\n"
    "rtt min/avg/max/mdev = 0.900/1.400/91.000/3.300 ms\n"
)


class RecorderTests(unittest.TestCase):
    def run_script(
        self,
        *,
        pings=(),
        default=OK_REPLY,
        arguments=(),
        routes=(ROUTE_END0,),
        route_get="192.168.1.77 dev eth9 src 192.168.1.9 uid 0",
        burst_output=BURST_CLEAN,
        capture_fails=False,
        sleep_delay=None,
        interrupt=None,
        prepare=None,
    ):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            routes_file = directory / "routes"
            routes_file.write_text("".join(f"{route}\n" for route in routes))
            ping_file = directory / "pings"
            ping_file.write_text("".join(f"{reply}\n" for reply in pings))
            ping_log = directory / "ping-args"
            ping_log.write_text("")
            tcpdump_log = directory / "tcpdump-args"
            tcpdump_log.write_text("")
            index_file = directory / "index"
            index_file.write_text("1\n")
            clock_file = directory / "clock"
            clock_file.write_text("0\n")
            burst_file = directory / "burst"
            burst_file.write_text(burst_output)
            logdir = directory / "log"
            ringdir = directory / "ring"
            if prepare is not None:
                prepare(logdir)
            process = subprocess.Popen(
                [
                    "bash",
                    "-c",
                    LIBRARY + "\n" + MOCKS + "\nmain \"$@\"",
                    "network-link-recorder",
                    *arguments,
                    "--logdir",
                    str(logdir),
                    "--ringdir",
                    str(ringdir),
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
                env=dict(
                    os.environ,
                    ROUTES_FILE=str(routes_file),
                    PING_FILE=str(ping_file),
                    PING_LOG=str(ping_log),
                    TCPDUMP_LOG=str(tcpdump_log),
                    INDEX_FILE=str(index_file),
                    CLOCK_FILE=str(clock_file),
                    BURST_OUTPUT=str(burst_file),
                    DEFAULT_REPLY=default,
                    ROUTE_GET=route_get,
                    CAPTURE_FAILS="1" if capture_fails else "0",
                    STEP="1",
                    SLEEP_DELAY=sleep_delay or "",
                ),
            )
            if interrupt:
                self.wait_for_log(logdir)
                if interrupt == "group":
                    os.killpg(os.getpgid(process.pid), signal.SIGTERM)
                elif interrupt == "usr1":
                    process.send_signal(signal.SIGUSR1)
                    self.wait_for_events(logdir)
                    process.terminate()
                else:
                    process.terminate()
            stdout, stderr = process.communicate(timeout=60)
            result = subprocess.CompletedProcess(process.args, process.returncode, stdout, stderr)
            return result, self.collect(logdir, ping_log, tcpdump_log)

    def wait_for_log(self, logdir, timeout=15):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if logdir.exists() and list(logdir.glob("probe-*.log")):
                return
            time.sleep(0.02)
        self.fail("the run did not write a probe log")

    def wait_for_events(self, logdir, timeout=15):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if logdir.exists() and list(logdir.glob("events/*/events.log")):
                return
            time.sleep(0.02)
        self.fail("no event was recorded after the signal")

    def collect(self, logdir, ping_log, tcpdump_log):
        summaries = sorted(logdir.glob("summary-*.txt")) if logdir.exists() else []
        probes = sorted(logdir.glob("probe-*.log")) if logdir.exists() else []
        events = sorted(logdir.glob("events/*/events.log")) if logdir.exists() else []
        files = sorted(str(path.relative_to(logdir)) for path in logdir.rglob("*")) if logdir.exists() else []
        return {
            "summary": summaries[-1].read_text() if summaries else "",
            "probe": probes[-1].read_text() if probes else "",
            "events": [path.read_text() for path in events],
            "files": files,
            "ping_args": ping_log.read_text().splitlines(),
            "tcpdump_args": tcpdump_log.read_text().splitlines(),
        }

    def test_clean_run_records_no_loss(self):
        result, state = self.run_script(default=OK_REPLY, arguments=["--duration", "3", "--burst", "0"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("probes: 0\n", state["summary"])
        self.assertIn("lost: 0\n", state["summary"])
        self.assertIn("events: 0\n", state["summary"])
        self.assertIn("rtt ms min/avg/max: 1.50/1.50/1.50", state["summary"])
        self.assertEqual(state["events"], [])

    def test_every_probe_is_bound_to_the_interface(self):
        result, state = self.run_script(
            default=OK_REPLY,
            arguments=["--duration", "3", "--burst", "1", "--interface", "end0"],
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(state["ping_args"])
        for args in state["ping_args"]:
            self.assertIn("-I end0", args, args)
        bursts = [args for args in state["ping_args"] if "-c 1000" in args]
        self.assertTrue(bursts, state["ping_args"])

    def test_interface_can_be_detected_from_the_target(self):
        result, state = self.run_script(
            default=OK_REPLY,
            arguments=["--duration", "3", "--burst", "0", "--target", "192.168.1.77"],
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("target=192.168.1.77", state["probe"])
        self.assertIn("interface=eth9", state["probe"])

    def test_target_comes_from_the_monitored_interface(self):
        result, state = self.run_script(
            default=OK_REPLY,
            arguments=["--duration", "3", "--burst", "0", "--interface", "end0"],
            routes=(ROUTE_WLAN0, ROUTE_END0),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("target=192.168.1.1", state["probe"])
        self.assertIn("interface=end0", state["probe"])

    def test_capture_avoids_promiscuous_mode_and_reports_copies(self):
        result, state = self.run_script(default=LOSS, arguments=["--duration", "3", "--burst", "0"])
        self.assertEqual(result.returncode, 0, result.stderr)
        captures = [args for args in state["tcpdump_args"] if "-w" in args]
        self.assertTrue(captures, state["tcpdump_args"])
        self.assertIn("-p ", captures[0] + " ", captures[0])
        self.assertTrue(state["events"])
        self.assertIn("copy failures", state["events"][0])

    def test_losses_produce_events_with_a_capture(self):
        result, state = self.run_script(default=LOSS, arguments=["--duration", "3", "--burst", "0"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("lost: 0\n", state["summary"])
        self.assertNotIn("events: 0\n", state["summary"])
        self.assertTrue(state["events"])
        self.assertIn("== event ", state["events"][0])
        self.assertIn("trigger=probe", state["events"][0])
        self.assertIn("capture: 1 files", state["events"][0])
        self.assertIn("event 2026", state["summary"])

    def test_capture_failure_is_reported_separately(self):
        result, state = self.run_script(
            default=LOSS,
            arguments=["--duration", "3", "--burst", "0"],
            capture_fails=True,
            sleep_delay="0.05",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("capture-failed", state["probe"])
        self.assertTrue(state["events"])
        self.assertIn("capture: unavailable", state["events"][0])
        self.assertNotIn("capture: 0 files", state["events"][0])

    def test_fractional_burst_loss_is_parsed_and_captured(self):
        result, state = self.run_script(
            default=OK_REPLY,
            arguments=["--duration", "3", "--burst", "1", "--interface", "end0"],
            burst_output=BURST_LOSSY,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        bursts = [line for line in state["probe"].splitlines() if "burst transmitted=" in line]
        self.assertTrue(bursts, state["probe"])
        self.assertIn("transmitted=1000", bursts[0])
        self.assertIn("received=999", bursts[0])
        self.assertIn("loss=0.1", bursts[0])
        self.assertIn("burst output", state["probe"])
        self.assertTrue(
            [event for event in state["events"] if "trigger=burst" in event],
            state["events"],
        )

    def test_slow_probes_land_in_the_expected_buckets(self):
        result, state = self.run_script(pings=[OK_REPLY, SLOW_REPLY], arguments=["--duration", "3", "--burst", "0"])
        self.assertEqual(result.returncode, 0, result.stderr)
        buckets = [line for line in state["summary"].splitlines() if line.startswith("rtt buckets")]
        self.assertEqual(len(buckets), 1)
        counts = buckets[0].split(": ")[1].split("/")
        self.assertEqual(counts[0], "0", "nothing under 1 ms")
        self.assertGreaterEqual(int(counts[1]), 1, "1.5 ms lands under 5 ms")
        self.assertEqual(counts[2], "1", "only the 7.25 ms probe lands under 10 ms")
        self.assertEqual(counts[7], "0", "nothing above 250 ms")

    def test_context_is_recorded(self):
        result, state = self.run_script(default=OK_REPLY, arguments=["--duration", "3", "--burst", "0"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("context generation=", state["probe"])
        self.assertIn("context boot=", state["probe"])
        self.assertIn("capture-started", state["probe"])
        self.assertIn("generation: ", state["summary"])

    def test_window_lines_include_retransmits(self):
        result, state = self.run_script(default=OK_REPLY, arguments=["--duration", "20", "--burst", "0"])
        self.assertEqual(result.returncode, 0, result.stderr)
        windows = [line for line in state["probe"].splitlines() if "window=" in line]
        self.assertTrue(windows, state["probe"])
        self.assertIn("retrans=", windows[0])

    def test_target_and_interface_come_from_the_default_route(self):
        result, state = self.run_script(default=OK_REPLY, arguments=["--duration", "3", "--burst", "0"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("target=192.168.1.1", state["probe"])
        self.assertIn("interface=end0", state["probe"])
        self.assertIn("target: 192.168.1.1\n", state["summary"])
        self.assertIn("interface: end0\n", state["summary"])

    def test_empty_target_and_interface_fall_back_to_the_default_route(self):
        result, state = self.run_script(
            default=OK_REPLY,
            arguments=["--duration", "3", "--burst", "0", "--target", "", "--interface", ""],
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("target=192.168.1.1", state["probe"])
        self.assertIn("interface=end0", state["probe"])

    def test_missing_route_is_rejected(self):
        result, state = self.run_script(default=OK_REPLY, arguments=["--duration", "3"], routes=())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no default route", result.stderr)
        self.assertEqual(state["summary"], "")

    def test_missing_route_for_the_named_interface_is_rejected(self):
        result, _ = self.run_script(
            default=OK_REPLY,
            arguments=["--duration", "3", "--interface", "end0"],
            routes=(ROUTE_WLAN0,),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no default route on end0", result.stderr)

    def test_rejects_non_numeric_duration(self):
        result, _ = self.run_script(default=OK_REPLY, arguments=["--duration", "8h"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("whole minutes", result.stderr)

    def test_interrupt_writes_the_summary(self):
        result, state = self.run_script(
            default=OK_REPLY,
            arguments=["--duration", "600", "--burst", "0"],
            interrupt="process",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("network-link-recorder summary", state["summary"])
        self.assertIn("lost: 0\n", state["summary"])

    def test_signal_records_an_event_immediately(self):
        result, state = self.run_script(
            default=OK_REPLY,
            arguments=["--duration", "600", "--burst", "0"],
            interrupt="usr1",
        )
        self.assertTrue(state["events"], "no event recorded")
        self.assertIn("trigger=manual", state["events"][0])

    def test_group_termination_writes_the_summary(self):
        result, state = self.run_script(
            default=OK_REPLY,
            arguments=["--duration", "600", "--burst", "0"],
            sleep_delay="0.1",
            interrupt="group",
        )
        self.assertIn("network-link-recorder summary", state["summary"])
        self.assertIn("interface: end0\n", state["summary"])

    def test_old_runs_are_pruned(self):
        def prepare(logdir):
            logdir.mkdir(parents=True)
            events = logdir / "events" / "20250101T000000Z"
            events.mkdir(parents=True)
            old = time.time() - 30 * 86400
            for path in (
                logdir / "probe-20250101T000000Z.log",
                logdir / "summary-20250101T000000Z.txt",
                events / "events.log",
            ):
                path.write_text("old\n")
                os.utime(path, (old, old))
            os.utime(events, (old, old))

        result, state = self.run_script(
            default=OK_REPLY,
            arguments=["--duration", "3", "--burst", "0", "--keep", "7"],
            prepare=prepare,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("probe-20250101T000000Z.log", state["files"])
        self.assertNotIn("summary-20250101T000000Z.txt", state["files"])
        self.assertNotIn("events/20250101T000000Z/events.log", state["files"])

    def test_keep_zero_disables_pruning(self):
        def prepare(logdir):
            logdir.mkdir(parents=True)
            old = time.time() - 30 * 86400
            path = logdir / "probe-20250101T000000Z.log"
            path.write_text("old\n")
            os.utime(path, (old, old))

        result, state = self.run_script(
            default=OK_REPLY,
            arguments=["--duration", "3", "--burst", "0", "--keep", "0"],
            prepare=prepare,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("probe-20250101T000000Z.log", state["files"])


if __name__ == "__main__":
    unittest.main()
