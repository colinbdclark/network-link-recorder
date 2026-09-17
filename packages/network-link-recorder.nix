{
  writeShellApplication,
  coreutils,
  ethtool,
  findutils,
  gnugrep,
  gnused,
  iproute2,
  iputils,
  tcpdump,
  util-linux,
}:

writeShellApplication {
  name = "network-link-recorder";
  runtimeInputs = [
    coreutils
    ethtool
    findutils
    gnugrep
    gnused
    iproute2
    iputils
    tcpdump
    util-linux
  ];
  text = builtins.readFile ../scripts/network-link-recorder.sh;
}
