{
  writeShellApplication,
  coreutils,
}:

writeShellApplication {
  name = "network-link-recorder-client";
  runtimeInputs = [ coreutils ];
  text = builtins.readFile ../scripts/network-link-recorder-client.sh;
}
