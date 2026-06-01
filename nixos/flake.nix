{
  description = "Alice gallery kiosk — NixOS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  };

  outputs = { self, nixpkgs }:
    let
      # Shared helper: build an Alice machine from its hardware config
      mkAlice = hardwareConfig: nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./hosts/alice/default.nix
          hardwareConfig
        ];
      };
    in {
      nixosConfigurations = {
        alice-1 = mkAlice ./hosts/alice-1/hardware-configuration.nix;
        # alice-2 = mkAlice ./hosts/alice-2/hardware-configuration.nix;
        # alice-3 = mkAlice ./hosts/alice-3/hardware-configuration.nix;
      };
    };
}
