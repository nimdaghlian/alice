# Installing Alice

The ordered checklist for putting Alice on a machine, meant to be followed at the keyboard. For
*what* each per-machine setting is and *why*, see [`README.md`](README.md); for architecture and the
attendant's day-to-day workflow, [`docs/alice.md`](docs/alice.md).

**Bring:** the NixOS USB, ethernet cable, wired keyboard. Ethernet matters — `nixos-install` pulls a
lot from the binary cache and the live environment's WiFi is fiddly.

### 1 · Boot and get root

F1 at POST → boot order to USB. Then `sudo -i`.

### 2 · Partition

```bash
lsblk                        # confirm the ~400GB internal, NOT the USB
wipefs -a /dev/sda           # wipes the old install
parted /dev/sda -- mklabel gpt
parted /dev/sda -- mkpart ESP fat32 1MB 512MB
parted /dev/sda -- set 1 esp on
parted /dev/sda -- mkpart primary ext4 512MB 100%
mkfs.fat -F32 /dev/sda1
mkfs.ext4 /dev/sda2
mount /dev/sda2 /mnt
mkdir -p /mnt/boot && mount /dev/sda1 /mnt/boot
lsblk                        # verify before continuing
```

### 2b · Library drive (the NVMe)

Must happen **before** step 3 — `nixos-generate-config` writes `fileSystems` entries for whatever is
mounted under `/mnt` at that moment.

```bash
lsblk                                    # confirm the 1TB NVMe
parted /dev/nvme0n1 -- mklabel gpt
parted /dev/nvme0n1 -- mkpart primary ext4 1MB 100%
mkfs.ext4 -L alice-library /dev/nvme0n1p1
mkdir -p /mnt/srv/library
mount /dev/nvme0n1p1 /mnt/srv/library
lsblk -f                                 # nvme0n1p1 ext4, labeled alice-library
```

NVMe partitions are `nvme0n1p1` (with a `p`), not `nvme0n11`. No `chown` needed — a tmpfiles rule
sets ownership to `gallery` at boot.

### 3 · Clone config and generate hardware config

```bash
git clone https://github.com/nimdaghlian/alice /tmp/alice
nixos-generate-config --root /mnt
mkdir /tmp/alice/nixos/hosts/alice-1/
cp /mnt/etc/nixos/hardware-configuration.nix \
   /tmp/alice/nixos/hosts/alice-1/hardware-configuration.nix
cd /tmp/alice
git add nixos/hosts/alice-1/hardware-configuration.nix
git commit -m "add alice-1 hardware config"
```

Confirm the library drive was picked up:

```bash
grep -A3 'srv/library' /mnt/etc/nixos/hardware-configuration.nix
```

Empty output means the NVMe wasn't mounted when this ran — mount it and re-run
`nixos-generate-config`.

### 4 · Validate before installing ⬅ do not skip

```bash
nix --extra-experimental-features 'nix-command flakes' \
  eval /tmp/alice/nixos#nixosConfigurations.alice-1.config.system.build.toplevel.drvPath
```

A `.drv` path means the whole config evaluated — every option name and module merge is sound. An error here costs seconds to fix; the same error during `nixos-install` costs a lot more. This is the first time this flake has ever been evaluated, so expect to land here a few times. Fix in `/tmp/alice`, commit, re-run.

### 5 · WiFi credentials

```bash
mkdir -p /mnt/etc/alice
cp /tmp/alice/nixos/hosts/alice/wifi-credentials.example /mnt/etc/alice/wifi-credentials
chmod 600 /mnt/etc/alice/wifi-credentials
nano /mnt/etc/alice/wifi-credentials      # real SSID + passphrase
```

### 6 · Install

```bash
nixos-install --flake /tmp/alice/nixos#alice-1
```

Set the **root** password when prompted — write it down. Reboot, pull the USB.

### 7 · First boot

Log in as `gallery` / `password`, then `passwd gallery`. Then check the riskiest layer first:

```bash
ip link                    # is the WiFi really wlan0?
systemctl status hostapd
systemctl status dnsmasq
```

### 8 · memex2 and config repo

```bash
git clone https://github.com/nimdaghlian/memex2 ~/memex2
cd ~/memex2 && npm install
cp memex.config.yml.example memex.config.yml
nano memex.config.yml
```

Four values, and the last three must match the Nix config exactly:

```yaml
memexId: alice-1              # unique per unit
libraryMode: external         # NOT embedded — see below
library: /srv/library         # must match alice.site.libraryPath
libraryUrl: /library/         # must match nginx's location block
```

Embedded mode cannot work here: Eleventy refuses a passthrough source outside the project directory,
so a library on its own disk is external-only. Getting `library:` wrong is the failure mode where the
site renders but every image 404s.

```bash
sudo mv /etc/nixos /etc/nixos.orig
sudo git clone https://github.com/nimdaghlian/alice /etc/nixos
```

### 9 · Verify

```bash
gallery-status              # all four OK
findmnt /srv/library        # library drive mounted
ls -ld /srv/www/alice       # build output exists, owned by gallery
wifi-qr
```

From a phone: join the WiFi, open `http://alice`, and confirm a `/library/...` media file loads — the nginx alias can fail independently of the HTML root.

To exercise the whole pipeline end to end, drop a couple of images into a gallery directory and catalog them:

```bash
mkdir -p /srv/library/test-gallery
cp ~/some-image.jpg /srv/library/test-gallery/
make-gallery /srv/library/test-gallery
```

Records appear in `~/memex2/site/`, Eleventy rebuilds into `/srv/www/alice`, and the gallery shows up at `http://alice`.

---

### Likely failures

| Symptom | Cause | Check |
|---|---|---|
| Eval fails at step 4 | Bad option name — `services.dnsmasq.settings` and `networking.firewall.interfaces` least certain | Error names the option |
| Eval fails on `--output` | Eleventy may reject an absolute output path outside the project dir | `journalctl -u eleventy` after install; fallback is a symlink |
| `hostapd` dead | Interface isn't `wlan0` | `ip link` → set `alice.wifiAp.interface` |
| Phone joins, no IP | dnsmasq or firewall | `journalctl -u dnsmasq` |
| `eleventy` dead | `npm install` missing, or `npx` unhappy under systemd with `HOME` set to the checkout | `journalctl -u eleventy` |
| Site 404s everywhere | `/srv/www/alice` empty — Eleventy never built | `ls /srv/www/alice`, then `journalctl -u eleventy` |
| Pages load, images 404 | `library:` in `memex.config.yml` disagrees with `alice.site.libraryPath`, or `libraryMode` is still `embedded` | `grep library ~/memex2/memex.config.yml` |
| `http://alice` fails, `10.0.0.1` works | dnsmasq `address=/alice/` entry | `journalctl -u dnsmasq` |

**Not** a fix: `chmod 755 /home/gallery`. An earlier version of this table suggested it for 403s. nginx never reads `/home` now — it serves `/srv/www/alice` and `/srv/library` — and the original problem was `ProtectHome`, a mount namespace that file permissions cannot affect.
