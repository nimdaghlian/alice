{ config, lib, ... }:

let
  cfg = config.alice.settings;
in
{
  # Values come from nixos/config.nix (shared) merged with hosts/alice-N/config.nix (per-unit),
  # wired up in flake.nix. This module only declares them and applies them to real NixOS options.
  options.alice.settings = {
    timezone = lib.mkOption {
      type = lib.types.str;
      description = "IANA timezone name for this unit.";
    };

    locale = lib.mkOption {
      type = lib.types.str;
      description = "System default locale.";
    };

    galleryName = lib.mkOption {
      type = lib.types.str;
      description = "Human-readable name of the gallery/venue this unit serves.";
    };
  };

  # Identity/plumbing rather than preferences, so kept out of alice.settings and nixos/config.nix.
  options.alice.unit = lib.mkOption {
    type = lib.types.str;
    description = ''
      This machine's flake attribute name, e.g. "alice-1". Set automatically by flake.nix from
      the host directory; used by `update-system` to rebuild the right configuration, since the
      hostname ("alice") is shared across units and cannot identify one.
    '';
  };

  options.alice.configRepo = lib.mkOption {
    type = lib.types.str;
    default = "/etc/nixos";
    description = ''
      On-machine clone of this repository, used by `update-system` to pull and rebuild.
      Placed here during install; see docs/alice.md.
    '';
  };

  config = {
    time.timeZone = cfg.timezone;
    i18n.defaultLocale = cfg.locale;

    # Nothing in the Nix config consumes galleryName yet — it is exposed here so signage, the
    # memex2 site, or an attendant script can read it without needing to parse Nix.
    environment.etc."alice/gallery-name".text = "${cfg.galleryName}\n";
  };
}
