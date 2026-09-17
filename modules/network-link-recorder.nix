{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.network-link-recorder;
in
{
  options.services.network-link-recorder = {
    enable = lib.mkEnableOption "probing the network path and recording failures";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../packages/network-link-recorder.nix { };
      description = "Package providing the recorder script.";
    };

    target = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "192.168.1.1";
      description = "Address to probe. The default gateway is used when empty.";
    };

    interface = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "end0";
      description = "Interface to monitor. The interface that routes to the target is used when empty, otherwise the interface holding the default route.";
    };

    duration = lib.mkOption {
      type = lib.types.ints.positive;
      default = 480;
      description = "Length of a run, in minutes.";
    };

    interval = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
      description = "Seconds between probes.";
    };

    burst = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 15;
      description = "Minutes between bursts of one thousand pings of 1472 bytes. Zero disables bursts.";
    };

    keep = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 7;
      description = "Days of logs and captures to keep. Zero keeps everything.";
    };

    logdir = lib.mkOption {
      type = lib.types.str;
      default = "/var/log/network-link-recorder";
      description = "Directory for probe logs, summaries and event captures.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d ${cfg.logdir} 0755 root root -"
      "d ${cfg.logdir}/events 0755 root root -"
    ];

    systemd.services.network-link-recorder = {
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];

      serviceConfig = {
        Type = "simple";
        Nice = 10;
        RuntimeDirectory = "network-link-recorder";
        ExecStart = lib.escapeShellArgs [
          "${cfg.package}/bin/network-link-recorder"
          "--target"
          cfg.target
          "--interface"
          cfg.interface
          "--duration"
          (toString cfg.duration)
          "--interval"
          (toString cfg.interval)
          "--burst"
          (toString cfg.burst)
          "--keep"
          (toString cfg.keep)
          "--logdir"
          cfg.logdir
          "--ringdir"
          "%t/network-link-recorder"
        ];
      };
    };

    environment.systemPackages = [ cfg.package ];
  };
}
