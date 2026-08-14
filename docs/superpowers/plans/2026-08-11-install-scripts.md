# Install Scripts Implementation Plan

**Goal:** Turn the manual install walkthrough into phase-separated scripts that encode the failures
found during the first real install, so machine two doesn't rediscover them.

**Architecture:** Four scripts under `install/` in this repo, run from the clone at `/tmp/alice`
(the repo is public and ethernet is required anyway, so no second USB is needed). Each is
independently re-runnable. Nothing is monolithic — a failure at validation must never force
repartitioning.

**Tech stack:** POSIX-ish bash, `set -euo pipefail`, no dependencies beyond what the NixOS installer
ISO ships.

## Why these scripts look paranoid

Every check below exists because it actually went wrong on 2026-08-11 during the first install of
`alice-1`. This is not defensive programming in the abstract.

| What happened | Cost | Check that would have caught it |
|---|---|---|
| `nixos-generate-config` never ran; `cp` silently copied nothing | ~40 min of chasing phantom module errors | Assert the source file exists and has 3 filesystems before copying |
| Hardware config left untracked; Nix silently evaluated the committed stub | Compounded the above | Assert `git status` shows the file staged or committed |
| `git commit` failed — no `user.email` on the installer | Blocked the commit, hence the above | Set local git identity before committing |
| NVMe mounted twice, producing duplicate `fileSystems` entries | Nix syntax error | Detect stacked mounts before generating |
| Generated config had `/srv/library` but no `/` | "does not specify your root file system" | Assert exactly `/`, `/boot`, `/srv/library` |
| `mkdir` without `-p` errored on an existing directory | Noise, misleading | Use `mkdir -p` |

## Global constraints

- **Destructive operations require typed confirmation.** Never infer a disk. Print size, model, and
  current contents, then require the operator to type the device path back.
- **Never trust `systemctl is-active`.** It reported all-green while `eleventy` was failing — verify
  a service produced its *output*, not that its process exists.
- **Never invoke a Node tool through `npx` in a unit or script.** `npx` exited 254 under systemd
  before Eleventy ever started. Call the entry point with `node` directly.
- **Client-facing behaviour must be tested from a client.** The `127.0.0.2` dnsmasq bug was
  invisible from the machine itself, where that address is a working local address.

---

### Task 1: `install/lib.sh` — shared helpers

**Files:** Create `install/lib.sh`

- [ ] **Step 1: Write the helpers**

```bash
# Common output + assertion helpers. Sourced by every phase script.
set -euo pipefail

ok()   { printf '  \033[32mOK\033[0m    %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; }
die()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# Require the operator to type a value back. Used before anything destructive.
confirm_exact() {
  local expected="$1" prompt="$2" answer
  printf '%s\n  Type it exactly to proceed: ' "$prompt"
  read -r answer
  [ "$answer" = "$expected" ] || die "Got '$answer', expected '$expected'. Nothing changed."
}

# A device is mounted more than once — produces duplicate fileSystems entries.
assert_not_stacked() {
  local dev="$1" count
  count=$(mount | grep -c "^$dev ") || true
  [ "$count" -le 1 ] || die "$dev is mounted $count times (stacked). Unmount until 'mount | grep $dev' is empty, then remount once."
}
```

- [ ] **Step 2: Verify it sources cleanly**

Run: `bash -n install/lib.sh && (. install/lib.sh && ok "helpers load")`
Expected: `OK    helpers load`

- [ ] **Step 3: Commit**

```bash
git add install/lib.sh
git commit -m "Add shared helpers for install scripts"
```

---

### Task 2: `install/01-disks.sh` — partition and mount

**Files:** Create `install/01-disks.sh`

**Interfaces:** Consumes `lib.sh`. Produces `/mnt`, `/mnt/boot`, `/mnt/srv/library` mounted.

- [ ] **Step 1: Write the script**

Behaviour, in order:

