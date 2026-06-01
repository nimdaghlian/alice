# Alice

Art gallery kiosk running NixOS. Managed by a non-technical attendant. Visitors connect to Alice's WiFi and browse the gallery's digital collection via a local Jekyll site.

---

## Hardware

| | |
|---|---|
| **Model** | ThinkCentre M710q |
| **System drive** | ~400GB internal — OS, Jekyll site, tools, Obsidian vault |
| **Asset drive** | Second internal drive — audio and video files |
| **Network** | Built-in WiFi — runs in AP (access point) mode |

## Software Stack

| Component | What it does |
|---|---|
| NixOS (flake) | Operating system, declarative config |
| GNOME | Desktop environment for attendant |
| Jekyll | Serves the collection browser site, runs in watch mode |
| make-gals | Node.js CLI — generates Jekyll MD files from asset directories |
| Obsidian | Attendant edits MD metadata files |
| hostapd + dnsmasq | Creates Alice's own WiFi network |
| Tailscale | Remote admin SSH access |
| SSH | Remote management by admin |

---

## Attendant Workflow

The attendant does not need to use a terminal for routine work. All terminal operations are available as named bash aliases with plain-English descriptions.

### Adding new assets

1. Copy media files into the assigned gallery directory on the asset drive
2. Open Terminal and run `make-gallery` (alias for the make-gals CLI)
   - This generates one MD file per asset and one MD file for the gallery
3. Open Obsidian and edit the generated MD files — add titles, descriptions, tags
4. The Jekyll site updates automatically (no action needed)

### Starting up

- Power on Alice
- Log in as `gallery`
- Jekyll starts automatically on boot — the collection site is immediately live on the WiFi network

### Checking status

- Run `gallery-status` to confirm Jekyll is running and the WiFi AP is active

---

## Network Setup

Alice creates its own isolated WiFi network. It does **not** serve content over the internet.

- **SSID**: TBD (set during production install)
- **Gateway / site URL**: `http://10.0.0.1` (or `http://alice.local`)
- **QR code**: Printed or displayed near the kiosk — encodes WiFi join credentials
- **Internet access**: Alice *can* connect to the internet (for updates, Tailscale) but does not expose the Jekyll site publicly
- **AP stack**: hostapd (access point) + dnsmasq (DHCP + DNS)

Visitors: scan QR code → join network → open browser → collection site loads automatically (captive portal redirect, or manual navigation to the URL).

---

## NixOS Configuration

Config lives in `nixos/` at the root of this repo.

```
nixos/
  flake.nix                          # entry point, pins nixpkgs 25.05
  hosts/
    alice/
      default.nix                    # system config — desktop, users, services
      hardware-configuration.nix     # generated during install, machine-specific
```

### Planned modules (production flake)

These will be split into separate module files under `nixos/modules/` as the config grows:

- `gnome.nix` — desktop, autologin, kiosk hardening
- `wifi-ap.nix` — hostapd + dnsmasq config
- `jekyll.nix` — Jekyll systemd service (watch mode)
- `aliases.nix` — attendant-facing bash aliases
- `tailscale.nix` — Tailscale + SSH
- `drives.nix` — asset drive mount

---

## Installation

### Prerequisites

- NixOS minimal ISO on a USB drive (download from nixos.org)
- This repo accessible (USB copy or network)
- Alice machine physically available

### Steps

**1. Boot from USB**

Enter BIOS (F1 on ThinkCentre at POST), set boot order to USB first.

**2. Partition disks**

After booting the live environment:

```bash
lsblk                    # identify system drive (e.g. /dev/sda) and asset drive
fdisk /dev/sda           # or use parted / gdisk
# Create:
#   /dev/sda1  512MB   EFI System Partition  (type: EFI System)
#   /dev/sda2  rest    Linux filesystem       (type: Linux filesystem)
```

**3. Format and mount**

```bash
mkfs.fat -F32 /dev/sda1
mkfs.ext4 /dev/sda2
mount /dev/sda2 /mnt
mkdir -p /mnt/boot
mount /dev/sda1 /mnt/boot
```

**4. Generate hardware config**

```bash
nixos-generate-config --root /mnt
```

Copy `/mnt/etc/nixos/hardware-configuration.nix` into `nixos/hosts/alice/hardware-configuration.nix` in this repo (replaces the placeholder).

**5. Install**

Copy this repo to the live environment or mount the USB with the repo, then:

```bash
nixos-install --flake /path/to/alice/nixos#alice --root /mnt
```

Set the `gallery` user password when prompted.

**6. First boot**

Reboot, remove USB. Log in as `gallery`. Run `passwd gallery` to set a password if not set during install.

**7. Verify**

- GNOME desktop loads
- `ssh gallery@alice.ts.net` works from another machine (once Tailscale is set up)

---

## Bash Aliases Reference

Defined in `nixos/modules/aliases.nix` (production). All aliases are documented with a comment explaining what they do.

| Alias | What it does |
|---|---|
| `make-gallery` | Run make-gals on the current gallery directory |
| `gallery-status` | Show status of Jekyll and WiFi AP services |
| `restart-site` | Restart the Jekyll systemd service |
| `update-system` | Pull latest config and rebuild NixOS (`nixos-rebuild switch`) |

---

## Custom Nix Packages

Several components of Alice are custom codebases that will be packaged as Nix derivations and referenced as flake inputs. When each repo is published, it gets a `flake.nix` that exposes a Nix package, then gets added to `nixos/flake.nix` as an input.

| Package | Source | Nix package type |
|---|---|---|
| Custom Jekyll site | GitHub (TBD) | `pkgs.stdenv.mkDerivation` or bundled Ruby env |
| make-gals | GitHub (TBD) | `pkgs.buildNpmPackage` |
| Other codebase (TBD) | GitHub (TBD) | TBD |

**Pattern for each:**
1. Add `flake.nix` to the tool's own repo exposing a `packages.x86_64-linux.default`
2. Add it as an input in `nixos/flake.nix`
3. Pass the input's packages into the host config via `specialArgs` or overlay
4. Add the package to `environment.systemPackages`

During development (before repos are published), use a local path input:
```nix
make-gals.url = "path:/home/gallery/make-gals";
```

---

## Future / Planned

- **Syncthing**: sync asset directories and MD files to other machines
- **Captive portal**: auto-redirect visitors to the site when joining WiFi
- **Auto-login**: GNOME autologin for the `gallery` user so attendant just powers on
- **Production flake modules**: split config into focused module files
