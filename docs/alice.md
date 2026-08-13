# Alice

Art gallery kiosk running NixOS. Managed by a non-technical attendant. Visitors connect to Alice's WiFi and browse the gallery's digital collection at `http://alice`.

For a checklist of everything that must be configured by hand on each machine, see the
[README](../README.md). This document is the full reference: architecture, workflow, and the
step-by-step install walkthrough.

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

- **SSID**: set in `/etc/alice/wifi-credentials` during install (see Installation, step 5b)
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

### Prerequisites

- NixOS minimal ISO on a USB drive (download from nixos.org)
- This repo accessible (USB copy or network)
- Alice machine physically available

### Steps

**1. Boot from USB**

Enter BIOS (F1 on ThinkCentre at POST), set boot order to USB first.

**2. Drop into a root shell**

The live environment requires `sudo` for disk operations. To avoid typing it repeatedly:

```bash
sudo -i
```

**3. Partition disks**

First identify the target drive — be careful not to confuse it with the USB installer:

```bash
lsblk    # system drive is ~400GB; USB will be smaller with the ISO on it
```

**If the drive has an existing OS (e.g. Windows)**, wipe it first:

```bash
wipefs -a /dev/sda
```

Then create a fresh GPT partition table:

```bash
parted /dev/sda -- mklabel gpt
parted /dev/sda -- mkpart ESP fat32 1MB 512MB
parted /dev/sda -- set 1 esp on
parted /dev/sda -- mkpart primary ext4 512MB 100%
```

**4. Format and mount**

```bash
mkfs.fat -F32 /dev/sda1
mkfs.ext4 /dev/sda2
mount /dev/sda2 /mnt
mkdir -p /mnt/boot
mount /dev/sda1 /mnt/boot
```

Run `lsblk` again to confirm the layout looks right before continuing.

**4b. Prepare the library drive**

The media library gets its own disk at `/srv/library`. Do this **before** step 5 —
`nixos-generate-config` writes `fileSystems` entries for whatever is mounted under `/mnt` at that
moment, so mounting now means the entry is generated for you.

```bash
lsblk                                    # confirm the library disk, e.g. /dev/nvme0n1
parted /dev/nvme0n1 -- mklabel gpt
parted /dev/nvme0n1 -- mkpart primary ext4 1MB 100%
mkfs.ext4 -L alice-library /dev/nvme0n1p1
mkdir -p /mnt/srv/library
mount /dev/nvme0n1p1 /mnt/srv/library
```

Skip the `mklabel`/`mkfs` lines if the disk already holds a library you want to keep. Ownership is
set declaratively at boot, so no `chown` is needed here.

**5. Generate hardware config**

```bash
git clone https://github.com/nimdaghlian/alice /tmp/alice
nixos-generate-config --root /mnt
cp /mnt/etc/nixos/hardware-configuration.nix /tmp/alice/nixos/hosts/alice-1/hardware-configuration.nix
```

Check that the generated file contains a `fileSystems."/srv/library"` entry — if not, the library
disk was not mounted when this ran.

This file is machine-specific (disk UUIDs, kernel modules) and committed to the repo so each unit's profile is preserved. For subsequent machines use `alice-2`, `alice-3`, etc.

Commit the hardware config locally to avoid a "dirty git tree" warning during install:

```bash
cd /tmp/alice
git add nixos/hosts/alice-1/hardware-configuration.nix
git commit -m "add alice-1 hardware config"
```

**5b. Seed WiFi credentials**

```bash
mkdir -p /mnt/etc/alice
cp /tmp/alice/nixos/hosts/alice/wifi-credentials.example /mnt/etc/alice/wifi-credentials
chmod 600 /mnt/etc/alice/wifi-credentials
$EDITOR /mnt/etc/alice/wifi-credentials   # fill in real SSID/password
```

This file lives outside git and outside the Nix store — `hostapd` and the `wifi-qr` alias both read it at runtime.

**5c. Validate the configuration**

The live installer has Nix, and this is the cheapest place to catch a bad option name or module
merge — seconds here versus a failed `nixos-install`:

```bash
nix --extra-experimental-features 'nix-command flakes' \
  eval /tmp/alice/nixos#nixosConfigurations.alice-1.config.system.build.toplevel.drvPath
```

A `.drv` path means the whole configuration evaluated. On an error, fix it in `/tmp/alice`, commit,
and re-run — then carry those fixes back to the repo afterwards.

**6. Install**

```bash
nixos-install --flake /tmp/alice/nixos#alice-1
```

Set the `gallery` user password when prompted.

**7. First boot**

Reboot, remove USB. Log in as `gallery` with the initial password `password`, then change it:

```bash
passwd gallery
```

> **Why the initial password matters.** `initialPassword` applies only when the account is first
> created. Earlier versions of this config set no password at all, which gives the account a
> disabled login (`!` in `/etc/shadow`) — no password works, and there is no way in as `gallery` to
> run `passwd` in the first place. If you are ever locked out like that, boot the installer USB and
> use `nixos-enter --root /mnt` to set the password from outside, then reboot.

**8. Install the collection software (memex2)**

```bash
git clone https://github.com/nimdaghlian/memex2 ~/memex2
cd ~/memex2
npm install
cp memex.config.yml.example memex.config.yml
$EDITOR memex.config.yml
```

Four values matter, and the last three must match the Nix config:

```yaml
memexId: alice-1              # unique per unit; identifies this machine in the catalog
libraryMode: external         # Alice is ALWAYS external — see Serving Architecture
library: /srv/library         # must match alice.site.libraryPath
libraryUrl: /library/         # must match nginx's location block
```

If `library` and `alice.site.libraryPath` disagree, the generated URLs and the files on disk point at
different places and every image 404s.

The site builder (`eleventy`) will fail to start until `npm install` has been run — `gallery-status` reports this.

**9. Put the configuration repo in place**

So `update-system` can pull and rebuild later. `nixos-generate-config` wrote its own files to
`/etc/nixos` back in step 5, so that directory is **always** non-empty at this point and the clone
will fail unless you move it aside first:

```bash
sudo mv /etc/nixos /etc/nixos.orig
sudo git clone https://github.com/nimdaghlian/alice /etc/nixos
```

Nothing in `/etc/nixos.orig` is needed — the hardware config it contains was already copied into the
repo in step 5, and the flake replaces `configuration.nix` entirely. Keep it until the first
`update-system` succeeds, then delete it.

**10. Verify**

- GNOME desktop loads
- `gallery-status` shows all four services OK
- From a second device: join Alice's WiFi, open `http://alice`, confirm the collection loads

**11. Print the WiFi join QR code**

```bash
wifi-qr
```

Writes `/home/gallery/wifi-qr.png`. Print it and display it near the kiosk.

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
