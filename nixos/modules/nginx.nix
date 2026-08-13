{ config, pkgs, lib, ... }:

let
  cfg = config.alice.site;
  apInterface = config.alice.wifiAp.interface;
in
{
  # The production HTTP frontend. Two roots under ONE origin, so /library/... URLs emitted by
  # memex2's templates resolve the same way they do in local development:
  #
  #   /          → <checkout>/_site   (Eleventy's build output, HTML)
  #   /library/  → alice.site.libraryPath, default /srv/library (the media library, on its own
  #               disk, served straight from source — never copied)
  #
  # memex2 must be configured for `libraryMode: external` with a matching `library:` path.
  # Embedded mode cannot serve a library on a separate disk at all: Eleventy rejects a
  # passthrough source outside the project directory.
  services.nginx = {
    enable = true;

    virtualHosts."alice" = {
      # Answer regardless of Host header, so http://alice and http://10.0.0.1 both work.
      default = true;

      locations."/" = {
        root = "${cfg.checkout}/_site";
      };

      locations."/library/" = {
        alias = "${cfg.libraryPath}/";
        extraConfig = ''
          autoindex off;
        '';
      };
    };
  };

  # NixOS sets ProtectHome = mkDefault true on nginx's systemd unit, which makes /home appear
  # EMPTY to the service — every request for the site under /home/gallery/memex2/_site would
  # 404 regardless of file permissions, since this is a mount-namespace block rather than an
  # access-control one. The media library lives outside /home precisely to avoid this, but the
  # Eleventy build output still sits in the attendant's checkout (they edit Records there in
  # Obsidian), so the protection has to be relaxed for nginx to read it.
  #
  # Narrower alternative, worth testing later: keep ProtectHome and re-expose just the build
  # output with BindReadOnlyPaths = [ "${cfg.checkout}/_site" ].
  systemd.services.nginx.serviceConfig.ProtectHome = lib.mkForce false;

  # Ensure the library root exists and is writable by the attendant before anything uses it —
  # `memex process` writes manifest.json into asset directories, and a freshly formatted disk
  # is root-owned.
  systemd.tmpfiles.rules = [
    "d ${cfg.libraryPath} 0755 ${cfg.user} users -"
  ];

  # Visitors reach the site over the AP only. Scoped to that interface so Alice does not expose
  # the collection on any other network it joins (e.g. ethernet for updates).
  networking.firewall.interfaces.${apInterface}.allowedTCPPorts = [ 80 ];
}
