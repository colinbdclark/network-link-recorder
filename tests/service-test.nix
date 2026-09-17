{
  name = "network-link-recorder";

  nodes.machine =
    { ... }:
    {
      imports = [ ../modules/network-link-recorder.nix ];

      services.network-link-recorder = {
        enable = true;
        target = "192.0.2.1";
        duration = 5;
        interval = 1;
        burst = 0;
      };
    };

  testScript = ''
    start_all()

    machine.wait_for_unit("network-link-recorder.service")
    machine.wait_until_succeeds(
        "grep -q 'probes: [1-9]' /var/log/network-link-recorder/summary-*.txt", timeout=120
    )
    machine.wait_until_succeeds(
        "test -s /var/log/network-link-recorder/events/*/events.log", timeout=120
    )

    machine.systemctl("stop network-link-recorder.service")
    machine.fail("systemctl is-active --quiet network-link-recorder.service")
    machine.succeed("grep -q 'events: [1-9]' /var/log/network-link-recorder/summary-*.txt")
  '';
}
