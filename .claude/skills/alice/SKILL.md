---
name: alice
description: >
  Use when working on Alice — the NixOS gallery kiosk in ~/dev/alice. Covers the NixOS flake and its
  modules (wifi-ap, aliases, eleventy), the hostapd/dnsmasq WiFi access point and QR join code, the
  memex2 CLI + Eleventy site that replaced make-gals and Jekyll, the attendant workflow and bash
  aliases, and the install procedure. Also use for questions about what on Alice is actually built
  versus only designed.
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
| WiFi AP (`nixos/modules/wifi-ap.nix`) | **Implemented**, committed — never validated by Nix (see below) |
| `wifi-qr` alias (`nixos/modules/aliases.nix`) | **Implemented**, committed — never validated by Nix |
| Example WiFi credentials file | **Implemented**, committed |
| memex2 migration (Eleventy, `memex process`, `http://alice`) | **Spec only** — `docs/superpowers/specs/2026-08-06-memex2-migration-design.md`. No code written. |
| `make-gallery`, `gallery-status`, `restart-site` aliases | **Not built** — listed in `docs/alice.md`'s table, but `aliases.nix` contains only `wifi-qr` |
| `eleventy.nix` module | **Not built** |
| `gnome.nix`, `drives.nix` | **Not built** |

**Nothing in `nixos/` has ever been evaluated by Nix.** The dev machine is a Mac with no `nix`
installed, so `nix flake check` and every build/eval step have been skipped throughout. Treat the
whole flake as unverified — syntax errors, wrong option names, and bad module merges are all still
live possibilities. Run `nix flake check` from `nixos/` on a Nix-capable machine before trusting any
of it. Eval works fine cross-platform from macOS if Nix is installed; a full build needs Linux.

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

**Tailscale is no longer part of Alice.** `docs/alice.md` still lists it and still tells you to
verify with `ssh gallery@alice.ts.net` — that is stale.

## memex2 deployment model

memex2 is deliberately **not** a Nix derivation. Its CLI writes generated content (`manifest.json`,
Records, Collections) back into its own working tree, which the read-only Nix store can't support.
It is a live git checkout at `/home/gallery/memex2` plus a one-time `npm install`, exactly like
make-gals was. Nix's job is only to provide `nodejs`, run the systemd service, and point aliases at
the checkout.

If someone proposes `buildNpmPackage` for memex2, that was considered and rejected for this reason.

## Attendant workflow

The attendant never needs raw Unix commands — everything is a named bash alias with a plain-English
purpose.

1. Copy media into a gallery directory
2. Run `make-gallery <dir>` → wraps `memex process`, which hashes assets and writes `manifest.json`
   plus Record/Collection `.md` files
3. Edit the generated `.md` in Obsidian — titles, descriptions, tags
4. The site rebuilds and re-serves automatically; no further action

| Alias | Does | Built? |
|---|---|---|
| `wifi-qr` | Writes `/home/gallery/wifi-qr.png` from the credentials file | yes |
| `make-gallery` | `memex process` on a gallery directory | no |
| `gallery-status` | Health of `hostapd`, `dnsmasq`, `eleventy` | no |
| `restart-site` | Restart the Eleventy service | no |
| `update-system` | Pull config, `nixos-rebuild switch` | no |

## Network

Isolated AP, no public exposure. Visitors scan a printed QR code to join, then browse.

- Gateway `10.0.0.1`, subnet `10.0.0.0/24`, DHCP pool `.50`–`.150`
- Clients are handed Alice as their DNS server, so dnsmasq can answer for local names
- Target URL is **`http://alice`** (spec'd, not built — needs an `address=/alice/10.0.0.1` dnsmasq
  entry plus Eleventy binding port 80 via `CAP_NET_BIND_SERVICE`). `alice.local` in `docs/alice.md`
  is stale — no mDNS/avahi is configured.
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
  flake.nix                        # nixpkgs 25.05; mkAlice helper, one entry per machine
  hosts/alice/default.nix          # shared config for all Alice units
  hosts/alice/wifi-credentials.example
  hosts/alice-1/hardware-configuration.nix   # per-machine, committed
  modules/wifi-ap.nix              # hostapd + dnsmasq
  modules/aliases.nix              # attendant aliases
docs/alice.md                      # main doc — PARTLY STALE, see below
docs/superpowers/specs/            # design specs
docs/superpowers/plans/            # implementation plans
```

Each physical unit gets its own `hosts/alice-N/` with a committed `hardware-configuration.nix`;
`hosts/alice/default.nix` is shared across all of them. Config is split into `nixos/modules/*.nix`
as it grows.

## Known-stale content in docs/alice.md

`docs/alice.md` is the main human-facing doc and has not been updated for the memex2 migration.
Do not treat it as current on:

- Jekyll and make-gals (both replaced by memex2)
- Tailscale (dropped) and the `ssh gallery@alice.ts.net` verify step
- `http://alice.local` (no mDNS; the target is `http://alice`)
- The aliases table, which lists aliases that don't exist yet
- The "Custom Nix Packages" table, whose Jekyll/make-gals rows are obsolete

The memex2 spec lists the specific edits needed. Fixing this doc is outstanding work.

## Open questions

- **Where assets actually live.** `docs/alice.md` describes a second internal drive for audio/video,
  but the memex2 spec puts the asset library inside the checkout (`site/library`) on the system
  drive so Eleventy can serve it. These conflict and it is undecided. Ask before writing anything
  that depends on the answer; don't assume either layout.
- Whether Eleventy's dev server binds all interfaces or only loopback — unconfirmed. If it's
  loopback-only, the fix belongs in memex2's own `eleventy.config.js`, not Alice's Nix config.

## Conventions

- Native systemd units — no Docker, no Coolify
- Services that need a secret read it from a runtime file; they never take it as a Nix option
- Attendant-facing operations get a documented alias
- Design specs land in `docs/superpowers/specs/`, plans in `docs/superpowers/plans/`
- Verification claims require actually running the command — the flake's unvalidated state above is
  the standing example of what happens otherwise
