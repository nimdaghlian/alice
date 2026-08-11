---
name: alice
description: >
  Use when working on Alice — the NixOS gallery kiosk in ~/dev/alice. Covers the NixOS flake and its
  modules (wifi-ap, aliases, eleventy, nginx), the hostapd/dnsmasq WiFi access point and QR join code,
  the memex2 CLI + Eleventy site that replaced make-gals and Jekyll, the nginx + eleventy --watch
  serving split (avoids duplicating the media library), the attendant workflow and bash aliases, and
  the install procedure. Also use for questions about what on Alice is actually built versus only
  designed.
---

# Alice

Art gallery kiosk on a ThinkCentre M710q running NixOS + GNOME, managed day-to-day by a
non-technical attendant. Visitors join Alice's own WiFi network and browse the gallery's digital
collection in a browser. Alice serves nothing to the public internet.

Alice is part of a larger machine fleet — for the homelab server (bonbon), Coolify/Docker services,
The Well, or Tailscale-based inter-machine networking, use the `bonbon-homelab` skill instead. Alice
does not use Docker or Coolify; everything runs as native NixOS systemd units.

## Build status — read this first

The repo contains committed design specs for work that is **not implemented**. Check status here
before assuming a feature exists.

| Area | Status |
|---|---|
| WiFi AP (`modules/wifi-ap.nix`) — hostapd, dnsmasq, firewall | **Implemented**, committed — never validated by Nix (see below) |
| Preferences (`config.nix` + `modules/settings.nix`) | **Implemented** — timezone/locale/galleryName, shared with per-unit override |
| Site builder (`modules/eleventy.nix`) + web server (`modules/nginx.nix`) | **Implemented** |
| All five attendant aliases (`modules/aliases.nix`) | **Implemented** |
| Example WiFi credentials file | **Implemented**, committed |
| `gnome.nix` (autologin/kiosk hardening), `drives.nix` | **Not built** |
| memex2 "external library mode" | **Spec'd in the memex2 repo** (`docs/specs/2026-08-10-external-library-mode-design.md`), implementation in progress there. Adds `libraryMode`/`libraryUrl` config. Alice switches to `external` once it lands. |

**Nothing has been installed on real hardware yet.** The whole config is pre-first-boot.

**Nothing in `nixos/` has ever been evaluated by Nix.** The dev machine is a Mac with no `nix`
installed, so `nix flake check` and every build/eval step have been skipped throughout. Treat the
whole flake as unverified — syntax errors, wrong option names, and bad module merges are all still
live possibilities. Eval works fine cross-platform from macOS if Nix is installed; a full build
needs Linux.

**And `flake check` cannot fully succeed yet regardless**, because `hosts/alice-1/hardware-configuration.nix`
is still a stub with no `fileSystems."/"` — NixOS can't build a system without a root filesystem, so
eval dies there before reaching the real config. It gets replaced by `nixos-generate-config` during
install. To validate earlier, temporarily add a dummy `fileSystems."/"` and check that. Practically:
expect a few edit-and-retry cycles during the first `nixos-install`.

Highest-risk unverified guesses, in rough order: `services.dnsmasq.settings` schema, the
`networking.firewall.interfaces.<iface>` option path, NetworkManager's `interface-name:` unmanaged
syntax, whether `npx` works under systemd with `HOME` set to the checkout, and whether nginx can
traverse `/home/gallery` to reach the site (the `users.users.nginx.extraGroups` line in `nginx.nix`
is an attempt at that, and may need `755` on the home directory instead).

## Software stack

| Component | Role |
|---|---|
| NixOS (flake, nixpkgs 25.05) | OS, declarative config |
| GNOME | Desktop for the attendant; logs in as the `gallery` user |
| memex2 | Node CLI + Eleventy site — catalogs assets and serves the collection |
| Obsidian | Attendant edits generated Markdown on the machine |
| hostapd + dnsmasq | Alice's own WiFi network (AP mode, DHCP, DNS) |

**memex2 replaced both make-gals and Jekyll.** Any reference to Jekyll or make-gals is stale. memex2
lives at `~/dev/memex2` (separate repo, private at time of writing, expected to go public). It is
one repo containing both a CLI (`memex process|tag|update|verify`) and the Eleventy site that builds
the CLI's output.

**Tailscale is no longer part of Alice.** Remote admin is plain SSH over whatever network Alice is
on. If you see Tailscale mentioned anywhere, it's stale.

## memex2 deployment model

memex2 is deliberately **not** a Nix derivation. Its CLI writes generated content (`manifest.json`,
Records, Collections) back into its own working tree, which the read-only Nix store can't support.
It is a live git checkout at `/home/gallery/memex2` plus a one-time `npm install`, exactly like
make-gals was. Nix's job is only to provide `nodejs`, run the systemd service, and point aliases at
the checkout.

If someone proposes `buildNpmPackage` for memex2, that was considered and rejected for this reason.

## Serving: nginx + eleventy --watch, not eleventy --serve

