# memex2 Migration — Design

Alice currently plans to run make-gals (a Node CLI) feeding a Jekyll site. Both are being replaced by `memex2` (`~/dev/memex2`), a single repo combining a cataloging CLI (`memex process|tag|update|verify`) and an Eleventy site that builds its output. This spec covers the NixOS/install-side changes needed to run memex2 on Alice in place of make-gals + Jekyll, plus a new `http://alice` local hostname for the served site.

## Goals

- Replace Jekyll with Eleventy (`memex2`'s bundled `eleventy.config.js`) as the systemd-managed site service
- Replace make-gals with memex2's CLI (`memex process`) behind the existing `make-gallery` alias
- Serve the site at `http://alice` (no port) to visitors on Alice's WiFi, via dnsmasq + a low-port-binding systemd service
- Keep memex2 as a live git checkout (like make-gals today) — its CLI writes generated content (`manifest.json`, Records, Collections) back into its own working tree, which doesn't fit a read-only Nix store derivation

## Non-goals

- Packaging memex2 as a Nix derivation (`buildNpmPackage`) — explicitly rejected; see Goals
- Any OP/Octothorpes network integration (memex2's own roadmap, not Alice's concern)
- Asset-drive / second-drive mount config (`drives.nix`) — out of scope; memex2's default `library: ./site/library` (inside the checkout, gitignored, Syncthing-shared) is used as-is
- Auth for cloning memex2 — the repo will be public before install; if it's still private at install time, the admin clones manually via a pre-authenticated machine and copies the checkout over. No deploy-key infra is being built.
- Captive portal, mDNS/avahi for `alice.local` — unrelated/already-tracked future items

## Components

### 1. `nixos/hosts/alice/default.nix` — package swap

Remove `jekyll` from `environment.systemPackages`; add `nodejs` (bundles `npm`). `git`, `vim`, `curl`, `wget` are unaffected — `git` is what clones memex2 during install.

### 2. `nixos/modules/eleventy.nix` (new, replaces the never-built `jekyll.nix` sketch)

A systemd service running Eleventy's dev server against the memex2 checkout:

- `description = "Alice collection site (memex2 / Eleventy)"`
- `WorkingDirectory = "/home/gallery/memex2"`
- `ExecStart = "${pkgs.nodejs}/bin/npx eleventy --serve --port=80"` (memex2's own `package.json` already depends on `@11ty/eleventy`; running through the checkout's local `node_modules` via `npx` avoids needing a global/Nix-packaged Eleventy)
- `User = "gallery"`, `Group = "users"`
- `AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ]` and `CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ]` — lets the service bind port 80 without running as root
- `Restart = "on-failure"`, `wantedBy = [ "multi-user.target" ]`, `after = [ "network.target" ]`

**Open verification item (not a blocker, a test step):** whether `@11ty/eleventy-dev-server` binds all interfaces by default or only loopback isn't confirmed from reading `eleventy.config.js` (no explicit `setServerOptions` call is present, so it's using the library default). Task 6/testing must confirm the site is reachable from a second device on `10.0.0.0/24`, not just `localhost` on the kiosk itself. If it turns out to bind loopback-only, the fix is a `--server.hostname=0.0.0.0`-equivalent CLI flag or an `eleventyConfig.setServerOptions({ hostname: '0.0.0.0' })` change — but that change would need to land in the memex2 repo, not Alice's, since it's the site's own dev-server config. Flagging here so it isn't mistaken for an Alice-side Nix bug if it comes up.

### 3. `nixos/modules/aliases.nix` — updated aliases

- `make-gallery` — currently just `wifi-qr`. Add a second `writeShellScriptBin`: `node /home/gallery/memex2/bin/memex.js process "$@"`, forwarding all arguments through exactly as memex2's own CLI expects (directory argument, any flags).
- `gallery-status` — new alias/script: reports `systemctl is-active hostapd`, `systemctl is-active dnsmasq`, and `systemctl is-active eleventy` in one plain-English summary (replaces the "Jekyll status" line implied by the docs table before either alias existed).
- `restart-site` — new alias: `systemctl restart eleventy` (was going to target `jekyll`).

These three were listed in `docs/alice.md`'s Bash Aliases Reference table before any alias module existed; this is where they actually get built, alongside the already-shipped `wifi-qr`.

### 4. `nixos/modules/wifi-ap.nix` — `alice` hostname

Add to the existing `services.dnsmasq.settings` block (already `enable`d and configured for `10.0.0.0/24` from the WiFi AP work):

```nix
"address" = [ "/alice/10.0.0.1" ];
```

Clients already use Alice's dnsmasq as their DNS server (`dhcp-option = [ "3,10.0.0.1" "6,10.0.0.1" ]` is already set), so this resolves `alice` → `10.0.0.1` for anyone on the WiFi with no further client-side config. Visitors type `http://alice` (explicit scheme recommended — a bare `alice` in some browsers' address bars gets treated as a search query rather than a hostname, since it has no dot; typing the full `http://` prefix sidesteps that ambiguity).

### 5. Install docs (`docs/alice.md`)

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
        → eleventy systemd service picks up the change, rebuilds, serves live
          → visitor on Alice's WiFi opens http://alice → sees the update
```

## Error handling

- Missing `node_modules` (install step skipped) → `eleventy` service fails to start; surfaced via `gallery-status` / `systemctl status eleventy`, same pattern as the `hostapd` failure mode from the WiFi work.
- Missing/incomplete `memex.config.yml` (no `memexId`) → the CLI's own `requireMemexId` check throws with a clear message when `make-gallery` is run; no Nix-side handling needed.
- Port 80 bind failure (capability misconfigured) → service fails to start, same `systemctl status eleventy` visibility.

## Testing

- `nix flake check` / dry-build on a Nix-capable machine (still unavailable on this dev Mac, same caveat as the WiFi work — run wherever Nix is installed)
- On real hardware: run `make-gallery <test-dir>`, confirm Records appear under memex2's `site/`, confirm `eleventy` rebuilds and serves them
- From a second device joined to Alice's WiFi: visit `http://alice`, confirm it loads without a port number and without going through `10.0.0.1` directly — this is also where the dev-server bind-address open item gets resolved one way or the other
- `gallery-status` reports all three services (`hostapd`, `dnsmasq`, `eleventy`) correctly when healthy, and clearly when one is down (e.g. stop `eleventy` manually and confirm the alias says so)

## Files touched

- `nixos/hosts/alice/default.nix` (modify — swap `jekyll` for `nodejs` in systemPackages)
- `nixos/modules/eleventy.nix` (new)
- `nixos/modules/aliases.nix` (modify — add `make-gallery`, `gallery-status`, `restart-site`)
- `nixos/modules/wifi-ap.nix` (modify — add `alice` dnsmasq address mapping)
- `docs/alice.md` (modify — Software Stack, Attendant Workflow, Network Setup, Installation, Bash Aliases Reference, Custom Nix Packages, Planned modules)
