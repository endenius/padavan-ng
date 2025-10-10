#!/bin/sh

###

WG="wg"
IF_NAME="wg0"
IF_ADDR=$(nvram get vpnc_wg_if_addr)
IF_MTU=$(nvram get vpnc_wg_mtu)
[ "$IF_MTU" ] || IF_MTU=1420
IF_PRIVATE=$(nvram get vpnc_wg_if_private)
IF_PRESHARED=$(nvram get vpnc_wg_if_preshared)
IF_DNS=$(nvram get vpnc_wg_if_dns | tr -d ' ')

unset DEFAULT
[ "$(nvram get vpnc_dgw)" == "1" ] && DEFAULT=1

PEER_PUBLIC=$(nvram get vpnc_wg_peer_public)
PEER_PORT=$(nvram get vpnc_wg_peer_port)
PEER_ENDPOINT="$(nvram get vpnc_wg_peer_endpoint)${PEER_PORT:+":$PEER_PORT"}"
PEER_KEEPALIVE=$(nvram get vpnc_wg_peer_keepalive)
PEER_ALLOWEDIPS="$(nvram get vpnc_wg_peer_allowedips | tr -d ' ')"
POST_SCRIPT="/etc/storage/vpnc_server_script.sh"
REMOTE_NETWORK_LIST="/etc/storage/vpnc_remote_network.list"
EXCLUDE_NETWORK_LIST="/etc/storage/vpnc_exclude_network.list"
CLIENTS_LIST="/etc/storage/vpnc_clients.list"

FWMARK=51820
TABLE=51

PREF_WG=5182
PREF_MAIN=5181

LAN_ADDR=$(nvram get lan_ipaddr)
WAN_ADDR=$(nvram get wan_ipaddr)
WAN0_ADDR=$(nvram get wan0_ipaddr)
WAN0_IFNAME=$(nvram get wan0_ifname)
WAN0_GW=$(nvram get wan0_gateway)

# if iproute2 is not available, when ipv6 disable
IPBB=$(ip 2>&1 | grep -i busybox)
IPV6=$(ip -6 route show default)

IPSET="/sbin/ipset"

IPT_WG_CHAIN="vpnc_wireguard"
IPT_WG_REMOTE="vpnc_wireguard_remote"

# iphash from dnsmasq
DNSMASQ_IPSET="unblock"
# nethash custom list of remote networks, filled in by user from console
CUSTOM_REMOTE_IPSET="custom.remote"

# nethash remote networks
VPN_REMOTE_IPSET="vpn.remote"
# nethash excluded remote networks
VPN_EXCLUDE_IPSET="vpn.exclude"
# nethash allowed LAN clients
VPN_CLIENTS_IPSET="vpn.clients"

###

log()
{
    [ -n "$*" ] || return
    echo "$@"
    logger -t wireguard "$@"
}

error()
{
    log "error: $@"
    exit 1
}

die()
{
    echo "$@" >&2
    exit 1
}

is_started()
{
    ip link show ${IF_NAME} >/dev/null 2>&1
    return $?
}

prepare_wg()
{
    modprobe -q wireguard >/dev/null 2>&1
    sysctl -q net.ipv4.conf.all.src_valid_mark=1
    sysctl -q net.ipv6.conf.all.disable_ipv6=0 2>/dev/null
    sysctl -q net.ipv6.conf.all.forwarding=1 2>/dev/null
}

wg_setdns()
{
    [ "$IF_DNS" ] || return

    local getdns=$(nvram get vpnc_pdns)
    [ "$getdns" == "0" ] && return

    nvram set vpnc_dns_t="$IF_DNS"

    if [ "$getdns" == "2" ]; then
        sed -i "/nameserver/d" /etc/resolv.conf
        echo "nameserver 127.0.0.1" >> /etc/resolv.conf
    fi

    for i in $(echo "$IF_DNS" | tr ',' '\n'); do
        grep -qE "nameserver ${i}\s*$" /etc/resolv.conf \
            || echo "nameserver $i" >> /etc/resolv.conf
    done

    restart_dns
}

