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
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "gallery";
      description = "User that owns the memex2 checkout and runs the site builder.";
    };
  };

  config = {
    # Build-only watch mode: regenerates _site/ on change and nothing else. Deliberately NOT
    # `--serve` — Eleventy's dev server is not the production frontend here (nginx is), and
    # under `--watch` Eleventy would otherwise re-copy the whole media library on every rebuild.
    # See docs/superpowers/specs/2026-08-06-memex2-migration-design.md, "Serving architecture".
    systemd.services.eleventy = {
      description = "Alice collection site builder (memex2 / Eleventy, watch mode)";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        WorkingDirectory = cfg.checkout;
        # Runs Eleventy from the checkout's own node_modules (installed by `npm install` during
        # setup), so no globally packaged Eleventy is needed.
        ExecStart = "${pkgs.nodejs}/bin/npx eleventy --watch";
        User = cfg.user;
        Restart = "on-failure";
        RestartSec = 5;
      };
      # npx needs a writable HOME for its cache; without this it fails under systemd.
      environment.HOME = cfg.checkout;
    };
  };
}
