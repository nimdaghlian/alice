---
name: bonbon-homelab
description: >
  Deep context skill for Dewalt's homelab infrastructure centered on "bonbon" — a ThinkCentre M720q
  running Debian with Coolify (Traefik reverse proxy), Docker, and Tailscale. Use this skill whenever
  working on anything related to bonbon, homelab services, The Well media archive, Coolify deployments,
  Nextcloud/OpenCloud, copyparty, CrashPlan, Samba, Yazi, Reticulum/LoRa, ATProto/PDS, or any
  self-hosted app on Dewalt's machines. Also trigger for new machine provisioning, or for networking
  questions involving Tailscale MagicDNS, Cloudflare Tunnels, Tailscale Funnel, or inter-machine
  connectivity across the homelab fleet. For the Alice gallery kiosk specifically, use the `alice` skill.
---

# Bonbon Homelab Skill

This skill provides full context on Dewalt's homelab so Claude Code doesn't need to re-ask setup questions.
Read this before making any recommendations or writing any config/code related to the homelab.

## Machine Fleet

| Hostname | Hardware | OS | Role |
|---|---|---|---|
| **bonbon** | ThinkCentre M720q | Debian | Primary homelab server — Docker, Coolify, main services |
| **screb** | ThinkPad x220 | Peppermint OS | Workstation / X11 forwarding host |
| **alice** | ThinkCentre M710q | NixOS + GNOME | Gallery kiosk, attendant-managed — see the `alice` skill |
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

Moved out of this skill — **use the `alice` skill**. Alice is self-contained: it does not access
bonbon's Well, uses no Docker/Coolify, and no longer runs Tailscale, so it shares no infrastructure
with the rest of the fleet.

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

- **New machines use NixOS** — bonbon stays Debian, but Alice and any future machines use NixOS flakes, with services as native systemd units rather than Docker/Coolify.
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
- See the `alice` skill (`.claude/skills/alice/SKILL.md`) — it owns `docs/alice.md`, the `nixos/`
  flake, and everything else kiosk-related.
