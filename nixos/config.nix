# Alice preferences — shared defaults for every Alice unit.
#
# These are BUILD-TIME values: they are baked into the system when you rebuild, so changing
# anything here requires `nixos-rebuild switch` (the `update-system` alias) to take effect.
# Runtime secrets do NOT belong here — the WiFi SSID/password live in /etc/alice/wifi-credentials
# on each machine, never in git.
#
# To override any of these for a single unit, create hosts/alice-N/config.nix with just the keys
# that differ, e.g.:
#
#   { timezone = "America/New_York"; galleryName = "East Wing"; }
#
# Per-unit values win; anything the unit does not mention falls back to the defaults below.

{
  # IANA timezone name. Full list: `timedatectl list-timezones` on any Linux box.
  timezone = "America/Los_Angeles";

  # System locale.
  locale = "en_US.UTF-8";

  # Human-readable name of the gallery/venue this unit serves.
  galleryName = "Alice Gallery";
}