setconf_wg()
{
    is_started || return 1

    if ! ip addr show $IF_NAME | grep -q "inet6"; then
        PEER_ALLOWEDIPS=$(echo "$PEER_ALLOWEDIPS" | tr -s ',' '\n' | grep -v ':' | tr -s '\n' ',' | sed 's/,$//')
    fi

    cat > "/tmp/${IF_NAME}.conf.$$" <<EOF
[Interface]
PrivateKey = $IF_PRIVATE
FwMark = $FWMARK

[Peer]
PublicKey = $PEER_PUBLIC
Endpoint = $PEER_ENDPOINT
PersistentKeepalive = $PEER_KEEPALIVE
AllowedIPs = $PEER_ALLOWEDIPS
EOF
    [ "$IF_PRESHARED" ] && echo "PresharedKey = $IF_PRESHARED" >> "/tmp/${IF_NAME}.conf.$$"

    [ ! "$IPV6" ] && echo "precedence ::ffff:0:0/96  100" > /etc/gai.conf
    local res=$($WG setconf $IF_NAME "/tmp/${IF_NAME}.conf.$$" 2>&1)
    rm -f "/tmp/${IF_NAME}.conf.$$"
    [ ! "$IPV6" ] && rm -f /etc/gai.conf

    if ! echo $res | grep -q "error"; then
        log "configuration $IF_NAME applied successfully"
        $WG show $IF_NAME | grep -A 5 "peer:" | while read i; do
            log "$i"
        done
    else
        echo "$res" | while read i; do
            log "$i"
        done
        return 1
    fi
}

add_default_route()
{
    ip rule add fwmark $FWMARK table $TABLE pref $PREF_WG
    ip route add default dev $IF_NAME table $TABLE \
        && log "add default route dev $IF_NAME table $TABLE" \
        || log "unable to add default route dev $IF_NAME table $TABLE"
}

add_route()
{
    add_default_route

    # for local cloudflare warp support on the router
    # padavan does not support nat64
    [ ! "$IPV6" ] && ip addr show $IF_NAME | grep -q "inet6" \
        && ip -6 route add default dev $IF_NAME metric 1024
}

prevent_access_loss()
{
    local i endpoint

    endpoint=$($WG show $IF_NAME endpoints | sed -r 's/^.+\t//; s/:[0-9]+$//')
    [ "$endpoint" ] && ip rule add to "$endpoint" table main pref $PREF_MAIN

    for i in $LAN_ADDR $WAN_ADDR $WAN0_ADDR; do
        [ "$i" = "0.0.0.0" ] && continue
            ip rule add from "$i" lookup main pref $PREF_MAIN
    done
}

wg_if_init()
{
    local i p

    prepare_wg

    ip link add dev $IF_NAME type wireguard || error "cannot create $IF_NAME"
    ip link set dev $IF_NAME mtu $IF_MTU

    for i in $(echo "$IF_ADDR" | tr ',' '\n'); do
        p=4; [ "$i" != "${i#*:}" ] && p=6
        ip -$p addr add "$i" dev $IF_NAME 2>/dev/null || log "warning: cannot set $IF_NAME address $i"
    done

    local if_ip=$(ip addr show dev $IF_NAME | awk '/inet/{print $2}')
    [ "$if_ip" ] || error "$IF_NAME interface address not set"

    setconf_wg || die

    if ip link set $IF_NAME up; then
        log "client started, interface: $IF_NAME, addresses: "$if_ip
    else
        error "$IF_NAME startup failed"
    fi
}

send_ping()
{
    # trying to sending single packet trought wg interface for activating the connection web-indicator
    ping -c1 -W1 -I $IF_NAME 8.8.8.8 >/dev/null 2>&1 &
}

start_wg()
{
    [ "$(nvram get vpnc_type)" == "3" -a "$(nvram get vpnc_enable)" == "1" ] || die "disabled"
    is_started && die "already started"

    wg_if_init

    prevent_access_loss
    add_route
    ipset_create
    start_fw

    wg_setdns
    send_ping
}

stop_wg()
{
    local i p

    is_started || return

    [ "$IPBB" ] && ip route del default table $TABLE 2>/dev/null

    for i in $PREF_MAIN $PREF_WG; do
        while ip rule del pref $i 2>/dev/null; do true; done
    done

    ip link set $IF_NAME down
    ip link del dev $IF_NAME

    stop_fw

    log "client stopped"
}

stop_fw()
{
    local i

    iptables -t mangle -D PREROUTING -t mangle -j $IPT_WG_CHAIN 2>/dev/null
    iptables -t mangle -D OUTPUT -t mangle -j $IPT_WG_CHAIN 2>/dev/null

    for i in $IPT_WG_CHAIN $IPT_WG_REMOTE; do
        iptables -t mangle -F $i 2>/dev/null
        iptables -t mangle -X $i 2>/dev/null
    done
}

filter_ipv4()
{
    grep -E -x '^((25[0-5]|2[0-4][0-9]|1[0-9]{2}|0?[0-9]{1,2})\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|0?[0-9]{1,2})(/(3[0-2]|[12]?[0-9]))?$' \
    | sed -r 's#/32|/0##g' | sort | uniq
}

