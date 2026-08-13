# Alice

Art gallery kiosk running NixOS. Managed by a non-technical attendant. Visitors connect to Alice's WiFi and browse the gallery's digital collection at `http://alice`.

This document is the reference: hardware, architecture, and the attendant's workflow. Two companions
sit alongside it — [`README.md`](../README.md) for what must be configured by hand on each machine,
and [`install.md`](../install.md) for the step-by-step install walkthrough.

---

## Hardware

| | |
|---|---|
| **Model** | ThinkCentre M710q |
| **System drive** | ~400GB internal — OS, memex2 checkout, built site, Obsidian vault |
| **Library drive** | 1TB NVMe — the media library, mounted at `/srv/library` |
| **Network** | Built-in WiFi — runs in AP (access point) mode |

## Software Stack

| Component | What it does |
|---|---|
| NixOS (flake) | Operating system, declarative config |
| GNOME | Desktop environment for attendant |
| memex2 | Node.js CLI (catalogs assets) + Eleventy site (the collection browser) |
| Eleventy | Rebuilds the site whenever Records change (`--watch`, build only) |
| nginx | Serves the built site and the media library on port 80 |
| Obsidian | Attendant edits MD metadata files |
| hostapd + dnsmasq | Creates Alice's own WiFi network |
| SSH | Remote management by admin |

---

## Attendant Workflow

The attendant does not need to use a terminal for routine work. All terminal operations are available as named bash aliases with plain-English descriptions.

### Adding new assets

1. Copy media files into a gallery directory in the library: `/srv/library/<gallery-name>/`
2. Open Terminal and run `make-gallery /srv/library/<gallery-name>`
   - Catalogs the media: one Record per asset, plus one Collection for the directory
3. Open Obsidian and edit the generated MD files — add titles, descriptions, tags
4. The site updates automatically (no action needed)

### Starting up

- Power on Alice
- Log in as `gallery`
- The site builder and web server start automatically on boot — the collection is immediately live on the WiFi network

### Checking status

- Run `gallery-status` for a plain-English summary of the WiFi network, the site builder, and the web server

---

## Network Setup

Alice creates its own isolated WiFi network. It does **not** serve content over the internet.

- **SSID**: set in `/etc/alice/wifi-credentials` during install (see [`install.md`](../install.md))
- **Site URL**: `http://alice` (or `http://10.0.0.1`). Type the full `http://` — a bare `alice` has no dot, so some browsers treat it as a search term.
- **QR code**: Printed or displayed near the kiosk — encodes WiFi join credentials
- **Internet access**: Alice *can* connect to the internet (for updates) but does not expose the collection publicly. DNS, DHCP, and HTTP are firewalled to the AP interface only.
- **AP stack**: hostapd (access point) + dnsmasq (DHCP + DNS, and resolves `alice`)

Visitors: scan QR code → join network → open browser → collection site loads automatically (captive portal redirect, or manual navigation to the URL).

---

## Serving Architecture

One web server, no copy steps. Three locations, each with one job:

```
/home/gallery/memex2   memex2 checkout — SOURCE only (Records, templates, node_modules)
/srv/library           media library, on the NVMe   → nginx serves at /library/
/srv/www/alice         Eleventy builds directly here → nginx serves at /
```

Eleventy runs as a **builder, not a server**: `eleventy --watch --output /srv/www/alice`. It rebuilds
the HTML whenever a Record changes and writes straight into the directory nginx serves. nginx is the
only thing listening on a port.

Three decisions here are load-bearing, and each was forced rather than chosen:

**Alice always uses memex2's external library mode.** In embedded mode Eleventy passthrough-copies
the library into the build output — on every rebuild under `--watch`, since Eleventy's copy-free
passthrough only applies to `--serve`. At library scale that is untenable. Eleventy also refuses a
passthrough source outside the project directory, so a library on its own disk cannot work any other
way. memex2's `library:` setting must match `alice.site.libraryPath`.

**The build output lives outside the checkout.** NixOS sets `ProtectHome` on nginx's systemd unit,
making `/home` appear empty to the service no matter what the file permissions say. Serving the
checkout's `_site` would 404 every request. Building into `/srv/www/alice` keeps nginx out of `/home`
entirely and leaves the stock hardening intact.

