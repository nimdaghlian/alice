{ config, pkgs, lib, ... }:

let
  cfg = config.alice.site;

  wifiQr = pkgs.writeShellScriptBin "wifi-qr" ''
    set -euo pipefail
    creds="/etc/alice/wifi-credentials"
    out="/home/gallery/wifi-qr.png"
    if [ ! -f "$creds" ]; then
      echo "Missing $creds — see docs/alice.md install steps" >&2
      exit 1
    fi
    ssid=$(grep -E '^SSID=' "$creds" | cut -d= -f2-)
    password=$(grep -E '^PASSWORD=' "$creds" | cut -d= -f2-)
    if [ -z "$ssid" ] || [ -z "$password" ]; then
      echo "$creds is missing SSID or PASSWORD" >&2
      exit 1
    fi
    ${pkgs.qrencode}/bin/qrencode -o "$out" "WIFI:T:WPA;S:$ssid;P:$password;;"
    echo "QR code written to $out"
  '';

  # Catalog a directory of media into Records + a Collection. Thin wrapper over memex2's CLI so
  # the attendant never types a node invocation or a path into the checkout.
  makeGallery = pkgs.writeShellScriptBin "make-gallery" ''
    set -euo pipefail
    cli="${cfg.checkout}/bin/memex.js"
    if [ ! -f "$cli" ]; then
      echo "memex2 not found at ${cfg.checkout} — see docs/alice.md install steps" >&2
      exit 1
    fi
    if [ $# -eq 0 ]; then
      echo "usage: make-gallery <directory>" >&2
      echo "  Catalogs the media in <directory> into the collection site." >&2
      exit 1
    fi
    exec ${pkgs.nodejs}/bin/node "$cli" process "$@"
  '';

  # One plain-English health summary of everything the kiosk needs to be working.
  galleryStatus = pkgs.writeShellScriptBin "gallery-status" ''
    set -uo pipefail

    check() {
      # $1 = unit, $2 = what it does in plain English
      if [ "$(systemctl is-active "$1")" = "active" ]; then
        echo "  OK      $2"
      else
        echo "  PROBLEM $2 (systemctl status $1)"
      fi
    }

    echo "Alice status:"
    check hostapd  "WiFi network is being broadcast"
    check dnsmasq  "Visitors can join and get an address"
    check eleventy "Collection site is rebuilding on changes"
    check nginx    "Collection site is being served"
  '';

  restartSite = pkgs.writeShellScriptBin "restart-site" ''
    set -euo pipefail
    # Only the builder needs restarting for content problems; nginx serves whatever is on disk
    # and only needs a restart if its own config changed (which a rebuild handles).
    sudo systemctl restart eleventy
    echo "Collection site builder restarted."
  '';

  updateSystem = pkgs.writeShellScriptBin "update-system" ''
    set -euo pipefail
    repo="${config.alice.configRepo}"
    if [ ! -d "$repo/.git" ]; then
      echo "No Alice configuration repository at $repo — see docs/alice.md install steps" >&2
      exit 1
    fi
    echo "This pulls the latest Alice configuration and applies it. It may take a while."
    sudo ${pkgs.git}/bin/git -C "$repo" pull
    sudo nixos-rebuild switch --flake "$repo/nixos#${config.alice.unit}"
  '';
in
{
  environment.systemPackages = [
    wifiQr
    makeGallery
    galleryStatus
    restartSite
    updateSystem
    pkgs.qrencode
  ];
}
