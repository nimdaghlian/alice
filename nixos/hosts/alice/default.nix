{ config, pkgs, ... }:

{
  imports = [
    ../../modules/settings.nix   # timezone/locale/gallery name
    ../../modules/wifi-ap.nix    # hostapd + dnsmasq
    ../../modules/eleventy.nix   # memex2 site builder (watch mode)
    ../../modules/nginx.nix      # serves the built site + media library
    ../../modules/aliases.nix    # attendant commands
  ];

  # Bootloader — assumes UEFI (ThinkCentre M710q ships with UEFI)
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.systemd-boot.configurationLimit = 5;

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

  # Timezone and locale come from nixos/config.nix via modules/settings.nix.

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

  # nodejs runs memex2 (its CLI and Eleventy); git clones and updates both repos.
  # obsidian is the attendant's editor for the Markdown memex2 generates.
  environment.systemPackages = with pkgs; [
    git
    vim
    curl
    wget
    nodejs
    obsidian
  ];

  # Must match the nixpkgs version in flake.nix
  system.stateVersion = "25.05";
}
