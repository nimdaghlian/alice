{
  description = "Alice gallery kiosk — NixOS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  };

  outputs = { self, nixpkgs }:
    let
      # Shared preferences (timezone, locale, gallery name), overridable per machine.
      sharedSettings = import ./config.nix;

      # Build an Alice machine from its host directory name, e.g. "alice-1".
      # Each host dir carries its own hardware-configuration.nix, and MAY carry a config.nix
      # holding only the preference keys that differ from nixos/config.nix.
      mkAlice = name:
        let
          hostDir = ./hosts + "/${name}";
          hostSettingsFile = hostDir + "/config.nix";
          hostSettings =
            if builtins.pathExists hostSettingsFile
            then import hostSettingsFile
            else { };
        in
        nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            ./hosts/alice/default.nix
            (hostDir + "/hardware-configuration.nix")
            {
              # Per-unit values win over the shared defaults.
              alice.settings = sharedSettings // hostSettings;
              # So `update-system` can rebuild this exact unit without hardcoding a name.
              alice.unit = name;
            }
          ];
        };
    in {
      nixosConfigurations = {
        alice-1 = mkAlice "alice-1";
        # alice-2 = mkAlice "alice-2";
        # alice-3 = mkAlice "alice-3";
      };
    };
}