1. `lsblk -dno NAME,SIZE,MODEL` — print candidate disks
2. Prompt for the **system** disk; `confirm_exact` the device path
3. Prompt for the **library** disk; `confirm_exact`; refuse if it equals the system disk
4. Refuse if either device is the one the installer booted from (compare against
   `findmnt -no SOURCE /iso` or the live media device)
5. Show what will be destroyed (`lsblk -f` for both) and require a final `yes-destroy`
6. Partition and format both, exactly as `install.md` documents
7. Mount `/mnt`, `/mnt/boot`, `/mnt/srv/library`
8. `assert_not_stacked` for each device
9. Print `mount | grep /mnt` and assert exactly three lines

- [ ] **Step 2: Test the guards without destroying anything**

Run with a `DRY_RUN=1` env var that stubs `parted`/`mkfs`/`mount` to echo. Verify: mismatched
confirmation aborts, same-disk-twice aborts, and the happy path reaches the mount assertions.

- [ ] **Step 3: Commit**

```bash
git add install/01-disks.sh
git commit -m "Add disk partitioning script with typed confirmation guards"
```

---

### Task 3: `install/02-config.sh` — clone, generate, validate

**Files:** Create `install/02-config.sh`

**Interfaces:** Consumes mounted `/mnt` from Task 2. Produces a validated flake at `/tmp/alice`.

This is the script that encodes most of the pain from the first install. Safe to re-run.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
. "$(dirname "$0")/lib.sh"

UNIT="${1:-alice-1}"
REPO=/tmp/alice

step "Cloning configuration"
[ -d "$REPO/.git" ] || git clone https://github.com/nimdaghlian/alice "$REPO"
ok "repo at $REPO"

step "Git identity (nixos-install needs a commit; the ISO has no identity configured)"
git -C "$REPO" config user.email "install@alice.local"
git -C "$REPO" config user.name  "Alice Installer"
ok "identity set locally"

step "Generating hardware configuration"
mount | grep -q ' /mnt '            || die "/mnt is not mounted — run 01-disks.sh first"
mount | grep -q ' /mnt/srv/library ' || die "library disk not mounted at /mnt/srv/library"
nixos-generate-config --root /mnt --force

SRC=/mnt/etc/nixos/hardware-configuration.nix
[ -s "$SRC" ] || die "$SRC missing or empty — nixos-generate-config did not run"

step "Verifying generated filesystems"
for fs in '"/"' '"/boot"' '"/srv/library"'; do
  grep -q "fileSystems.$fs" "$SRC" || die "no fileSystems.$fs entry — was that disk mounted?"
done
count=$(grep -c 'fileSystems\."' "$SRC")
[ "$count" -eq 3 ] || die "expected 3 fileSystems entries, found $count (stacked mount?)"
ok "3 filesystems: / /boot /srv/library"

step "Installing hardware config into the flake"
mkdir -p "$REPO/nixos/hosts/$UNIT"
cp "$SRC" "$REPO/nixos/hosts/$UNIT/hardware-configuration.nix"
git -C "$REPO" add -A
git -C "$REPO" commit -m "add $UNIT hardware config" || warn "nothing to commit (unchanged)"

# Nix reads flakes from git and IGNORES untracked files. An unstaged hardware config
# means the committed stub is evaluated instead — silently, with no error.
git -C "$REPO" status --porcelain "nixos/hosts/$UNIT/hardware-configuration.nix" \
  | grep -q '^??' && die "hardware config is untracked — Nix will ignore it"
ok "hardware config is tracked"

step "Validating the flake (this is the cheap place to fail)"
nix --extra-experimental-features 'nix-command flakes' \
  eval "$REPO/nixos#nixosConfigurations.$UNIT.config.system.build.toplevel.drvPath" >/dev/null \
  || die "flake does not evaluate — fix in $REPO, commit, re-run this script"
