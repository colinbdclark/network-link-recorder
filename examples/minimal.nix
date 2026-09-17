{ pkgs, ... }:

{
  services.network-link-recorder = {
    enable = true;
    target = "192.168.1.1";
    duration = 60;
  };

  networking.hostName = "example";
  system.stateVersion = "26.05";

  boot.loader.grub.enable = false;
  fileSystems."/" = {
    device = "/dev/sda1";
    fsType = "ext4";
  };

  environment.systemPackages = [ pkgs.vim ];
}
