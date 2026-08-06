{ config, pkgs, lib, ... }:

let
  cfg = config.alice.wifiAp;

  hostapdTemplate = pkgs.writeText "hostapd.conf.template" ''
    interface=${cfg.interface}
    driver=nl80211
    ssid=@SSID@
    hw_mode=g
    channel=6
    wpa=2
    wpa_passphrase=@PASSWORD@
    wpa_key_mgmt=WPA-PSK
    rsn_pairwise=CCMP
  '';

  renderHostapdConf = pkgs.writeShellScript "render-hostapd-conf" ''
    set -euo pipefail
    creds="/etc/alice/wifi-credentials"
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
    mkdir -p /run/hostapd
    sed -e "s/@SSID@/$ssid/" -e "s/@PASSWORD@/$password/" ${hostapdTemplate} > /run/hostapd/hostapd.conf
    chmod 600 /run/hostapd/hostapd.conf
  '';
in
{
  options.alice.wifiAp.interface = lib.mkOption {
    type = lib.types.str;
    default = "wlan0";
    description = "Network interface used for Alice's WiFi access point.";
  };

  config = {
    networking.networkmanager.unmanaged = [ cfg.interface ];

    networking.interfaces.${cfg.interface}.ipv4.addresses = [
      { address = "10.0.0.1"; prefixLength = 24; }
    ];

    systemd.services.hostapd = {
      description = "Alice WiFi access point";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStartPre = "${renderHostapdConf}";
        ExecStart = "${pkgs.hostapd}/bin/hostapd /run/hostapd/hostapd.conf";
        Restart = "on-failure";
      };
    };

    services.dnsmasq = {
      enable = true;
      settings = {
        interface = cfg.interface;
        bind-interfaces = true;
        "dhcp-range" = [ "10.0.0.50,10.0.0.150,24h" ];
        "dhcp-option" = [ "3,10.0.0.1" "6,10.0.0.1" ];
      };
    };
  };
}
