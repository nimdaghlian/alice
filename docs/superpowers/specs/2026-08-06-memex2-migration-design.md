# memex2 Migration — Design

Alice currently plans to run make-gals (a Node CLI) feeding a Jekyll site. Both are being replaced by `memex2` (`~/dev/memex2`), a single repo combining a cataloging CLI (`memex process|tag|update|verify`) and an Eleventy site that builds its output. This spec covers the NixOS/install-side changes needed to run memex2 on Alice in place of make-gals + Jekyll, plus a new `http://alice` local hostname for the served site.

## Goals

- Replace Jekyll with Eleventy (`memex2`'s bundled `eleventy.config.js`) as the site builder
- Replace make-gals with memex2's CLI (`memex process`) behind the existing `make-gallery` alias
- Serve the site at `http://alice` (no port) to visitors on Alice's WiFi
- Serve the (potentially large) `site/library` media directory directly from its source location, never copied — see "Serving architecture" below
- Keep memex2 as a live git checkout (like make-gals today) — its CLI writes generated content (`manifest.json`, Records, Collections) back into its own working tree, which doesn't fit a read-only Nix store derivation

## Non-goals

- Packaging memex2 as a Nix derivation (`buildNpmPackage`) — explicitly rejected; see Goals
- Any OP/Octothorpes network integration (memex2's own roadmap, not Alice's concern)
- Asset-drive / second-drive mount config (`drives.nix`) — out of scope; memex2's default `library: ./site/library` (inside the checkout, gitignored, Syncthing-shared) is used as-is
- Auth for cloning memex2 — the repo will be public before install; if it's still private at install time, the admin clones manually via a pre-authenticated machine and copies the checkout over. No deploy-key infra is being built.
- Captive portal, mDNS/avahi for `alice.local` — unrelated/already-tracked future items

## Serving architecture — why nginx is back

An earlier revision of this spec ran `eleventy --serve` directly as the systemd service, deliberately avoiding nginx. That's been reversed after confirming a real problem, not a hypothetical one.

**Confirmed against the installed Eleventy source** (`~/dev/memex2/node_modules/@11ty/eleventy` v3.1.6): Eleventy's passthrough-copy-for-free behavior (serving passthrough files straight from source, no copy) is gated to `runMode === "serve"` only (`Util/PassthroughCopyBehaviorCheck.js`, comment: *"False when runMode is 'build' or 'watch'"*), and `cmd.cjs` sets `runMode: argv.serve ? "serve" : argv.watch ? "watch" : "build"`. So `--watch` alone does a real `recursive-copy` of the entire passthrough set — including `site/library` — into `_site/library` on **every** rebuild. For a large, growing media library this is slow and wasteful, and `--watch` (not `--serve`) is what the curator needs for live-reload during cataloging.

**New architecture:** stop using Eleventy's own dev server as the production frontend. Instead:

- `eleventy --watch` runs as a systemd service — build-only, no bundled server, regenerates `_site/` (HTML only) on change
- `nginx` is the single listener on port 80, with two roots under one origin:
  - `/` → `/home/gallery/memex2/_site` (Eleventy's build output)
  - `/library/` → **`alias`** straight to `/home/gallery/memex2/site/library/` (the source directory, not a build artifact)
- Because both roots share nginx's one origin, `/library/...` URLs already emitted by memex2's templates (`libraryPrefix = "/library/"` in `site/_data/site.json`) resolve identically in dev and production — no template changes needed
- The library is never copied, not even once, at any point in this pipeline

**Cross-repo coordination required:** `eleventy.config.js`'s `addPassthroughCopy({ 'site/library': 'library' })` line must be removed in the memex2 repo — otherwise a `build`-mode run (e.g. a one-off `eleventy` invocation, or if `--serve` is ever used again for local preview) still copies the library once. This is a memex2-repo change, not an Alice-repo change; it's called out here so it isn't missed, but isn't part of the "Files touched" list below.

## Components

### 1. `nixos/hosts/alice/default.nix` — package swap

Remove `jekyll` from `environment.systemPackages`; add `nodejs` (bundles `npm`). `git`, `vim`, `curl`, `wget` are unaffected — `git` is what clones memex2 during install.

### 2. `nixos/modules/eleventy.nix` (new, replaces the never-built `jekyll.nix` sketch)

A systemd service running Eleventy in build-only watch mode against the memex2 checkout — no bundled server, no port binding:

- `description = "Alice collection site builder (memex2 / Eleventy, watch mode)"`
- `WorkingDirectory = "/home/gallery/memex2"`
- `ExecStart = "${pkgs.nodejs}/bin/npx eleventy --watch"` (memex2's own `package.json` already depends on `@11ty/eleventy`; running through the checkout's local `node_modules` via `npx` avoids needing a global/Nix-packaged Eleventy)
- `User = "gallery"`, `Group = "users"`
- `Restart = "on-failure"`, `wantedBy = [ "multi-user.target" ]`, `after = [ "network.target" ]`
- No `AmbientCapabilities` needed — this service never binds a network port; nginx (below) is what listens on 80

### 3. `nixos/modules/nginx.nix` (new)

The production HTTP frontend, replacing what would otherwise have been Eleventy's own dev server:

```nix
services.nginx = {
  enable = true;
  virtualHosts."alice" = {
    default = true;
    locations."/" = {
      root = "/home/gallery/memex2/_site";
    };
    locations."/library/" = {
      alias = "/home/gallery/memex2/site/library/";
    };
  };
};
```

`default = true` so it answers regardless of whether the request's Host header is `alice`, `10.0.0.1`, or something else — visitors reach it the same way whether DNS resolved or they typed the raw gateway IP. NixOS's `services.nginx` module runs its own systemd unit and already binds port 80 without any extra capability wiring on our part.

### 4. `nixos/modules/aliases.nix` — updated aliases

- `make-gallery` — currently just `wifi-qr`. Add a second `writeShellScriptBin`: `node /home/gallery/memex2/bin/memex.js process "$@"`, forwarding all arguments through exactly as memex2's own CLI expects (directory argument, any flags).
- `gallery-status` — new alias/script: reports `systemctl is-active hostapd`, `systemctl is-active dnsmasq`, `systemctl is-active eleventy`, and `systemctl is-active nginx` in one plain-English summary (replaces the "Jekyll status" line implied by the docs table before either alias existed).
- `restart-site` — new alias: `systemctl restart eleventy` (was going to target `jekyll`). Does not restart `nginx` — that only needs restarting if its own config changes, which attendant workflow never touches.

These three were listed in `docs/alice.md`'s Bash Aliases Reference table before any alias module existed; this is where they actually get built, alongside the already-shipped `wifi-qr`.

### 5. `nixos/modules/wifi-ap.nix` — `alice` hostname

Add to the existing `services.dnsmasq.settings` block (already `enable`d and configured for `10.0.0.0/24` from the WiFi AP work):

```nix
"address" = [ "/alice/10.0.0.1" ];
```

Clients already use Alice's dnsmasq as their DNS server (`dhcp-option = [ "3,10.0.0.1" "6,10.0.0.1" ]` is already set), so this resolves `alice` → `10.0.0.1` for anyone on the WiFi with no further client-side config. Visitors type `http://alice` (explicit scheme recommended — a bare `alice` in some browsers' address bars gets treated as a search query rather than a hostname, since it has no dot; typing the full `http://` prefix sidesteps that ambiguity).

### 6. Install docs (`docs/alice.md`)

- **Software Stack table**: replace the Jekyll and make-gals rows with a single memex2 row.
- **Attendant Workflow**: `make-gallery` step description changes from "generates one MD file per asset and one MD file for the gallery" to memex2's actual output (Records + a baseline Collection); "The Jekyll site updates automatically" → "The site updates automatically" (Eleventy, not Jekyll).
- **Network Setup**: gateway/site URL line changes from `http://10.0.0.1` (or `http://alice.local`) to `http://alice` (or `http://10.0.0.1`).
- **Installation steps**: new step between the WiFi credentials step (5b) and Install (6) — clone memex2, `npm install`, seed `memex.config.yml` from its own `.example` file, set `memexId`. (Mirrors the WiFi-credentials pattern already established, but this example file lives in the memex2 repo itself, not Alice's — Alice's docs just document running the copy step, not committing a second example file into this repo.)
- **Bash Aliases Reference table**: descriptions updated to say memex2/Eleventy instead of make-gals/Jekyll.
- **Custom Nix Packages table**: remove the "Custom Jekyll site" and "make-gals" rows (superseded — memex2 isn't going to be Nix-packaged per the Non-goals above); this section's premise (package as a flake input) no longer applies to memex2, so the table note should say so explicitly rather than leaving stale TBD rows.
- **Planned modules list**: `jekyll.nix` entry becomes `eleventy.nix` (implemented).

## Data flow

```
attendant copies media → asset dir inside site/library (memex2 checkout, gitignored)
  → `make-gallery <dir>` (→ memex process <dir>) hashes assets, writes manifest.json
    + Records/Collections .md under memex2's site/
      → attendant edits .md in Obsidian (unchanged workflow)
        → eleventy --watch (systemd) detects the change, rebuilds _site/ (HTML only,
          library never copied)
          → nginx serves _site/ at "/" and site/library/ directly at "/library/"
            → visitor on Alice's WiFi opens http://alice → sees the update
```

## Error handling

- Missing `node_modules` (install step skipped) → `eleventy` service fails to start; surfaced via `gallery-status` / `systemctl status eleventy`, same pattern as the `hostapd` failure mode from the WiFi work.
- Missing/incomplete `memex.config.yml` (no `memexId`) → the CLI's own `requireMemexId` check throws with a clear message when `make-gallery` is run; no Nix-side handling needed.
- nginx misconfiguration or port 80 already in use → `nginx` service fails to start, surfaced via `gallery-status` / `systemctl status nginx`.
- memex2 repo not updated to remove the `site/library` passthrough copy → harmless at runtime (nginx's `/library/` alias still serves correctly), but a one-time `_site/library` copy will exist on disk after any `build`-mode Eleventy run; not a correctness bug, just wasted disk space until the memex2-side fix lands.

## Testing

- `nix flake check` / dry-build on a Nix-capable machine (still unavailable on this dev Mac, same caveat as the WiFi work — run wherever Nix is installed)
- On real hardware: run `make-gallery <test-dir>`, confirm Records appear under memex2's `site/`, confirm `eleventy --watch` rebuilds `_site/` and nginx serves the update
- From a second device joined to Alice's WiFi: visit `http://alice`, confirm it loads without a port number; confirm an image/media link under `/library/...` loads correctly (proves the nginx alias, not just the HTML root, is working)
- Confirm `_site/library` does **not** exist (or stays empty) after repeated `make-gallery` runs and rebuilds — this is the actual regression test for the problem this redesign fixes
- `gallery-status` reports all four services (`hostapd`, `dnsmasq`, `eleventy`, `nginx`) correctly when healthy, and clearly when one is down (e.g. stop `eleventy` manually and confirm the alias says so)

## Files touched

- `nixos/hosts/alice/default.nix` (modify — swap `jekyll` for `nodejs` in systemPackages)
- `nixos/modules/eleventy.nix` (new — `eleventy --watch` build service)
- `nixos/modules/nginx.nix` (new — serves `_site/` and `site/library/` on port 80)
- `nixos/modules/aliases.nix` (modify — add `make-gallery`, `gallery-status`, `restart-site`)
- `nixos/modules/wifi-ap.nix` (modify — add `alice` dnsmasq address mapping)
- `docs/alice.md` (modify — Software Stack, Attendant Workflow, Network Setup, Installation, Bash Aliases Reference, Custom Nix Packages, Planned modules)
- **Not in this repo:** `eleventy.config.js` in `~/dev/memex2` — remove the `site/library` passthrough copy (see "Serving architecture" above)
