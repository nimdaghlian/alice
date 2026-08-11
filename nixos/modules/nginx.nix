{ config, pkgs, lib, ... }:

let
  cfg = config.alice.site;
  apInterface = config.alice.wifiAp.interface;
in
{
  # The production HTTP frontend. Two roots under ONE origin, so /library/... URLs emitted by
  # memex2's templates resolve the same way they do in local development:
  #
  #   /          → _site/        (Eleventy's build output, HTML)
  #   /library/  → site/library/ (the media library, served from source — never copied)
  #
  # Serving the library straight from its source directory is the whole point: Eleventy's
  # passthrough copy would otherwise duplicate it into _site/ on every rebuild.
  services.nginx = {
    enable = true;

    virtualHosts."alice" = {
      # Answer regardless of Host header, so http://alice and http://10.0.0.1 both work.
      default = true;

      locations."/" = {
        root = "${cfg.checkout}/_site";
      };

      locations."/library/" = {
        alias = "${cfg.checkout}/site/library/";
        extraConfig = ''
          # Media files are content-addressed by memex2 and effectively immutable.
          autoindex off;
        '';
      };
    };
  };

  # nginx runs as its own user and must traverse the attendant's home to reach the checkout.
  # Without this the site returns 403 even though the paths are correct.
  users.users.nginx.extraGroups = [ "users" ];

  # Visitors reach the site over the AP only. Scoped to that interface so Alice does not expose
  # the collection on any other network it joins (e.g. ethernet for updates).
  networking.firewall.interfaces.${apInterface}.allowedTCPPorts = [ 80 ];
}
