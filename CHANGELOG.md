# Changelog

## v1.1.1-f50 — 2026-05-20

F50 fork of [Kr328/vpn-gateway](https://github.com/Kr328/vpn-gateway) v1.1.

### Why a fork

Stock Kr328/vpn-gateway is correct for hotspot LAN forwarding, but on
a Magisk install that **also** runs Tailscale, the kernel ends up
sending replies destined to a Tailscale peer (100.64.0.0/10) out through
`tun0` because:

1. Some VPN client (clash / sing-box / openclash) populates the `tun0`
   routing table with `64.0.0.0/2 dev tun0` — a sweeping link route
   that covers Tailscale's CGNAT range as a side effect.
2. Android's UID-based ip rules at pref 17000 send root-owned traffic
   through `tun0`.

Result: services on the F50 (sipserver, dropbear, etc.) reach Tailscale
peers (the REQUEST arrives via tailscale0) but the REPLY leaves via
tun0, source IP 10.10.14.1 (or whatever the VPN tunnel uses). The
peer never sees the reply.

### Fix

Added one high-priority ip rule:

```
ip rule add to 100.64.0.0/10 lookup main pref 9990
```

- Pref 9990 is lower (= higher priority) than both the 17000-range
  Android UID rules and the 5030+ rules Kr328 installs.
- Main table already has tailscale0 reach (tailscaled puts it there).
- If tailscale0 is up but main table doesn't carry the CGNAT route, the
  script also drops one in (`metric 50`).
- Re-asserted on every `inotifyd` event on `/data/misc/net/`, so it
  survives `tailscale up/down` toggles, fwmark switches, and the
  tun_table_index refresh that Kr328's loop already watches for.

Idempotent (delete-before-add). Cleanup removes both the original
Kr328 rules and the Tailscale exception.

### Credit

Original logic + structure: Kr328 (<https://github.com/Kr328/vpn-gateway>).
F50-specific patches: kaandikec.
