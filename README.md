# network-link-recorder

A Nix flake and set of scripts for recording a network link for fault tracing.

This repository was created with the assistance of DeepSeek V4.1 Flash.

## Components

### Device Recorder

`network-link-recorder` runs on the monitored host. It pings a target, tests throughput with periodic bursts, and keeps a rotating packet capture. On failure, the recorder writes the interface counters, neighbour table, kernel messages, pressure and a copy of the capture covering the time before the failure.

### Client Recorder

`network-link-recorder-client` runs on the observing Mac. It probes the same addresses, optionally opening a short SSH session on each interval so that reachability and session responsiveness are measured separately. In case of failure, it records what the observing machine was doing when either failed.

To avoid losing recorded data, it writes a summary at the start, every ten probes, and at exit.

## Use as a NixOS module

Add the input to `flake.nix` and pass it through `specialArgs`:

```nix
inputs.network-link-recorder.url = "github:colinbdclark/nix-network-link-recorder";
inputs.network-link-recorder.inputs.nixpkgs.follows = "nixpkgs";

outputs = { nixpkgs, ... }@inputs: {
  nixosConfigurations.host = nixpkgs.lib.nixosSystem {
    specialArgs = { inherit inputs; };
    modules = [ ./configuration.nix ];
  };
};
```

In `configuration.nix`, import the module and set the options:

```nix
{ inputs, ... }:

{
  imports = [ inputs.network-link-recorder.nixosModules.default ];
  services.network-link-recorder = {
    enable = true;
    target = "192.168.1.1";
    interface = "end0";
    duration = 480;
    interval = 1;
    burst = 15;
    keep = 7;
    logdir = "/var/log/network-link-recorder";
  };
}
```

## Use on a workstation

```console
nix run github:colinbdclark/nix-network-link-recorder#network-link-recorder-client -- \
  --target 192.168.1.9 --target 192.168.1.15 --ssh-user colin
```

On macOS, the client should run under `caffeinate -i`, otherwise the Mac may go to sleep and drop its own wireless link, resulting in false stall observations.

The client uses macOS-specific CLI tools and does not currently work on Windows or Linux.

## Options

| Option | Default | Purpose |
| --- | --- | --- |
| `enable` | `false` | Run the recorder as a systemd service |
| `package` | the flake's recorder package | Package providing the recorder script |
| `target` | the gateway of the monitored interface | Address to probe |
| `interface` | the interface that routes to `target`, else the default route | Interface to monitor |
| `duration` | `480` | Length of a run, in minutes |
| `interval` | `1` | Seconds between probes |
| `burst` | `15` | Minutes between bursts of a thousand 1472-byte pings; `0` disables |
| `keep` | `7` | Days of logs and captures to keep |
| `logdir` | `/var/log/network-link-recorder` | Where logs, summaries and events go |

Run the services' script by hand for other arrangements:

```console
network-link-recorder --help
network-link-recorder-client --help
```

## Reading the results

| File | Contents |
| --- | --- |
| `summary-RUN.txt` | Probe counts, loss, RTT min/avg/max, a latency histogram, event list and counter deltas |
| `probe-RUN.log` | Start context, five-minute windows, burst results |
| `events/RUN/events.log` | Per-event state: counters, neighbours, softnet, pressure, load, kernel messages |
| `events/RUN/*.pcap` | The capture covering the event |

`SIGUSR1` to the recorder records an event immediately, for a failure you saw rather than one the probes detected:

```console
systemctl kill -s SIGUSR1 --kill-who=main network-link-recorder
```

## Checks

```console
nix flake check        # formatting, script tests, package checks and the service test
```

The script tests run the parsers and the run loop against a mocked clock, `ping` and `tcpdump`, and cover loss accounting, burst parsing, event capture, capture failures, retention, signal handling and argument validation.

## Testing unpushed changes

When testing changes to this flake from a consuming repository, there are two options for referring to your local version:

1. Create an `.envrc.local` file in the consuming repository and set the `NETWORK_LINK_RECORDER_SRC` environment variable (e.g. `export NETWORK_LINK_RECORDER_SRC="$HOME/code/nix-network-link-recorder"`), and have that repository's `.envrc` pass it to the flake: `use flake . --override-input network-link-recorder "path:$NETWORK_LINK_RECORDER_SRC"`.
2. Manually override the path to network-link-recorder:

```console
nix build --override-input network-link-recorder path:<path_to_your_network-link-recorder_clone>
```