Alice does **not** run Eleventy's own dev server (`--serve`) in production. Confirmed against
Eleventy's source (`~/dev/memex2/node_modules/@11ty/eleventy` v3.1.6,
`Util/PassthroughCopyBehaviorCheck.js`): Eleventy's no-copy passthrough behavior only applies when
`runMode === "serve"`. Under `--watch` (needed for the curator's live-reload while cataloging), every
rebuild does a real `recursive-copy` of passthrough content — including `site/library`, which can be
large — into `_site/library`. That's a real, sourced problem, not a guess.

The fix: `eleventy --watch` runs build-only (no server, no port), and `nginx` is the single listener
on port 80 with two roots — `/` → `_site/` (Eleventy's HTML output), `/library/` → an `alias`
straight to `site/library/` (the source, never copied). See
`docs/superpowers/specs/2026-08-06-memex2-migration-design.md`'s "Serving architecture" section for
the full rationale. Built, in `modules/eleventy.nix` and `modules/nginx.nix`.

**Cross-repo dependency:** memex2's `eleventy.config.js` still has
`addPassthroughCopy({ 'site/library': 'library' })`, which needs removing there — an Alice-side nginx
config doesn't undo that. That edit belongs in `~/dev/memex2`, not here.

## Attendant workflow

The attendant never needs raw Unix commands — everything is a named bash alias with a plain-English
purpose.

1. Copy media into a gallery directory
2. Run `make-gallery <dir>` → wraps `memex process`, which hashes assets and writes `manifest.json`
   plus Record/Collection `.md` files
3. Edit the generated `.md` in Obsidian — titles, descriptions, tags
4. The site rebuilds and re-serves automatically; no further action

All five are built, in `modules/aliases.nix`:

| Alias | Does |
|---|---|
| `wifi-qr` | Writes `/home/gallery/wifi-qr.png` from the credentials file |
| `make-gallery <dir>` | `memex process` on a gallery directory |
| `gallery-status` | Plain-English health of `hostapd`, `dnsmasq`, `eleventy`, `nginx` |
| `restart-site` | Restart the Eleventy builder (not nginx — it serves whatever is on disk) |
| `update-system` | `git pull` in `alice.configRepo`, then rebuild `alice.unit` |

## Network

Isolated AP, no public exposure. Visitors scan a printed QR code to join, then browse.

- Gateway `10.0.0.1`, subnet `10.0.0.0/24`, DHCP pool `.50`–`.150`
- Clients are handed Alice as their DNS server, so dnsmasq can answer for local names
- Target URL is **`http://alice`**, via an `address=/alice/10.0.0.1` dnsmasq entry; the port-80
  listener is nginx, not Eleventy (see "Serving" above). There is no mDNS/avahi — `alice.local`
  will not work.
- DNS (53), DHCP (67), and HTTP (80) are firewalled to the AP interface only, so Alice is not an
  open resolver or web server on any other network it joins. Forgetting this is why an AP can look
  "broken" — clients associate but never get a lease.
- Visitors should type the full `http://alice`; a bare `alice` has no dot and some browsers treat it
  as a search query

### WiFi credentials — the one secret

SSID and password live **only** in `/etc/alice/wifi-credentials` on the machine (mode 600). Never in
git, never in the Nix store.

The store is world-readable, so passing the passphrase through a Nix option would leak it. Instead
both consumers read the file at runtime: `hostapd` gets its config rendered by an `ExecStartPre`
script into `/run/hostapd/hostapd.conf`, and `wifi-qr` reads the same file to build the QR payload.
`nixos/hosts/alice/wifi-credentials.example` is committed purely as an install-time template the
admin copies and edits in place.

Both consumers fail loudly with a pointer to `docs/alice.md` if the file is missing or incomplete —
no silent fallback to placeholder values.

## Repo layout

```
nixos/
  flake.nix                        # nixpkgs 25.05; mkAlice "alice-N", merges preferences
  config.nix                       # shared preferences (timezone/locale/galleryName)
  hosts/alice/default.nix          # shared config for all Alice units
  hosts/alice/wifi-credentials.example
  hosts/alice-1/hardware-configuration.nix   # per-machine, committed (STUB until generated)
  hosts/alice-1/config.nix         # optional per-unit preference overrides
  modules/settings.nix             # applies config.nix; declares alice.unit/configRepo
  modules/wifi-ap.nix              # hostapd + dnsmasq + AP firewall
  modules/eleventy.nix             # eleventy --watch build service
  modules/nginx.nix                # serves _site/ + site/library/ on :80
  modules/aliases.nix              # the five attendant commands
docs/alice.md                      # main doc — current as of the memex2 migration
docs/superpowers/specs/            # design specs
docs/superpowers/plans/            # implementation plans
```

Each physical unit gets its own `hosts/alice-N/` with a committed `hardware-configuration.nix`;
`hosts/alice/default.nix` is shared across all of them. Config is split into `nixos/modules/*.nix`
as it grows.

## Preferences

`nixos/config.nix` holds shared build-time preferences (`timezone`, `locale`, `galleryName`), a plain
Nix attrset. A unit overrides any subset by adding `hosts/alice-N/config.nix`; `flake.nix` merges
them (per-unit wins) and passes the result as `alice.settings`, applied by `modules/settings.nix`.

YAML was asked for but isn't viable — Nix has `fromJSON`/`fromTOML` but no YAML parser, and the IFD
workaround breaks under `nix flake check`.

Two related options live outside `alice.settings` because they're plumbing, not preferences:
`alice.unit` (the flake attribute name, set automatically by `flake.nix`, since hostname `alice` is
shared across units and can't identify one) and `alice.configRepo` (default `/etc/nixos`, the
on-machine clone `update-system` pulls from).

## Open questions

- **Where assets live long-term.** The media library currently sits inside the memex2 checkout on
  the system drive (`site/library`), which is what nginx's `/library/` alias points at. The
  second-drive idea from earlier docs is deferred, pending memex2's external library mode.

## Conventions

- Native systemd units — no Docker, no Coolify
- Services that need a secret read it from a runtime file; they never take it as a Nix option
- Attendant-facing operations get a documented alias
- Design specs land in `docs/superpowers/specs/`, plans in `docs/superpowers/plans/`
- Verification claims require actually running the command — the flake's unvalidated state above is
  the standing example of what happens otherwise
