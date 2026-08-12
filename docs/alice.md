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
| **System drive** | ~400GB internal — OS, memex2 checkout (site + media library), Obsidian vault |
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

1. Copy media files into a gallery directory inside the media library (`~/memex2/site/library/`)
2. Open Terminal and run `make-gallery <directory>`
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
- `drives.nix` — second-drive mount, if the media library outgrows the system drive

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

**5. Generate hardware config**

```bash
git clone https://github.com/nimdaghlian/alice /tmp/alice
nixos-generate-config --root /mnt
cp /mnt/etc/nixos/hardware-configuration.nix /tmp/alice/nixos/hosts/alice-1/hardware-configuration.nix
```

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
$EDITOR memex.config.yml     # set memexId (this machine's identity)
```

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

Its CLI writes generated content — `manifest.json`, Records, Collections — back into its own working
tree, and the media library lives inside that tree too. The Nix store is read-only, so a packaged
memex2 would need its working directory somewhere else anyway, losing the benefit. Nix's job here is
just to provide `nodejs`, run the systemd services, and point the attendant aliases at the checkout.

The tradeoff: memex2's version is not pinned by the flake. Updating it is `git pull` in
`~/memex2`, separate from `update-system`.

---

## Future / Planned

- **Syncthing**: sync the media library and Records to other machines
- **Captive portal**: auto-redirect visitors to the site when joining WiFi
- **Auto-login**: GNOME autologin for the `gallery` user so attendant just powers on
- **External library mode**: serve the media library from outside the memex2 checkout (e.g. a second drive). Designed in memex2's own repo (`docs/specs/2026-08-10-external-library-mode-design.md`); once it lands, Alice sets `libraryMode: external` and points nginx at the new location.