ok "configuration evaluates"
```

- [ ] **Step 2: Verify each assertion fires**

Test by breaking one precondition at a time: unmount the library disk, leave the hardware config
unstaged, corrupt a module. Each must produce its specific message, not a generic failure.

- [ ] **Step 3: Commit**

```bash
git add install/02-config.sh
git commit -m "Add config generation and validation script"
```

---

### Task 4: `install/03-install.sh` — credentials and install

**Files:** Create `install/03-install.sh`

- [ ] **Step 1: Write the script**

1. Prompt for SSID and passphrase (passphrase with `read -rs`, twice, compared)
2. **Assert passphrase is 8–63 characters** — WPA2's requirement; too short means `hostapd` refuses
   to start, discovered long after install
3. Warn (do not block) if either contains characters that were historically fragile
4. Write `/mnt/etc/alice/wifi-credentials`, `chmod 600`
5. Print the SSID back for confirmation
6. Run `nixos-install --flake /tmp/alice/nixos#<unit>`
7. On success, print the post-reboot checklist and remind the operator to carry
   `hardware-configuration.nix` back to the repo

- [ ] **Step 2: Verify the length check**

Run: supply a 5-character passphrase.
Expected: rejected before anything is written.

- [ ] **Step 3: Commit**

```bash
git add install/03-install.sh
git commit -m "Add credentials and install script"
```

---

### Task 5: `install/first-boot.sh` — post-reboot setup

**Files:** Create `install/first-boot.sh`

Runs as `gallery` after the first boot. Non-destructive.

- [ ] **Step 1: Write the script**

1. Assert it is **not** running as root — memex2 must be owned by `gallery`, and cloning as root
   puts it in `/root/memex2` where nothing finds it
2. Clone memex2 to `$HOME/memex2` (assert the path — `~/alice` was a real mistake made once)
3. `npm install`
4. Seed `memex.config.yml` and require all four values, asserting `libraryMode: external` and that
   `library:` matches `alice.site.libraryPath`
5. Clone the config repo to `/etc/nixos`, moving the installer's directory aside first
6. Run the verification below

- [ ] **Step 2: Verification section — output, not liveness**

```bash
step "Verifying"
systemctl is-active --quiet hostapd  || die "hostapd not running"
systemctl is-active --quiet dnsmasq  || die "dnsmasq not running"
systemctl is-active --quiet nginx    || die "nginx not running"

# is-active is NOT sufficient: it reported healthy while eleventy failed on every restart.
sleep 5
[ -f /srv/www/alice/index.html ] || die "no index.html — check: journalctl -u eleventy"
ok "site built"

[ "$(stat -c %U /srv/library)" = gallery ] || warn "/srv/library not owned by gallery"
curl -fsS -o /dev/null http://10.0.0.1/   || die "nginx not serving"
ok "site served"

warn "Name resolution and the media library can only be verified FROM A CLIENT DEVICE."
warn "Join the WiFi from a phone, open http://10.0.0.1/, and confirm an image loads."
```

- [ ] **Step 3: Commit**

```bash
git add install/first-boot.sh
git commit -m "Add first-boot setup and verification script"
```

---

### Task 6: Wire into the docs

**Files:** Modify `install.md`, `README.md`

- [ ] **Step 1: Restructure `install.md`**

Keep the manual commands — they are the reference when a script fails — but lead each phase with the
script that does it. Add a note that scripts are the normal path and the manual steps are the
fallback.

- [ ] **Step 2: Fix the two known doc bugs**

`mkdir` → `mkdir -p` in step 3, and add `--force` to `nixos-generate-config`.

- [ ] **Step 3: Commit**

```bash
git add install.md README.md
git commit -m "Document install scripts as the primary path"
```

---

## Self-review notes

- **Not automated deliberately:** BIOS and boot order (physical), the reboot, and choosing which
  disks (scripts detect and confirm, never guess).
- **`03-install.sh` still prompts** for the root password via `nixos-install`. That is correct;
  scripting a root password would be worse.
- **Scripts assume ethernet.** They clone from GitHub. A USB fallback is a copy of the repo
  directory and running the same scripts from it — worth a paragraph in `install.md`, not a
  separate code path.
