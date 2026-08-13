{ config, pkgs, lib, ... }:

let
  cfg = config.alice.site;
in
{
  options.alice.site = {
    checkout = lib.mkOption {
      type = lib.types.str;
      default = "/home/gallery/memex2";
      description = ''
        Path to the memex2 git checkout. This is a live working directory, not a Nix
        derivation — `memex process` writes manifests and Records back into it, which the
        read-only Nix store cannot support. Cloned during install; see docs/alice.md.

        Only the SOURCE lives here. Both things nginx serves — the built site and the media
        library — are written outside it, so nginx never has to read from /home.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "gallery";
      description = "User that owns the memex2 checkout and runs the site builder.";
    };

    libraryPath = lib.mkOption {
      type = lib.types.str;
      default = "/srv/library";
      description = ''
        Media library root, served by nginx at /library/. Normally a dedicated disk.

        memex2's memex.config.yml must agree with this path:
          libraryMode: external
          library: /srv/library
          libraryUrl: /library/

        Alice ALWAYS uses external mode. Embedded mode would have Eleventy copy the entire
        library into the build output on every rebuild — untenable at ~1TB — and Eleventy
        refuses a passthrough source outside the project directory anyway, so a library on
        its own disk cannot work any other way.
      '';
    };

    outputPath = lib.mkOption {
      type = lib.types.str;
      default = "/srv/www/alice";
      description = ''
        Where Eleventy writes the built site, and where nginx serves it from. Passed as
        `--output`, overriding the `dir.output` (`_site`) in memex2's eleventy.config.js.

        Building straight into the served directory means one web server and no copy step.
        It also keeps nginx out of /home entirely: NixOS sets ProtectHome on nginx's systemd
        unit, which makes /home appear empty to the service regardless of file permissions,
        so serving the in-checkout _site would 404 every request.
      '';
    };
  };

  config = {
    # Build-only watch mode: regenerates the site on change and nothing else. Deliberately NOT
    # `--serve` — nginx is the production frontend, and Eleventy's dev server is not meant for
    # unattended use. See docs/superpowers/specs/2026-08-06-memex2-migration-design.md.
    systemd.services.eleventy = {
      description = "Alice collection site builder (memex2 / Eleventy, watch mode)";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        WorkingDirectory = cfg.checkout;
        # Invoke Eleventy's entry point directly rather than through `npx`. npx adds package
        # resolution, a writable cache, and possible registry lookups — none of which we want in a
        # systemd unit, and all of which can fail before Eleventy even starts. (It did: npx exited
        # 254 on the first real install, while Eleventy itself only ever exits 0 or 1.)
        # cmd.cjs is the `bin.eleventy` entry from @11ty/eleventy's package.json.
        ExecStart =
          "${pkgs.nodejs}/bin/node ${cfg.checkout}/node_modules/@11ty/eleventy/cmd.cjs"
          + " --watch --output ${cfg.outputPath}";
        User = cfg.user;
        Restart = "on-failure";
        RestartSec = 5;
      };
      # Eleventy and its plugins expect a writable HOME; the checkout is the natural choice since
      # the service already owns it.
      environment.HOME = cfg.checkout;
    };

    # Both directories are written by the attendant's tooling (Eleventy writes the site, the
    # memex2 CLI writes manifests into the library) and only read by nginx. A freshly formatted
    # disk mounted at libraryPath is root-owned, so this fixes ownership at boot — after
    # local-fs.target, so it applies to the mount rather than the mountpoint underneath it.
    systemd.tmpfiles.rules = [
      "d ${cfg.libraryPath} 0755 ${cfg.user} users -"
      "d ${cfg.outputPath} 0755 ${cfg.user} users -"
    ];
  };
}
