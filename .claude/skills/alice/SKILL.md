---
name: alice
description: >
  Use when working on Alice — the NixOS gallery kiosk in ~/dev/alice. Covers the NixOS flake and its
  modules (wifi-ap, settings, eleventy, nginx, aliases), the hostapd/dnsmasq WiFi access point and QR
  join code, the memex2 CLI + Eleventy site that replaced make-gals and Jekyll, the serving layout
  (/srv/library on its own disk, /srv/www/alice as build output, nginx as the only server), the
  attendant workflow and bash aliases, and the install procedure. Also use for questions about what on
  Alice is actually built versus only designed.
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
| `gnome.nix` (autologin/kiosk hardening) | **Not built** |
| memex2 external library mode | **Shipped and tested in the memex2 repo.** Alice depends on it — see Serving architecture. |
| Preview mode (live-reload editing on `:8081`) | **Spec'd, deliberately not built** — `docs/superpowers/specs/2026-08-11-preview-mode-design.md`. Deferred until the base install works. |

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
syntax, whether `npx` works under systemd with `HOME` set to the checkout, and whether Eleventy
accepts an absolute `--output` outside the project directory (the flag itself is confirmed —
`cmd.cjs:80` passes it as the constructor's second arg — but an out-of-project target is not).

The nginx-can't-read-`/home` question is **resolved**, not pending: it was `ProtectHome`, and
building into `/srv/www/alice` sidesteps it. Any advice about `chmod 755 /home/gallery` is obsolete
and was wrong anyway — permissions can't defeat a mount namespace.

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

## Serving architecture

Three locations, one web server, no copy steps anywhere:

```
/home/gallery/memex2   memex2 checkout — SOURCE only
/srv/library           media library, own NVMe      → nginx serves at /library/
/srv/www/alice         eleventy --watch --output    → nginx serves at /
```

Eleventy is a **builder, not a server** here: `eleventy --watch --output /srv/www/alice`. nginx is
the only listener. Built, in `modules/eleventy.nix` and `modules/nginx.nix`; paths are the
`alice.site.{checkout,libraryPath,outputPath}` options.

Three constraints forced this shape. Each was verified in source, not assumed — and each looks like
an arbitrary path choice until you know the reason, so don't "simplify" any of them away:

**1. Alice always uses memex2's external library mode.** Eleventy's copy-free passthrough is gated to
`runMode === "serve"` (`Util/PassthroughCopyBehaviorCheck.js`, v3.1.6: *"False when runMode is 'build'
or 'watch'"*). Under `--watch` it does a real `recursive-copy` of the whole library every rebuild.
Eleventy also refuses a passthrough source outside the project directory, so a library on its own
disk cannot work in embedded mode at all. memex2's `library:` must equal `alice.site.libraryPath`.

**2. Nothing nginx serves may live under `/home`.** NixOS 25.05 sets `ProtectHome = mkDefault true`
on nginx's systemd unit — a mount-namespace block, so `/home` appears *empty* to the service and no
`chmod`/group change can defeat it. Hence `--output /srv/www/alice` rather than the checkout's
`_site`. (An earlier revision worked around this with `ProtectHome = mkForce false`; building into
`/srv` removed the need and the stock hardening is now intact.)

**3. Root-relative asset URLs resolve against the page's origin.** Records emit `/library/...`, so
any server other than nginx that renders those pages must be on the same origin or the images 404.
This is why preview mode is designed as an nginx proxy rather than a standalone dev server.

## Attendant workflow

The attendant never needs raw Unix commands — everything is a named bash alias with a plain-English
purpose.

1. Copy media into `/srv/library/<gallery-name>/` (the NVMe, not the checkout)
2. Run `make-gallery /srv/library/<gallery-name>` → wraps `memex process`, which hashes assets and
   writes `manifest.json` beside them, plus Record/Collection `.md` into the checkout
3. Edit the generated `.md` in Obsidian — titles, descriptions, tags
4. `eleventy --watch` rebuilds into `/srv/www/alice`; refresh the browser to see it. There is no
   live reload — that's preview mode, spec'd but not built.

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
  modules/eleventy.nix             # eleventy --watch --output; declares alice.site.*
  modules/nginx.nix                # /srv/www/alice at /, /srv/library at /library/
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

Where assets live is **resolved**: a dedicated 1TB NVMe mounted at `/srv/library`, with memex2 in
external mode. Earlier docs describing a library inside the checkout, or an undecided second drive,
are superseded.

Nothing else is open at the design level. What remains is empirical — whether the config actually
evaluates and boots, which the first install answers.

## Conventions

- Native systemd units — no Docker, no Coolify
- Services that need a secret read it from a runtime file; they never take it as a Nix option
- Attendant-facing operations get a documented alias
- Design specs land in `docs/superpowers/specs/`, plans in `docs/superpowers/plans/`
- Verification claims require actually running the command — the flake's unvalidated state above is
  the standing example of what happens otherwise
