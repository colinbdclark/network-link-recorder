{
  description = "Probe a network link continuously and keep the evidence around faults";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    {
      self,
      nixpkgs,
    }:
    let
      lib = nixpkgs.lib;

      systems = [
        "aarch64-linux"
        "x86_64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      forAllSystems = lib.genAttrs systems;
      pkgsFor = system: nixpkgs.legacyPackages.${system};

      mkRecorder = pkgs: pkgs.callPackage ./packages/network-link-recorder.nix { };

      mkClient = pkgs: pkgs.callPackage ./packages/network-link-recorder-client.nix { };

      recorderPackageCheck =
        system:
        let
          pkgs = pkgsFor system;
          recorder = mkRecorder pkgs;
        in
        pkgs.runCommand "check-recorder-package"
          {
            nativeBuildInputs = [ pkgs.gnugrep ];
          }
          ''
            ${recorder}/bin/network-link-recorder --help > /dev/null
            grep -q '${pkgs.tcpdump}' ${recorder}/bin/network-link-recorder
            grep -q '${pkgs.iputils}' ${recorder}/bin/network-link-recorder
            grep -q '${pkgs.iproute2}' ${recorder}/bin/network-link-recorder
            grep -q '${pkgs.ethtool}' ${recorder}/bin/network-link-recorder
            touch $out
          '';

      clientPackageCheck =
        system:
        let
          pkgs = pkgsFor system;
          client = mkClient pkgs;
        in
        pkgs.runCommand "check-client-package"
          {
            nativeBuildInputs = [ pkgs.gnugrep ];
          }
          ''
            ${client}/bin/network-link-recorder-client --help > /dev/null
            grep -q '/sbin/ping' ${client}/bin/network-link-recorder-client
            grep -q '/usr/sbin/route' ${client}/bin/network-link-recorder-client
            grep -q '/usr/bin/ssh' ${client}/bin/network-link-recorder-client
            touch $out
          '';

      formatCheck =
        system:
        (pkgsFor system).runCommand "check-format"
          {
            nativeBuildInputs = [ (pkgsFor system).nixfmt ];
          }
          ''
            find ${self} -name '*.nix' -print0 | xargs -0 -r nixfmt --check
            touch $out
          '';

      scriptCheck =
        system:
        let
          pkgs = pkgsFor system;
        in
        pkgs.runCommand "check-scripts"
          {
            nativeBuildInputs = [
              pkgs.python3
              pkgs.shellcheck
            ];
          }
          ''
            shellcheck --shell=bash ${./scripts/network-link-recorder.sh}
            shellcheck --shell=bash ${./scripts/network-link-recorder-client.sh}
            python3 ${./tests/network-link-recorder.py} ${./scripts/network-link-recorder.sh}
            python3 ${./tests/network-link-recorder-client.py} ${./scripts/network-link-recorder-client.sh}
            touch $out
          '';
    in
    {
      nixosModules.default = ./modules/network-link-recorder.nix;
      nixosModules.network-link-recorder = self.nixosModules.default;

      packages = forAllSystems (
        system:
        lib.optionalAttrs (lib.hasSuffix "linux" system) {
          network-link-recorder = mkRecorder (pkgsFor system);
        }
        // lib.optionalAttrs (lib.hasSuffix "darwin" system) {
          network-link-recorder-client = mkClient (pkgsFor system);
        }
      );

      checks = forAllSystems (
        system:
        {
          format = formatCheck system;
          scripts = scriptCheck system;
        }
        // lib.optionalAttrs (lib.hasSuffix "linux" system) {
          recorder-package = recorderPackageCheck system;
          service = (pkgsFor system).testers.runNixOSTest ./tests/service-test.nix;
        }
        // lib.optionalAttrs (lib.hasSuffix "darwin" system) {
          client-package = clientPackageCheck system;
        }
      );

      nixosConfigurations.example = lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          self.nixosModules.default
          ./examples/minimal.nix
        ];
      };

      formatter = forAllSystems (system: (pkgsFor system).nixfmt-tree);

      devShells = forAllSystems (system: {
        default = (pkgsFor system).mkShell {
          packages = with pkgsFor system; [
            just
            nixfmt
            python3
            shellcheck
          ];
        };
      });
    };
}