ipset_load()
{
    local name="$1"
    local list="$2"

    [ -s "$list" ] || return

    echo -n > /tmp/$name.ipset.$$
    for i in $(cat "$list" | filter_ipv4); do
        echo "add $name $i" >> /tmp/$name.ipset.$$
    done

    if [ ! -s /tmp/$name.ipset.$$ ]; then
        rm -f /tmp/$name.ipset.$$
        return
    fi

    res=$(cat /tmp/$name.ipset.$$ | ipset restore 2>&1)
    if [ $? = 0 ]; then
        log "ipset $name updated"
    else
        log "ipset $name: $res"
    fi

    rm -f /tmp/$name.ipset.$$
}

ipset_create()
{
    # create ipset ipv4 entrys

    [ -x "$IPSET" ] || return

    ipset -N $DNSMASQ_IPSET iphash timeout 3600 2>/dev/null
    ipset -N $CUSTOM_REMOTE_IPSET nethash 2>/dev/null

    ipset -N $VPN_REMOTE_IPSET nethash 2>/dev/null
    ipset flush $VPN_REMOTE_IPSET 2>/dev/null

    ipset -N $VPN_EXCLUDE_IPSET nethash 2>/dev/null
    ipset flush $VPN_EXCLUDE_IPSET 2>/dev/null

    ipset -N $VPN_CLIENTS_IPSET nethash 2>/dev/null
    ipset flush $VPN_CLIENTS_IPSET 2>/dev/null

    ipset_load $VPN_REMOTE_IPSET $REMOTE_NETWORK_LIST
    ipset_load $VPN_EXCLUDE_IPSET $EXCLUDE_NETWORK_LIST
    ipset_load $VPN_CLIENTS_IPSET $CLIENTS_LIST
}

ipt_set_rules()
{
    local i

    if [ -x "$IPSET" ]; then
        echo "-A $IPT_WG_CHAIN -m set --match-set $VPN_EXCLUDE_IPSET dst -j RETURN"
        echo "-A $IPT_WG_CHAIN -m set ! --match-set $VPN_CLIENTS_IPSET src -j RETURN"

        if [ "$DEFAULT" ]; then
            echo "-A $IPT_WG_CHAIN -j MARK --set-mark $FWMARK"
        else
            echo "-A $IPT_WG_CHAIN -m set --match-set $DNSMASQ_IPSET dst -j MARK --set-mark $FWMARK"
            echo "-A $IPT_WG_CHAIN -m set --match-set $VPN_REMOTE_IPSET dst -j MARK --set-mark $FWMARK"
            echo "-A $IPT_WG_CHAIN -m set --match-set $CUSTOM_REMOTE_IPSET dst -j MARK --set-mark $FWMARK"
        fi
    else
        for i in $(cat "$EXCLUDE_NETWORK_LIST" | filter_ipv4); do
            echo "-A $IPT_WG_CHAIN -d $i -j RETURN"
        done

        for i in $(cat "$CLIENTS_LIST" | filter_ipv4); do
            echo "-A $IPT_WG_CHAIN -s \"$i\" -j $IPT_WG_REMOTE"
        done

        if [ "$DEFAULT" ]; then
            echo "-A $IPT_WG_REMOTE -j MARK --set-mark $FWMARK"
        else
            for i in $(cat "$REMOTE_NETWORK_LIST" | filter_ipv4); do
                echo "-A $IPT_WG_REMOTE -d \"$i\" -j MARK --set-mark $FWMARK"
            done
        fi
    fi
}

start_fw()
{
    stop_fw

    iptables-restore -n <<EOF
*mangle
:$IPT_WG_CHAIN - [0:0]
:$IPT_WG_REMOTE - [0:0]
-I PREROUTING -j $IPT_WG_CHAIN
-I OUTPUT -j $IPT_WG_CHAIN
-A $IPT_WG_CHAIN -p udp --dport 53 -j RETURN
-A $IPT_WG_CHAIN -p tcp --dport 53 -j RETURN
-A $IPT_WG_CHAIN -p udp --dport 123 -j RETURN
$(ipt_set_rules)
COMMIT
EOF
    [ $? -eq 0 ] || error "firewall rules update failed"
}

case $1 in
    start)
        start_wg
    ;;

    stop)
        stop_wg
    ;;

    restart)
        stop_wg
        start_wg
    ;;

    reload)
        is_started && start_fw
    ;;

    ipset-update)
        ipset_create
    ;;
esac

IFNAME=$IF_NAME

[ -s "$POST_SCRIPT" -a -x "$POST_SCRIPT" ] && . "$POST_SCRIPT"
