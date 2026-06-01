---
name: bonbon-homelab
description: >
  Deep context skill for Dewalt's homelab infrastructure centered on "bonbon" — a ThinkCentre M720q
  running Debian with Coolify (Traefik reverse proxy), Docker, and Tailscale. Use this skill whenever
  working on anything related to bonbon, homelab services, The Well media archive, Coolify deployments,
  Nextcloud/OpenCloud, copyparty, CrashPlan, Samba, Yazi, Alice kiosk, Reticulum/LoRa, ATProto/PDS,
  or any self-hosted app on Dewalt's machines. Also trigger for NixOS flake configs, new machine provisioning,
  or any self-hosted app on Dewalt's machines. Also trigger for networking questions involving Tailscale
  MagicDNS, Cloudflare Tunnels, Tailscale Funnel, or inter-machine connectivity across the homelab fleet.
---

# Bonbon Homelab Skill

This skill provides full context on Dewalt's homelab so Claude Code doesn't need to re-ask setup questions.
Read this before making any recommendations or writing any config/code related to the homelab.

## Machine Fleet

| Hostname | Hardware | OS | Role |
|---|---|---|---|
| **bonbon** | ThinkCentre M720q | Debian | Primary homelab server — Docker, Coolify, main services |
| **screb** | ThinkPad x220 | Peppermint OS | Workstation / X11 forwarding host |
| **alice** | ThinkCentre M710q | NixOS + GNOME | Gallery kiosk — Jekyll collection browser, WiFi AP, attendant-managed |
| Mac | Mac (main workstation) | macOS | Dev machine, iTerm2, Homebrew |
| Boox | Onyx Boox Go7 | Android | E-ink reader, WebDAV/Seafile sync |

All machines connected via **Tailscale**. MagicDNS subdomains used for inter-machine access.

## Bonbon: Core Infrastructure

### Storage
- **Internal SSD**: OS + Docker app data + self-contained services
- **The Well**: Two 10TB external USB drives — media archive. Mount path TBD (check with `lsblk` or `mount`). Services do NOT get direct access to The Well unless explicitly required; Docker volumes for Well-accessing apps point at the external drive mounts.

### Networking Stack
- **Tailscale**: Private mesh VPN. MagicDNS for `.ts.net` subdomains between machines.
- **Coolify**: Web UI for app deployment. Manages Docker Compose services.
- **Traefik**: Reverse proxy + SSL, managed by Coolify. Handles HTTPS termination for all services via domain labels.
- **Cloudflare Tunnels**: Preferred method for public internet exposure (hides origin IP, no static IP required).
- **Tailscale Funnel**: Alternative for public exposure, simpler but Tailscale-dependent.

> ⚠️ Caddy was previously installed but removed — it was non-functional. Do not suggest Caddy.

### Docker Conventions
- Self-contained apps: use bonbon's internal SSD
- Apps needing The Well: Docker volume pointing at external drive mount
- Coolify manages compose files; Traefik labels added via Coolify's domain UI
- Cargo/Rust tools are unreliable on bonbon — prefer prebuilt binaries

---

## Active / Recent Services

### Copyparty
File server for bonbon's internal SSD (not The Well).

**Config location**: `/opt/copyparty/config/copyparty.conf`  
**Data location**: `/opt/copyparty/data` (internal SSD)  
**Docker image**: `copyparty/ac:latest`  
**Port**: 3923  
**Public endpoint**: via Cloudflare Tunnel → Traefik → copyparty container

Key config flags:
```ini
[global]
e2dsa       # file indexing
e2ts        # multimedia indexing
ah-alg: argon2
xff-hdr: X-Forwarded-For
rproxy: 1   # required behind Traefik
```

Passwords must be hashed. Generate with:
```bash
docker exec -it copyparty sh
python3 -m copyparty --ah-cli --ah-alg argon2
```

See `references/copyparty.md` for full config template and Coolify compose.

### Nextcloud / OpenCloud
Both were set up simultaneously on bonbon for comparison. Port conflicts on port 80 were a known issue during setup. Cloudflare Tunnel vs. Tailscale Funnel evaluated for public access.

### CrashPlan
- Installed on The Well (headless Debian)
- Requires X11 forwarding from screb via Tailscale to run the GUI
- Missing shared library dependencies were manually resolved during setup
- Monitoring via `progress` and `btop`
- Use CrashPlan Small Business (LLC account)

### Samba
- Slow transfers observed when CrashPlan backup runs simultaneously (I/O + network contention)
- Workaround: mount via LAN IP directly (`/etc/hosts` alias) rather than Tailscale MagicDNS path

