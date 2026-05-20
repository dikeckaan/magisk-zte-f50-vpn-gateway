# vpn-gateway (ZTE F50 fork)

Fork of [**Kr328/vpn-gateway**](https://github.com/Kr328/vpn-gateway) with one
F50-specific patch: a Tailscale-aware exception that stops the kernel
from misrouting replies destined for Tailscale peers through the VPN
tunnel.

## What the upstream module does

Kr328's `vpn-gateway` lets a Magisk-rooted Android device act as a VPN
gateway for the local network:

- Hotspot clients (RFC1918 ranges: `10.0.0.0/8`, `172.16.0.0/12`,
  `192.168.0.0/16`) have their traffic looked up in the `tun0` routing
  table — so whatever VPN client owns tun0 (Clash, sing-box, OpenClash,
  …) gets to handle their packets.
- `iptables FORWARD` ACCEPTs the RFC1918 → tun0 path and ACCEPTs return
  traffic.
- DNS DNAT to `1.1.1.1` for RFC1918 sources (so split-tunnel apps that
  hardcode the router IP still get reasonable DNS).

## What this fork adds

A single `ip rule` plus a route guard, both idempotent:

```sh
ip rule add to 100.64.0.0/10 lookup main pref 9990
# and, if needed:
ip route add 100.64.0.0/10 dev tailscale0 src <ts-ip> metric 50
```

`pref 9990` beats Android's UID-based pref-17000 rules and Kr328's own
pref-5030 rules, so any traffic destined to a Tailscale CGNAT peer
goes through `tailscale0` instead of getting swallowed by the
`64.0.0.0/2 dev tun0` link route some VPN clients drop into the tun0
table.

Re-asserted on every `/data/misc/net/` change, so it survives:

- `tailscale up` / `tailscale down`
- VPN client restarts
- Magisk module disable/enable cycles

### Why this matters on F50

On the F50 we run both Tailscale (`tailscale0`) and a local VPN client
on `tun0`. Without the fix:

- `sipserver` listening on `*:5060` receives a REGISTER from a Tailscale
  peer fine.
- But its 401 reply gets routed via `tun0` with source IP `10.10.14.1`.
- The peer never sees the reply → keeps retrying without auth → looks
  exactly like a broken-password loop.

With the fix the reply leaves via `tailscale0` with source IP
`100.x.x.x`, the peer authenticates on the first round-trip, and SIP
registration succeeds.

## Dependencies

- A Magisk install with a tun0-owning VPN client already running (this
  module doesn't bring its own VPN — it only wires the routes).
- Optional: `tailscale-control` module for the Tailscale interface. If
  `tailscale0` doesn't exist, the patch is a no-op.

## Install

```bash
adb push vpn-gateway-v1.1.1-f50.zip /sdcard/
adb shell su -c "magisk --install-module /sdcard/vpn-gateway-v1.1.1-f50.zip"
adb reboot
```

After reboot, verify:

```sh
adb shell su -c "ip rule | grep 9990"
# Expected:
# 9990:  from all to 100.64.0.0/10 lookup main

adb shell su -c "ip route get 100.85.20.36"
# Should now use tailscale0 (not tun0).
```

## Rollback

```bash
adb shell "echo 1 > /data/adb/modules/vpn-gateway/disable" && adb reboot
```

## Credits

Upstream author: [Kr328](https://github.com/Kr328). All original logic
and structure preserved; this fork only adds a thin Tailscale-aware
patch on top.
