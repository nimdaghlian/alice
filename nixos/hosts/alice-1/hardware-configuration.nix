# NOT TRACKED IN GIT — machine-specific, generated during install.
#
# After partitioning and mounting disks to /mnt, run:
#   nixos-generate-config --root /mnt
#
# Then copy /mnt/etc/nixos/hardware-configuration.nix over this file.
# Contains disk UUIDs, filesystem types, kernel modules, and CPU settings
# specific to this machine — do not write it by hand.

{ modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];
}
