{ config, pkgs, lib, ... }:

let
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
in
{
  environment.systemPackages = [ wifiQr pkgs.qrencode ];
}
