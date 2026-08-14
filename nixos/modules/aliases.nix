{ config, pkgs, lib, ... }:

let
  cfg = config.alice.site;

  # The credentials file is root-only (mode 600), but this alias is attendant-facing and runs as
  # the gallery user — so the read goes through sudo. Without it the grep fails with a permission
  # error that surfaces as a misleading "missing SSID or PASSWORD".
  wifiQr = pkgs.writeShellScriptBin "wifi-qr" ''
    set -euo pipefail
    creds="/etc/alice/wifi-credentials"
    out="$HOME/wifi-qr.png"
    if ! sudo test -f "$creds"; then
      echo "Missing $creds — see install.md" >&2
      exit 1
    fi
    text="$(sudo cat "$creds")"
    ssid=$(printf '%s\n' "$text" | grep -E '^SSID=' | cut -d= -f2-)
    password=$(printf '%s\n' "$text" | grep -E '^PASSWORD=' | cut -d= -f2-)
    if [ -z "$ssid" ] || [ -z "$password" ]; then
      echo "$creds is missing SSID or PASSWORD" >&2
      exit 1
    fi
    ${pkgs.qrencode}/bin/qrencode -o "$out" "WIFI:T:WPA;S:$ssid;P:$password;;"
    echo "QR code written to $out"
    echo "SSID: $ssid"
  '';

  # Catalog a directory of media into Records + a Collection. Thin wrapper over memex2's CLI so
  # the attendant never types a node invocation or a path into the checkout.
  #
  # MUST run from the checkout: memex2 resolves memex.config.yml from the current working
  # directory (src/config.js, `join(cwd, CONFIG_NAME)`) and resolves relative `out`/`library`
  # against it too. Run from anywhere else and it silently falls back to DEFAULTS —
  # libraryMode "embedded", library "./library" — writing Records to the wrong place with wrong
  # asset paths and no error. So: absolutize the target directory first, THEN cd.
  makeGallery = pkgs.writeShellScriptBin "make-gallery" ''
    set -euo pipefail
    cli="${cfg.checkout}/bin/memex.js"
    if [ ! -f "$cli" ]; then
      echo "memex2 not found at ${cfg.checkout} — see install.md" >&2
      exit 1
    fi
    if [ $# -eq 0 ]; then
      echo "usage: make-gallery <directory>" >&2
      echo "  Catalogs the media in <directory> into the collection site." >&2
      echo "  Media lives under ${cfg.libraryPath}/<gallery-name>/" >&2
      exit 1
    fi
    dir="$1"; shift
    if [ ! -d "$dir" ]; then
      echo "Not a directory: $dir" >&2
      exit 1
    fi
    dir="$(cd "$dir" && pwd)"
    cd "${cfg.checkout}"
    exec ${pkgs.nodejs}/bin/node "$cli" process "$dir" "$@"
  '';

  # The full memex2 CLI (tag, update, verify, or no arguments for the interactive wizard).
  # `npm link` cannot provide this on NixOS — the global npm prefix is in the read-only Nix
  # store, which is what the EROFS error means. Same cd-to-checkout requirement as above, so
  # pass absolute paths to subcommands that take one.
  memexCli = pkgs.writeShellScriptBin "memex" ''
    set -euo pipefail
    cli="${cfg.checkout}/bin/memex.js"
    if [ ! -f "$cli" ]; then
      echo "memex2 not found at ${cfg.checkout} — see install.md" >&2
      exit 1
    fi
    cd "${cfg.checkout}"
    exec ${pkgs.nodejs}/bin/node "$cli" "$@"
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

  # Visitors scan this AFTER joining the WiFi. A single QR cannot both join a network and open a
  # URL — those are different payload formats — so this is a second code alongside wifi-qr.
  # Uses the gateway IP rather than http://alice deliberately: it needs no DNS at all, which
  # sidesteps phones that fall back to cellular DNS when a WiFi network has no internet. Nobody
  # reads a QR code, so the uglier URL costs nothing.
  siteQr = pkgs.writeShellScriptBin "site-qr" ''
    set -euo pipefail
    out="$HOME/site-qr.png"
    url="http://10.0.0.1/"
    ${pkgs.qrencode}/bin/qrencode -o "$out" "$url"
    echo "QR code for $url written to $out"
    echo "Print alongside the WiFi code: visitors scan to join, then scan this to browse."
  '';

  # Eleventy only ever writes output — it never removes files for deleted sources. So a removed
  # gallery keeps its generated pages in the served directory indefinitely. This wipes the build
  # output and rebuilds from scratch, which is the only way to make a deletion take effect.
  rebuildSite = pkgs.writeShellScriptBin "rebuild-site" ''
    set -euo pipefail
    out="${cfg.outputPath}"
    case "$out" in
      /|""|/srv|/home) echo "Refusing to clear $out" >&2; exit 1 ;;
    esac
    echo "Clearing $out and rebuilding from scratch..."
    sudo find "$out" -mindepth 1 -delete
    sudo systemctl restart eleventy
    echo "Rebuilt. Pages for deleted galleries are now gone."
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

  # memex2 is deliberately not a Nix derivation (its CLI writes generated content back into its
  # own working tree), so update-system's rebuild never touches it. This is the equivalent for
  # that live checkout: pull, reinstall in case dependencies changed, then restart the builder so
  # the new code takes effect.
  updateMemex = pkgs.writeShellScriptBin "update-memex" ''
    set -euo pipefail
    checkout="${cfg.checkout}"
    if [ ! -d "$checkout/.git" ]; then
      echo "No memex2 checkout at $checkout — see install.md" >&2
      exit 1
    fi
    echo "This pulls the latest memex2 and restarts the collection site builder. It may take a while."
    ${pkgs.git}/bin/git -C "$checkout" pull
    ${pkgs.nodejs}/bin/npm install --prefix "$checkout"
    sudo systemctl restart eleventy
    echo "memex2 updated and the site builder restarted."
  '';
in
{
  environment.systemPackages = [
    wifiQr
    siteQr
    makeGallery
    memexCli
    galleryStatus
    restartSite
    rebuildSite
    updateSystem
    updateMemex
    pkgs.qrencode
  ];
}
