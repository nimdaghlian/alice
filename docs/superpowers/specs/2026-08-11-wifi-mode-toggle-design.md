# WiFi mode toggle — AP vs joining an external network

> **Status: DRAFT, deferred.** Ethernet is the current answer and works. This is for venues without
> a wired drop. Nothing here blocks anything.

## Problem

Alice's radio is dedicated to access-point mode. `hostapd` owns `wlan0`, NetworkManager is told to
leave it alone (`unmanaged = [ "interface-name:wlan0" ]`), a static `10.0.0.1` is assigned, and
`dnsmasq` binds to it. There is no path to joining an external network on that radio without editing
config and rebuilding.

That is fine when ethernet is available — Alice reaches the internet over `eth0` for
`update-system`, and the WiFi stays a pure AP. It is not fine in a venue with no wired drop, where
the machine can only get online over WiFi.

## The physical constraint

One radio cannot reliably be both an access point and a client. Some chipsets support concurrent
AP+STA, but it is driver-dependent and fragile — not something to build a kiosk on without testing
the specific card. Treat the built-in radio as doing one job at a time.

This is what makes it a *mode toggle* rather than a configuration option: switching costs the AP.
While Alice is joined to an external network, **visitors cannot reach the collection.**

## Options

### A. Second radio (USB dongle) — no toggle at all

Built-in radio stays the AP permanently; a USB dongle joins external networks. Both work at once,
nothing switches, no state to get wrong.

The Nix side is small: `alice.wifiAp.interface` already exists, so the AP keeps `wlan0` and the
dongle appears as `wlan1` under NetworkManager's normal management. NM already manages everything
except the explicitly-unmanaged AP interface, so a dongle would Just Work with no config change at
all.

**Recommended if the venue allows it.** It removes the failure mode where someone switches to client
mode and forgets, leaving the gallery without a kiosk network.

### B. Runtime toggle (no new hardware) — *primary design below*

Two admin commands that stop the AP stack, hand the interface to NetworkManager, connect, and
reverse it. No rebuild required, because `nmcli` can override the unmanaged setting at runtime.

### C. Declarative flag + rebuild

`alice.wifiAp.enable = false`, `update-system`, reboot. Cleanest conceptually, but circular: the
usual reason to want internet is to run `update-system`, and you cannot rebuild your way onto a
network you need in order to rebuild. **Rejected.**

## Design (Option B)

### Commands

```
wifi-client <ssid>    # stop the AP, join an external network
wifi-ap               # stop the client connection, resume broadcasting
```

Admin-facing, not attendant-facing. They belong in `aliases.nix` alongside the others but should be
documented under administration rather than in the attendant workflow — an attendant running
`wifi-client` takes the gallery offline.

### `wifi-client`

1. `systemctl stop hostapd dnsmasq`
2. `ip addr flush dev wlan0` — the static `10.0.0.1` must go, or NM will fight it
3. `nmcli device set wlan0 managed yes`
4. `nmcli device wifi connect "<ssid>" --ask` — prompt for the passphrase rather than taking it as
   an argument, so it stays out of shell history
5. Report the acquired address, and state plainly that the gallery network is now **down**

### `wifi-ap`

1. `nmcli device disconnect wlan0`
2. `nmcli device set wlan0 managed no`
3. `ip addr add 10.0.0.1/24 dev wlan0` — restore the static address that `networking.interfaces`
   would have set at boot; nothing re-applies it after a flush
4. `systemctl start hostapd dnsmasq`
5. Verify: assert `wlan0` is `UP` with `10.0.0.1`, and that `hostapd` is active

### Fail-safe: reboot returns to AP mode

This falls out of the declarative model rather than needing to be built. Everything `wifi-client`
does is runtime state — NM's managed flag, the flushed address, the stopped units. On reboot the
Nix configuration reasserts itself and Alice comes back as an access point.

That is the right default for a kiosk: the worst case of someone forgetting is resolved by turning
it off and on again. It should be stated prominently in the docs, because it is also surprising if
you expect client mode to persist.

### Mode visibility

`gallery-status` currently reports four services. It should report **mode** as the first line, since
"hostapd is not running" reads as a fault when it may be deliberate:

```
Alice status:
  MODE    Access point (gallery network is live)
  OK      WiFi network is being broadcast
  ...
```

or

```
Alice status:
  MODE    Client — joined "VenueGuest". THE GALLERY NETWORK IS DOWN.
  ...
```

Derive it from whether `hostapd` is active plus whether NM has a connection on `wlan0`.

## Risks

**The main one is human, not technical:** switching to client mode takes the gallery offline, and
nothing forces it back except a reboot. Mitigations, in order of preference:

1. `wifi-ap` prints loudly on success, and `wifi-client` warns before acting
2. Mode shown first in `gallery-status`
3. *Optional:* a systemd timer that reverts to AP mode after N minutes unless cancelled. Defensible
   for an unattended kiosk, but adds a background process that can surprise an admin mid-update.
   Not part of the initial design; revisit if forgetting proves to be a real pattern.

**Secondary:** `nmcli device set ... managed` is imperative state that a `nixos-rebuild switch` may
reassert. If a rebuild during client mode drops the connection, the fix is to re-run `wifi-client`.
Worth testing, and worth documenting either way — this is the fundamental cost of Option B versus a
dongle.

## Testing

- `wifi-client` joins a known network; `ip addr show wlan0` shows a DHCP address from it
- The gallery network genuinely disappears — **verified from a phone**, not from Alice, since the
  `127.0.0.2` bug proved host-side checks say nothing about client experience
- `wifi-ap` restores broadcasting, and a phone can join and load `http://10.0.0.1/`
- `10.0.0.1` is present after `wifi-ap` — the address restore in step 3 is the step most likely to
  be missed, and its absence looks like a working AP that hands out no useful route
- Reboot while in client mode returns to AP mode unaided
- `update-system` while in client mode completes successfully — the whole point of the feature

## Files touched

- `nixos/modules/aliases.nix` — `wifi-client`, `wifi-ap`, and the mode line in `gallery-status`
- `docs/alice.md` — an administration section; explicitly **not** the attendant workflow
- `README.md` — alias table

No changes to `wifi-ap.nix`: the toggle is deliberately runtime-only, so the declarative config stays
the single description of the intended resting state.
