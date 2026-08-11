{ config, pkgs, ... }:

{
  # WiFi access point (hostapd + dnsmasq) and attendant aliases
  imports = [
    ../../modules/wifi-ap.nix
    ../../modules/aliases.nix
  ];

  # Bootloader — assumes UEFI (ThinkCentre M710q ships with UEFI)
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Hostname
  networking.hostName = "alice";

  # NetworkManager handles everything EXCEPT the AP interface, which wifi-ap.nix marks unmanaged.
  # Set explicitly rather than relying on GNOME enabling it by default — the `gallery` user's
  # networkmanager group membership below depends on this being on.
  networking.networkmanager.enable = true;

  # Alice is fixed single-purpose hardware (one WiFi, one ethernet), so old-style kernel names are
  # deterministic here — and it makes wifi-ap.nix's `wlan0` default correct without having to look
  # up the predictable name (wlpXsY) on each unit. Override alice.wifiAp.interface if this changes.
  networking.usePredictableInterfaceNames = false;

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
    # Applies only at first account creation, so GDM is reachable on first boot.
    # Stored in plaintext in the world-readable Nix store — change it after install
    # with `passwd gallery`; changing it there does not require a rebuild.
    initialPassword = "password";
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