**The library is never copied, anywhere.** nginx reads it in place from the NVMe via an `alias`. The
only thing that ever writes there is the memex2 CLI, adding `manifest.json` alongside the assets.

Live-reload editing (`http://alice:8081`) is designed but not built — see
`docs/superpowers/specs/2026-08-11-preview-mode-design.md`.

---

## NixOS Configuration

Config lives in `nixos/` at the root of this repo.

```
nixos/
  flake.nix                          # entry point, pins nixpkgs 25.05; one entry per machine
  config.nix                         # shared preferences (timezone, locale, gallery name)
  modules/
    settings.nix                     # applies config.nix values
    wifi-ap.nix                      # hostapd + dnsmasq
    eleventy.nix                     # memex2 site builder (watch mode)
    nginx.nix                        # serves built site + media library
    aliases.nix                      # attendant commands
  hosts/
    alice/
      default.nix                    # shared config for all Alice machines
      wifi-credentials.example       # install-time template
    alice-1/
      hardware-configuration.nix     # machine-specific, committed to repo
      config.nix                     # optional per-unit preference overrides
    alice-2/
      hardware-configuration.nix     # (future)
```

Each physical Alice unit gets its own numbered directory under `hosts/`. The shared system config (`hosts/alice/default.nix`) applies to all of them. To add a new machine, generate its hardware config and add a new entry to `flake.nix`.

### Preferences

`nixos/config.nix` holds settings you may want to change per install — timezone, locale, gallery name. To change one for a single unit only, create `hosts/alice-N/config.nix` containing just the keys that differ:

```nix
{ timezone = "America/New_York"; galleryName = "East Wing"; }
```

Per-unit values win; anything not mentioned falls back to the shared defaults. These are build-time values — run `update-system` after changing them.

### Still planned

- `gnome.nix` — autologin, kiosk hardening
- Preview mode — live-reload editing vhost; see `docs/superpowers/specs/2026-08-11-preview-mode-design.md`

---

## Installation

The step-by-step walkthrough lives in **[`install.md`](../install.md)** at the repo root — a single
checklist to follow at the keyboard, kept in one place so it cannot drift from this document.

Read [`README.md`](../README.md) first for what has to be configured by hand on each machine, and
the Serving Architecture section above for why the paths are what they are.

Two things that trip up an install and are easy to miss:

- **Mount the library drive before `nixos-generate-config`.** It writes `fileSystems` entries for
  whatever is mounted under `/mnt` at that moment; mount afterwards and you are hand-writing the
  entry.
- **Set `libraryMode: external` in memex2's config.** Embedded is the default and cannot work with a
  library on a separate disk. The symptom is a site that renders with every image missing.

---

## Bash Aliases Reference

Defined in `nixos/modules/aliases.nix` (production). All aliases are documented with a comment explaining what they do.

| Alias | What it does |
|---|---|
| `make-gallery <dir>` | Catalog a directory of media into Records + a Collection |
| `gallery-status` | Plain-English health check of WiFi, site builder, and web server |
| `restart-site` | Restart the site builder if the collection stops updating |
| `update-system` | Pull the latest configuration and rebuild NixOS |
| `wifi-qr` | Regenerate the printable WiFi join QR code |

---

## Why memex2 is not a Nix package

memex2 is deliberately a plain git checkout in the attendant's home directory, not a Nix derivation
or flake input.

Its CLI writes generated content — Records and Collections — back into its own working tree, and the
`memex.config.yml` it reads is per-machine. The Nix store is read-only, so a packaged memex2 would
need a mutable working directory elsewhere regardless, losing the benefit. Nix's job here is just to
provide `nodejs`, run the systemd services, and point the attendant aliases at the checkout.

The tradeoff: memex2's version is not pinned by the flake. Updating it is `git pull` in
`~/memex2`, separate from `update-system`.

---

## Future / Planned

- **Preview mode**: live-reload editing at `http://alice:8081` via an nginx-proxied Eleventy dev server. Spec'd in `docs/superpowers/specs/2026-08-11-preview-mode-design.md`; deferred until the base install works.
- **Syncthing**: sync the media library and Records to other machines
- **Captive portal**: auto-redirect visitors to the site when joining WiFi
- **Auto-login**: GNOME autologin for the `gallery` user so attendant just powers on
