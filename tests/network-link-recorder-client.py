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
ping() {
  local address=
  local arg
  for arg in "$@"; do
    case "$arg" in
      -*) ;;
      *) address=$arg ;;
    esac
  done
  printf 'ping %s\n' "$*" >> "$PING_LOG"
  case "$*" in
    *"-c 100"*)
      cat "$BURST_OUTPUT"
      return 0
      ;;
  esac
  local index
  index=$(cat "$INDEX_DIR/$address" 2>/dev/null || printf '1')
  printf '%s' "$((index + 1))" > "$INDEX_DIR/$address"
  local reply
  reply=$(sed -n "${index}p" "$PING_DIR/$address" 2>/dev/null || true)
  [ -n "$reply" ] || reply=$DEFAULT_REPLY
  case "$reply" in
    loss)
      printf '%s\n' '1 packets transmitted, 0 packets received, 100.0% packet loss'
      return 1
      ;;
    *)
      printf '%s\n' '1 packets transmitted, 1 packets received, 0.0% packet loss'
      printf 'round-trip min/avg/max/stddev = %s/%s/%s/0.000 ms\n' "$reply" "$reply" "$reply"
      ;;
  esac
}

ssh() {
  printf 'ssh %s\n' "$*" >> "$SSH_LOG"
  local address=
  local arg
  for arg in "$@"; do
    case "$arg" in
      *@*) address=${arg#*@} ;;
    esac
  done
  local reply
  reply=$(cat "$SSH_REPLY_DIR/$address" 2>/dev/null || printf 'ok')
  case "$reply" in
    fail*)
      printf '%s\n' 'ssh: connect to host port 22: Operation timed out' >&2
      return "${reply#fail}"
      ;;
    hang)
      while :; do :; done
      ;;
    *) : ;;
  esac
}

route() {
  case "$*" in
    *"get"*) printf '%s\n' '   interface: en7' ;;
    *) : ;;
  esac
}

date() {
  case "$*" in
    *"+%s")
      clock=$(cat "$CLOCK_FILE")
      clock=$((clock + 1))
      printf '%s' "$clock" > "$CLOCK_FILE"
      printf '%s' "$clock"
      ;;
    *"%Y%m%dT%H%M%SZ") printf '20260101T000000Z' ;;
    *) printf '2026-01-01T00:00:00Z' ;;
  esac
}

