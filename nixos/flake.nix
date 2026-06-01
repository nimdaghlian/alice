{
  description = "Alice gallery kiosk — NixOS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  };

  outputs = { self, nixpkgs }: {
    nixosConfigurations.alice = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./hosts/alice/default.nix
        ./hosts/alice/hardware-configuration.nix
      ];
    };
  };
}
