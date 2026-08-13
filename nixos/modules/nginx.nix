{ config, pkgs, lib, ... }:

let
  cfg = config.alice.site;
  apInterface = config.alice.wifiAp.interface;
in
{
  # The only web server on the machine. Two roots under ONE origin, both outside the memex2
  # checkout and both written directly by the build — nothing is copied to get here:
  #
  #   /          → alice.site.outputPath  (/srv/www/alice — Eleventy builds straight into it)
  #   /library/  → alice.site.libraryPath (/srv/library — the media library, on its own disk)
  #
  # Keeping both out of /home matters: NixOS sets ProtectHome on nginx's systemd unit, so
  # anything under /home is invisible to the service no matter what the file permissions say.
  # Building into /srv means the stock hardening is left intact.
  services.nginx = {
    enable = true;

    virtualHosts."alice" = {
      # Answer regardless of Host header, so http://alice and http://10.0.0.1 both work.
      default = true;

      locations."/" = {
        root = cfg.outputPath;
      };

      locations."/library/" = {
        alias = "${cfg.libraryPath}/";
        extraConfig = ''
          autoindex off;
        '';
      };
    };
  };

  # Visitors reach the site over the AP only. Scoped to that interface so Alice does not expose
  # the collection on any other network it joins (e.g. ethernet for updates).
  networking.firewall.interfaces.${apInterface}.allowedTCPPorts = [ 80 ];
}
