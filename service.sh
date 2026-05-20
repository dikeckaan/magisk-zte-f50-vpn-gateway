#!/system/bin/sh
#
# vpn-gateway (F50 fork) — based on Kr328/vpn-gateway v1.1
# Upstream: https://github.com/Kr328/vpn-gateway  (MIT-style header in repo)
#
# F50-specific changes (kaandikec):
#   * Tailscale-aware exception: traffic destined for the Tailscale CGNAT
#     range (100.64.0.0/10) is forced through the main routing table at a
#     priority *higher* than the tun0 policy rules below. This stops
#     replies from on-device services (e.g. sipserver) destined for a
#     Tailscale peer from being misrouted into the VPN tunnel and lost.
#   * The exception is installed both at boot and on every rt_tables
#     refresh, so it survives Tailscale restarts.

TUN_NAME=tun0
TAILSCALE_IF=tailscale0
TAILSCALE_CGNAT=100.64.0.0/10
TAILSCALE_RULE_PREF=9990     # lower number = higher prio; must beat the
                              # 17000-range Android UID rules + the 5030+
                              # rules this script installs further down.

ip="/system/bin/ip"
iptables="/system/bin/iptables"
ip6tables="/system/bin/ip6tables"

if [[ ! -x $ip ]] || [[ ! -x $iptables ]]; then
    echo "command 'ip' or 'iptables' not found"
    exit 1
fi

function assert() {
    if ! "$@"; then
        echo "'$*' failed"

        clean_rules

        exit 1
    fi
}

function ip_rules_for() {
    local tun_name=$1
    local tun_table_index=$2

    cat <<EOF
iif lo goto 6000 pref 5000
iif $tun_name lookup main suppress_prefixlength 0 pref 5010
iif $tun_name goto 6000 pref 5020
from 10.0.0.0/8 lookup $tun_table_index pref 5030
from 172.16.0.0/12 lookup $tun_table_index pref 5040
from 192.168.0.0/16 lookup $tun_table_index pref 5050
nop pref 6000
EOF
}

function iptables_rules_for() {
    local tun_name=$1

    cat <<EOF
FORWARD -s 10.0.0.0/8 -o $tun_name -j ACCEPT
FORWARD -s 172.16.0.0/12 -o $tun_name -j ACCEPT
FORWARD -s 192.168.0.0/16 -o $tun_name -j ACCEPT
FORWARD -i $tun_name -j ACCEPT
PREROUTING -t nat ! -i $tun_name -s 10.0.0.0/8 -p udp --dport 53 -j DNAT --to 1.1.1.1
PREROUTING -t nat ! -i $tun_name -s 172.16.0.0/12 -p udp --dport 53 -j DNAT --to 1.1.1.1
PREROUTING -t nat ! -i $tun_name -s 192.168.0.0/16 -p udp --dport 53 -j DNAT --to 1.1.1.1
EOF
}

# F50 patch: install a high-prio rule that pins Tailscale CGNAT traffic to
# the main table (which already has a tailscale0 route maintained by the
# tailscaled daemon). Idempotent — delete first, then add.
function install_tailscale_exception() {
    $ip rule del to $TAILSCALE_CGNAT lookup main pref $TAILSCALE_RULE_PREF 2>/dev/null
    $ip rule add to $TAILSCALE_CGNAT lookup main pref $TAILSCALE_RULE_PREF 2>/dev/null

    # If tailscale0 is up and the main table doesn't already have a CGNAT
    # route via it, add one (low metric so it wins). Most installs have
    # this populated by tailscaled anyway.
    if $ip link show $TAILSCALE_IF >/dev/null 2>&1; then
        local ts_ip
        ts_ip=$($ip -4 addr show $TAILSCALE_IF 2>/dev/null | awk '/inet /{sub("/.*","",$2); print $2; exit}')
        if [[ -n "$ts_ip" ]] && ! $ip route show $TAILSCALE_CGNAT 2>/dev/null | grep -q "$TAILSCALE_IF"; then
            $ip route add $TAILSCALE_CGNAT dev $TAILSCALE_IF src "$ts_ip" metric 50 2>/dev/null
        fi
    fi
}

function remove_tailscale_exception() {
    $ip rule del to $TAILSCALE_CGNAT lookup main pref $TAILSCALE_RULE_PREF 2>/dev/null
}

function read_table_index() {
    local iface=$1

    cat /data/misc/net/rt_tables | while read -r index name; do
        if [[ "$name" = "$iface" ]]; then
            echo $index
            return 0
        fi
    done

    return 1
}

function cleanup() {
    local tun_name=$1
    local tun_table_index=$2

    iptables_rules_for $tun_name | while read -r rule; do
        $iptables -D $rule 2>/dev/null
    done

    ip_rules_for $tun_name $tun_table_index | while read -r rule; do
        $ip rule del $rule 2>/dev/null
    done

    $ip6tables -D FORWARD -j REJECT --reject-with icmp6-no-route
}

function setup() {
    local tun_name=$1
    local tun_table_index=$2

    cleanup $tun_name $tun_table_index

    iptables_rules_for $tun_name | while read -r rule; do
        $iptables -I $rule
    done

    ip_rules_for $tun_name $tun_table_index | while read -r rule; do
        $ip rule add $rule
    done

    $ip6tables -I FORWARD -j REJECT --reject-with icmp6-no-route

    # F50 patch
    install_tailscale_exception
}

while [[ ! -f /data/misc/net/rt_tables ]]; do
    sleep 5
done

tun_table_index=$(read_table_index $TUN_NAME)
echo "Initialize: $TUN_NAME $tun_table_index"

if [[ ! -z "$tun_table_index" ]]; then
    setup $TUN_NAME $tun_table_index
fi

# F50 patch: even if tun_table_index is empty (tun0 down), still install
# the Tailscale exception so a fresh tailscale boot is reachable.
install_tailscale_exception

echo 1 > /proc/sys/net/ipv4/ip_forward
echo 0 > /dev/ip_forward_stub
chown $(stat -c '%u:%g' /data/misc/net/rt_tables) /dev/ip_forward_stub
chcon $(stat -Z -c '%C' /data/misc/net/rt_tables) /dev/ip_forward_stub
mount -o bind /dev/ip_forward_stub /proc/sys/net/ipv4/ip_forward

inotifyd - /data/misc/net::w | while read -r event; do
    sleep 1

    tun_table_index_new=$(read_table_index $TUN_NAME)
    if [[ "$tun_table_index" != "$tun_table_index_new" ]]; then
        echo "Network changed: $TUN_NAME $tun_table_index_new"

        cleanup $TUN_NAME $tun_table_index

        tun_table_index=$tun_table_index_new

        if [[ ! -z "$tun_table_index" ]]; then
            setup $TUN_NAME $tun_table_index
        fi
    fi

    # F50 patch: re-assert the Tailscale exception on every rt_tables
    # change (e.g. tailscale up/down toggles), idempotent.
    install_tailscale_exception
done
