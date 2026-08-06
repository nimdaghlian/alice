# WiFi AP + QR Join Code — Design

Alice needs to broadcast its own WiFi network for gallery visitors and let them join by scanning a printed QR code, without exposing anything to the internet. This spec covers declaring the AP in the NixOS flake and generating the join QR code.

## Goals

- `hostapd` + `dnsmasq` declared as NixOS modules (per the plan already in `docs/alice.md`)
- SSID/password never committed to git, and never baked into the world-readable `/nix/store`
- A committed example credentials file so the admin edits values in place during install, rather than creating a file from scratch
- An on-demand alias that generates a printable QR PNG encoding the WiFi join credentials

## Non-goals

- Captive portal redirect (already tracked as a separate "Future" item in `docs/alice.md`)
- On-screen/live QR display — printed-only per this design
- Secrets management tooling (sops-nix/agenix) — not needed since the credentials file lives outside git entirely

## Components

### 1. Credentials file

Location: `/etc/alice/wifi-credentials`, mode `600`, owned by `root`.

Format:
```
SSID=AliceGallery
PASSWORD=changeme
```

An example with placeholder values is committed at `nixos/hosts/alice/wifi-credentials.example`. It is not referenced by any Nix module — it exists purely as an install-time template.

**Why not embed via `environment.etc`:** Nix-managed `/etc` files are written from the store and are either read-only or get clobbered on rebuild, and any value passed in at eval time lands in the store in plaintext. Copying the example file into place as a plain file sidesteps both problems: it's mutable in place, and the real password is never touched by Nix.

### 2. Install step

Added to `docs/alice.md`'s installation walkthrough, between "Generate hardware config" and "Install":

```bash
mkdir -p /mnt/etc/alice
cp /tmp/alice/nixos/hosts/alice/wifi-credentials.example /mnt/etc/alice/wifi-credentials
chmod 600 /mnt/etc/alice/wifi-credentials
$EDITOR /mnt/etc/alice/wifi-credentials   # fill in real SSID/password
```

This runs while `/mnt` is still the mounted target filesystem (before `nixos-install`), so the file is in place on first boot.

### 3. `wifi-ap.nix` module

New file: `nixos/modules/wifi-ap.nix`. Declares:

- `networking.networkmanager.enable = false;` (production only — replaces the install-time NetworkManager config currently in `hosts/alice/default.nix`)
- A static hostapd config *template* (committed, no secret — SSID/passphrase left as placeholder tokens)
- A `systemd` service (`hostapd.service` override via `serviceConfig.ExecStartPre`) that renders the template into `/run/hostapd/hostapd.conf` by substituting values read from `/etc/alice/wifi-credentials` at service start, and points `hostapd` at that runtime file
- `dnsmasq` configured for DHCP/DNS on the AP interface, serving `10.0.0.0/24` with gateway `10.0.0.1` (per the addressing already noted in `docs/alice.md`) — no secret involved, declared directly

If `/etc/alice/wifi-credentials` is missing or malformed at service start, `hostapd` fails to start and `systemctl status hostapd` shows the reason — this is acceptable since it can only happen if the install step above was skipped, and `gallery-status` (existing alias) will surface the AP as down.

### 4. `wifi-qr` alias

Added to `nixos/modules/aliases.nix` alongside `make-gallery`, `gallery-status`, etc.

- Reads `SSID` and `PASSWORD` from `/etc/alice/wifi-credentials`
- Runs `qrencode` to build a standard WiFi-join QR payload: `WIFI:T:WPA;S:<SSID>;P:<PASSWORD>;;`
- Writes the PNG to `/home/gallery/wifi-qr.png`
- Prints a one-line confirmation with the output path so the admin knows where to find it for printing

`qrencode` is added to `environment.systemPackages`.

Run once after install (or after any password change) — not on every boot, since the credentials rarely change and regenerating on every boot adds a startup dependency for no benefit.

## Data flow

```
install time:
  wifi-credentials.example (git) --copy--> /etc/alice/wifi-credentials (edited by admin)

boot time:
  /etc/alice/wifi-credentials --read--> hostapd ExecStartPre --renders--> /run/hostapd/hostapd.conf --> hostapd

on demand:
  /etc/alice/wifi-credentials --read--> wifi-qr alias --qrencode--> /home/gallery/wifi-qr.png --> printed by admin
```

## Error handling

- Missing credentials file at hostapd start → service fails, visible via `gallery-status` / `systemctl status hostapd`
- Missing credentials file when `wifi-qr` runs → alias exits with a clear error message pointing at `/etc/alice/wifi-credentials`, rather than generating a QR for an empty/placeholder network
- Malformed file (missing `SSID=` or `PASSWORD=` line) → same explicit failure in both paths, no silent fallback to placeholder values

## Testing

- `nixos-rebuild build --flake .#alice-1` to confirm the flake evaluates with the new modules
- On real hardware (or a VM with a USB WiFi adapter passed through): confirm `hostapd` and `dnsmasq` start, the SSID is visible from another device, and a client can associate and get a DHCP lease
- Run `wifi-qr`, confirm the PNG decodes (via phone camera or `zbarimg`) to the correct SSID/password and successfully joins the network
- Delete/rename the credentials file and confirm both `hostapd` and `wifi-qr` fail with clear, actionable errors rather than hanging or silently degrading

## Files touched

- `nixos/hosts/alice/wifi-credentials.example` (new)
- `nixos/modules/wifi-ap.nix` (new)
- `nixos/modules/aliases.nix` (new — first alias module; others in `docs/alice.md`'s table can migrate in later if desired, out of scope here)
- `nixos/hosts/alice/default.nix` (import new modules, remove install-time NetworkManager WiFi config)
- `docs/alice.md` (install steps, mark WiFi AP + QR future items as done)
