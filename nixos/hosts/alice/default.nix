{ config, pkgs, ... }:

{
  # Bootloader — assumes UEFI (ThinkCentre M710q ships with UEFI)
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Hostname
  networking.hostName = "alice";

  # NetworkManager handles WiFi during setup;
  # will be replaced with hostapd AP config in production
  networking.networkmanager.enable = true;

  # TODO: set to gallery's actual timezone
  time.timeZone = "America/Los_Angeles";

  # Locale
  i18n.defaultLocale = "en_US.UTF-8";

  # GNOME desktop
  services.xserver.enable = true;
  services.xserver.displayManager.gdm.enable = true;
  services.xserver.desktopManager.gnome.enable = true;

  # Primary user — gallery attendant
  users.users.gallery = {
    isNormalUser = true;
    description = "Gallery Attendant";
    extraGroups = [ "networkmanager" "wheel" ];
    # Set a password after first boot with: passwd gallery
  };

  # SSH — for remote management by admin
  services.openssh.enable = true;

  # Basic packages for first-boot testing
  environment.systemPackages = with pkgs; [
    git
    vim
    curl
    wget
    jekyll
  ];

  # Must match the nixpkgs version in flake.nix
  system.stateVersion = "25.05";
}