sleep() { command sleep 0.01; }
arp() { :; }
netstat() { :; }
ifconfig() { :; }
'''

OK_REPLY = "1.200"
ETHERNET = "192.168.1.9"
WIFI = "192.168.1.15"
BURST_CLEAN = (
    "--- 192.168.1.9 ping statistics ---\n"
    "100 packets transmitted, 100 packets received, 0.0% packet loss\n"
    "round-trip min/avg/max/stddev = 0.900/1.400/9.000/0.300 ms\n"
)
BURST_LOSSY = (
    "--- 192.168.1.9 ping statistics ---\n"
    "100 packets transmitted, 99 packets received, 1.0% packet loss\n"
    "round-trip min/avg/max/stddev = 0.900/1.400/91.000/3.300 ms\n"
)


class ClientTests(unittest.TestCase):
    def run_script(
        self,
        *,
        targets=(ETHERNET, WIFI),
        replies=None,
        default=OK_REPLY,
        arguments=(),
        burst_output=BURST_CLEAN,
        ssh_replies=None,
        interrupt=None,
    ):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            ping_dir = directory / "replies"
            index_dir = directory / "indexes"
            ssh_dir = directory / "ssh"
            ping_dir.mkdir()
            index_dir.mkdir()
            ssh_dir.mkdir()
            for address in targets:
                (ping_dir / address).write_text("".join(f"{reply}\n" for reply in (replies or {}).get(address, ())))
                (index_dir / address).write_text("1\n")
                (ssh_dir / address).write_text(((ssh_replies or {}).get(address, "ok")) + "\n")
            clock_file = directory / "clock"
            clock_file.write_text("0\n")
            ping_log = directory / "ping-args"
            ping_log.write_text("")
            ssh_log = directory / "ssh-args"
            ssh_log.write_text("")
            burst_file = directory / "burst"
            burst_file.write_text(burst_output)
            logdir = directory / "log"
            process = subprocess.Popen(
                [
                    "bash",
                    "-c",
                    LIBRARY + "\n" + MOCKS + "\nmain \"$@\"",
                    "network-link-recorder-client",
                    *[item for address in targets for item in ("--target", address)],
                    *arguments,
                    "--logdir",
                    str(logdir),
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
                env=dict(
                    os.environ,
                    NETWORK_LINK_RECORDER_PING="ping",
                    NETWORK_LINK_RECORDER_ROUTE="route",
                    NETWORK_LINK_RECORDER_SSH="ssh",
                    NETWORK_LINK_RECORDER_ARP="arp",
                    NETWORK_LINK_RECORDER_NETSTAT="netstat",
                    NETWORK_LINK_RECORDER_IFCONFIG="ifconfig",
                    PING_DIR=str(ping_dir),
                    INDEX_DIR=str(index_dir),
                    SSH_REPLY_DIR=str(ssh_dir),
                    PING_LOG=str(ping_log),
                    SSH_LOG=str(ssh_log),
                    CLOCK_FILE=str(clock_file),
                    BURST_OUTPUT=str(burst_file),
                    DEFAULT_REPLY=default,
                ),
            )
            if interrupt == "sighup":
                self.wait_for_logs(logdir, len(targets))
                process.send_signal(signal.SIGHUP)
                self.wait_for(logdir, "events-*-manual.log", "reason=manual")
                os.killpg(os.getpgid(process.pid), signal.SIGTERM)
            elif interrupt == "group":
                self.wait_for_logs(logdir, len(targets))
                os.killpg(os.getpgid(process.pid), signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=60)
            result = subprocess.CompletedProcess(process.args, process.returncode, stdout, stderr)
            return result, self.collect(logdir, ping_log, ssh_log)

    def wait_for_logs(self, logdir, count, timeout=15):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if logdir.exists() and len(list(logdir.glob("probe-*.log"))) >= count:
                return
            time.sleep(0.02)
        self.fail("the run did not write probe logs for every target")

    def wait_for(self, logdir, pattern, needle, timeout=15):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for path in sorted(logdir.glob(pattern)):
                if needle in path.read_text():
                    return
            time.sleep(0.02)
        self.fail(f"{needle} never appeared in {pattern}")

    def collect(self, logdir, ping_log, ssh_log):
        summaries = sorted(logdir.glob("summary-*-*.txt")) if logdir.exists() else []
        per_target = {}
        for path in summaries:
            key = path.name[len("summary-") : -len(".txt")].split("-", 1)[1]
            per_target[key] = path.read_text()
        combined = sorted(logdir.glob("summary-2026*.txt")) if logdir.exists() else []
        events = {}
        for path in sorted(logdir.glob("events-*.log")) if logdir.exists() else []:
            events[path.name] = path.read_text()
        probes = {}
        for path in sorted(logdir.glob("probe-*.log")) if logdir.exists() else []:
            probes[path.name.split("-")[-1].replace(".log", "")] = path.read_text()
        return {
            "combined": combined[-1].read_text() if combined else "",
            "targets": per_target,
            "events": events,
            "probes": probes,
            "ping_args": ping_log.read_text().splitlines(),
            "ssh_args": ssh_log.read_text().splitlines(),
        }

    def event_text(self, state):
        return "".join(state["events"].values())

    def burst_lines(self, state):
        return [
            line
            for text in state["probes"].values()
            for line in text.splitlines()
            if "burst transmitted=" in line
        ]

    def test_clean_run_records_each_target(self):
        result, state = self.run_script(arguments=["--duration", "3", "--burst", "0"])
        self.assertEqual(result.returncode, 0, result.stderr)
        for address in (ETHERNET, WIFI):
            self.assertIn(address, state["targets"])
            self.assertIn("lost: 0\n", state["targets"][address])
            self.assertIn("rtt ms min/avg/max: 1.20/1.20/1.20", state["targets"][address])
            self.assertIn("ssh failures: 0\n", state["targets"][address])
        self.assertIn("combined summary", state["combined"])
        self.assertIn(ETHERNET, state["combined"])
        self.assertEqual(state["events"], {})

    def test_interface_is_detected_per_target(self):
        result, state = self.run_script(arguments=["--duration", "3", "--burst", "0"])
        self.assertEqual(result.returncode, 0, result.stderr)
        for address in (ETHERNET, WIFI):
            self.assertIn(f"target={address} interface=en7", state["probes"][address])

    def test_probes_use_the_macos_timeout_flag(self):
        result, state = self.run_script(arguments=["--duration", "3", "--burst", "0"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(state["ping_args"])
        for args in state["ping_args"]:
            self.assertIn("-t 1", args, args)

    def test_losses_are_counted_per_target(self):
        result, state = self.run_script(
            arguments=["--duration", "3", "--burst", "0"],
            replies={WIFI: ("loss", "loss")},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("lost: 0\n", state["targets"][ETHERNET])
        self.assertNotIn("lost: 0\n", state["targets"][WIFI])
        self.assertIn("reason=probe", self.event_text(state))
        self.assertIn("-- tcp counters", self.event_text(state))

    def test_clean_burst_produces_no_event(self):
        result, state = self.run_script(
            arguments=["--duration", "3", "--burst", "1"],
            burst_output=BURST_CLEAN,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        bursts = self.burst_lines(state)
        self.assertTrue(bursts, state["probes"])
        self.assertIn("transmitted=100 received=100 loss=0.0", bursts[0])
        self.assertEqual(state["events"], {}, "a clean burst must not record an event")

    def test_burst_loss_is_recorded_and_snapshotted(self):
        result, state = self.run_script(
            arguments=["--duration", "3", "--burst", "1"],
            burst_output=BURST_LOSSY,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("burst", self.event_text(state))
        self.assertIn("reason=burst", self.event_text(state))

    def test_ssh_probe_success_and_failure(self):
        result, state = self.run_script(
            arguments=["--duration", "3", "--burst", "0", "--ssh-user", "colin", "--ssh-interval", "1"],
            ssh_replies={WIFI: "fail255"},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(state["ssh_args"], "no ssh probe was run")
        self.assertIn("ssh failures: 0\n", state["targets"][ETHERNET])
        self.assertNotIn("ssh failures: 0\n", state["targets"][WIFI])
        self.assertIn("status=255", state["probes"][WIFI])
        self.assertIn("reason=ssh", self.event_text(state))

    def test_ssh_probe_stops_at_the_deadline(self):
        result, state = self.run_script(
            arguments=["--duration", "3", "--burst", "0", "--ssh-user", "colin", "--ssh-interval", "1"],
            ssh_replies={ETHERNET: "hang"},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("status=124", state["probes"][ETHERNET])

    def test_worker_failure_fails_the_run_without_waiting(self):
        result, state = self.run_script(
            arguments=["--duration", "3", "--burst", "0"],
            replies={ETHERNET: ("1.2.3",)},
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("failed with status", result.stderr)
        self.assertIn(ETHERNET, state["targets"])
        self.assertIn("network-link-recorder-client summary", state["targets"][ETHERNET])

    def test_manual_signal_snapshots_all_targets(self):
        result, state = self.run_script(
            arguments=["--duration", "600", "--burst", "0"],
            interrupt="sighup",
        )
        manual = [text for name, text in state["events"].items() if "manual" in name]
        self.assertTrue(manual, state["events"].keys())
        for address in (ETHERNET, WIFI):
            self.assertIn(f"reason=manual target={address}", manual[0])

    def test_requires_a_target(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                ["bash", "-c", LIBRARY + "\n" + MOCKS + "\nmain \"$@\"", "network-link-recorder-client", "--logdir", directory],
                text=True,
                capture_output=True,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("at least one --target", result.stderr)

    def test_rejects_non_numeric_duration(self):
        result, _ = self.run_script(arguments=["--duration", "8h"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("whole minutes", result.stderr)

    def test_interrupt_leaves_a_summary_per_target(self):
        result, state = self.run_script(arguments=["--duration", "600", "--burst", "0"], interrupt="group")
        for address in (ETHERNET, WIFI):
            self.assertIn(address, state["targets"])
            self.assertIn("network-link-recorder-client summary", state["targets"][address])
        self.assertIn("combined summary", state["combined"])
        self.assertIn("workers outstanding: 0", state["combined"])


if __name__ == "__main__":
    unittest.main()