### Yazi (file manager)
- Installed on bonbon, handles image previews via imgcat
- Configured openers: images, video, audio, mediainfo
- Nerd Font installed via Homebrew on Mac side (not remote) for iTerm2 glyph rendering
- **Octothorpes** (CLI tagging tool) planned as Yazi Lua plugin integration

---

## Planned / In-Progress

### Alice (Gallery Kiosk)

**Hardware**: ThinkCentre M710q, ~400GB system drive + second internal drive for audio/video assets  
**OS**: NixOS flake, GNOME desktop  
**Status**: NixOS flake config being built; machine physically on-hand, not yet installed

#### Purpose
Art gallery kiosk managed by a non-technical attendant. Visitors connect to Alice's WiFi and browse a Jekyll site presenting the gallery's digital collection. Alice does **not** access bonbon's Well — all assets stored locally on the second drive.

#### Storage Layout
- **Drive 1 (system)**: NixOS OS, Jekyll site, make-gals tool, Obsidian vault
- **Drive 2 (assets)**: Audio and video files, separated from system drive

#### Attendant Workflow
1. Dump new media assets into assigned directories on Drive 2
2. Run `make-gals` (Node.js CLI at `~/make-gals/`) to generate Jekyll-ready Markdown frontmatter files for the new assets
3. Edit the generated MD files in Obsidian (add titles, tags, descriptions)
4. Jekyll (running in watch mode) auto-rebuilds — no manual step needed

All CLI operations are wrapped in **well-documented bash aliases** so the attendant doesn't need to remember Unix commands.

#### make-gals
Node.js CLI (`bin/make-gals.js`) that scans a gallery directory and outputs:
- `_galleries/<slug>.md` — gallery-level frontmatter
- `_media/<gallery>/<slug>.md` — per-asset frontmatter

Each gallery directory contains a `gallery.yml` config. Supports image, audio, and video templates. Reads EXIF dates from images.

#### Networking
- Alice creates its own WiFi LAN via **hostapd + dnsmasq** (AP mode)
- Serves the Jekyll site on that network (e.g., `http://10.0.0.1` or `http://alice.local`)
- **QR code** displayed or printed for visitors to join the network
- Alice can connect to the internet if needed (for updates, Tailscale, etc.) but does not serve over the internet
- **Tailscale** installed for remote management/SSH by Dewalt

#### Planned (not yet)
- Syncthing to sync Alice's asset/MD directories to other machines

### Octothorpes Integration
- Existing CLI tool for tagging/metadata
- Planned Yazi Lua plugin
- SPARQL/RDF knowledge graph using `octo:octothorpes` and `octo:indexed` properties

---

## Networking Patterns

### Cloudflare Tunnel (preferred for public endpoints)
```bash
cloudflared tunnel route dns <tunnel-name> <subdomain.yourdomain.com>
# point tunnel at http://localhost:<port> or let Traefik handle via domain
```

### Tailscale Funnel (simple alternative)
```bash
tailscale funnel <port>
```

### Traefik via Coolify
Set domain in Coolify's Domain UI. Labels are auto-applied. For custom Traefik config, use Coolify's environment/label overrides.

### Real-IP with Traefik
Always set in copyparty (and any app that needs client IP):
```ini
xff-hdr: X-Forwarded-For
rproxy: 1
```

---

## Key Constraints & Preferences

- **New machines use NixOS** — bonbon stays Debian, but Alice and any future machines use NixOS flakes. Alice does not use Docker/Coolify — services run as native NixOS systemd units (Jekyll, hostapd, dnsmasq, Tailscale).
- **No Caddy** — removed, non-functional
- **No Proxmox** — chose Debian + Docker directly
- **No RAID** — prefer MergerFS + SnapRAID or single drive + CrashPlan
- **Prebuilt binaries** over compiling on bonbon (Cargo unreliable)
- **Cloudflare Tunnel** preferred over static IP / port forwarding for public services
- **Tailscale** for all private inter-machine access
- Coolify is the deployment UI — always frame Docker services as Coolify-managed compose apps

---

## Reference Files

- `references/copyparty.md` — Full copyparty config template, Docker Compose for Coolify, Traefik notes
- `references/machines.md` — Extended machine specs and network addresses (fill in as discovered)

### Alice-specific
- `docs/alice.md` — Full Alice documentation: hardware, software stack, attendant workflow, network setup, installation guide, bash alias reference. Keep this up to date.
- `nixos/` — NixOS flake config. `flake.nix` + `hosts/alice/` for host config. Modules split into `nixos/modules/` as config grows.
