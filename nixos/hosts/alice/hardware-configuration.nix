# PLACEHOLDER — replace this file before running nixos-install.
#
# During installation, after partitioning and mounting disks to /mnt, run:
#   nixos-generate-config --root /mnt
#
# Then copy /mnt/etc/nixos/hardware-configuration.nix to this file.
# That generated file contains disk UUIDs, filesystem types, kernel modules,
# and CPU settings specific to this machine — do not write it by hand.

{ modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];
}
