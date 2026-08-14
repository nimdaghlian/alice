{ config, pkgs, lib, ... }:

let
  cfg = config.alice.wifiAp;

  # Written by an ExecStartPre at service start, never at build time — the passphrase must not
  # reach the world-readable Nix store.
  #
  # Uses a quoted heredoc rather than substituting into a template with `sed`. sed treats `/`,
  # `&` and `\` as special in the replacement text, so a passphrase containing any of them would
  # silently render a corrupt config — a nasty failure mode for a value the operator chooses
  # freely. Shell expansion inside a heredoc has no such special cases.
  renderHostapdConf = pkgs.writeShellScript "render-hostapd-conf" ''
    set -euo pipefail
    creds="/etc/alice/wifi-credentials"
    if [ ! -f "$creds" ]; then
      echo "Missing $creds — see install.md" >&2
      exit 1
    fi
    ssid=$(grep -E '^SSID=' "$creds" | cut -d= -f2-)
    password=$(grep -E '^PASSWORD=' "$creds" | cut -d= -f2-)
    if [ -z "$ssid" ] || [ -z "$password" ]; then
      echo "$creds is missing SSID or PASSWORD" >&2
      exit 1
    fi
    # WPA2 requires 8-63 characters; hostapd refuses to start otherwise, well after install.
    if [ ''${#password} -lt 8 ] || [ ''${#password} -gt 63 ]; then
      echo "PASSWORD in $creds must be 8-63 characters (WPA2 requirement)" >&2
      exit 1
    fi
    mkdir -p /run/hostapd
    umask 077
    cat > /run/hostapd/hostapd.conf <<EOF
    interface=${cfg.interface}
    driver=nl80211
    ssid=$ssid
    hw_mode=g
    channel=6
    wpa=2
    wpa_passphrase=$password
    wpa_key_mgmt=WPA-PSK
    rsn_pairwise=CCMP
    EOF
  '';
in
{
  options.alice.wifiAp.interface = lib.mkOption {
    type = lib.types.str;
    default = "wlan0";
    description = "Network interface used for Alice's WiFi access point.";
  };

  config = {
    # Keep NetworkManager off the AP interface entirely — hostapd owns it. NM's unmanaged-devices
    # syntax requires a qualifier ("interface-name:", "mac:", "type:"); a bare device name is not
    # a valid match spec and would silently fail to exclude anything.
    networking.networkmanager.unmanaged = [ "interface-name:${cfg.interface}" ];

    networking.interfaces.${cfg.interface}.ipv4.addresses = [
      { address = "10.0.0.1"; prefixLength = 24; }
    ];

    # Without these, visitors associate with the WiFi but never get a DHCP lease — it presents as
    # "the network is broken", not as a blocked port. Scoped to the AP interface so Alice does not
    # act as an open DNS resolver / DHCP server on any other network it joins (e.g. ethernet for
    # updates). Port 80 is opened by nginx.nix when that module is built.
    networking.firewall.interfaces.${cfg.interface} = {
      allowedUDPPorts = [ 53 67 ];   # DNS, DHCP server
      allowedTCPPorts = [ 53 ];      # DNS over TCP (large responses)
    };

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
        # 3 = default gateway, 6 = DNS server — both Alice, so the name below resolves.
        "dhcp-option" = [ "3,10.0.0.1" "6,10.0.0.1" ];
        # Makes http://alice work for anyone on the WiFi, with no client-side configuration.
        "address" = [ "/alice/10.0.0.1" ];
        # Do NOT serve /etc/hosts to clients. NixOS puts `127.0.0.2 alice` there for the machine's
        # own hostname, and dnsmasq reads /etc/hosts by default — so without this it hands visitors
        # 127.0.0.2, their own loopback, and the site simply hangs. It looks fine when tested on
        # Alice itself, where 127.0.0.2 is a local address nginx answers on.
        no-hosts = true;
      };
    };
  };
}
