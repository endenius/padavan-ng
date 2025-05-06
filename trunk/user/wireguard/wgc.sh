#!/bin/sh

###

WG="wg"
IF_NAME="wg0"
IF_ADDR=$(nvram get vpnc_wg_if_addr)
IF_MTU=$(nvram get vpnc_wg_mtu)
[ "$IF_MTU" ] || IF_MTU=1420
IF_PRIVATE=$(nvram get vpnc_wg_if_private)
IF_PRESHARED=$(nvram get vpnc_wg_if_preshared)
PEER_PUBLIC=$(nvram get vpnc_wg_peer_public)
PEER_ENDPOINT=$(nvram get vpnc_wg_peer_endpoint)
PEER_KEEPALIVE=$(nvram get vpnc_wg_peer_keepalive)
PEER_ALLOWEDIPS=$(nvram get vpnc_wg_peer_allowedips)
POST_SCRIPT="/etc/storage/vpnc_server_script.sh"
NETWORK_LIST="/etc/storage/vpnc_remote_network.list"

FWMARK=51820
WAN_ADDR=$(ip addr show $(nvram get wan_ifname) | awk '/inet/{print $2}' | grep -Eo "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+")

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
}

setconf_wg()
{
    is_started || return 1

    cat > "/tmp/${IF_NAME}.conf.$$" <<EOF
[Interface]
PrivateKey = $IF_PRIVATE

[Peer]
PublicKey = $PEER_PUBLIC
Endpoint = $PEER_ENDPOINT
PersistentKeepalive = $PEER_KEEPALIVE
AllowedIPs = $PEER_ALLOWEDIPS
EOF
    [ "$IF_PRESHARED" ] && echo "PresharedKey = $IF_PRESHARED" >> "/tmp/${IF_NAME}.conf.$$"

    local res=$($WG setconf $IF_NAME "/tmp/${IF_NAME}.conf.$$" 2>&1)
    rm -f "/tmp/${IF_NAME}.conf.$$"
    if ! echo $res | grep -q "error"; then
        log "configuration $IF_NAME applied successfully"
        $WG show $IF_NAME | grep -A 5 "peer:" | while read i; do
            log "  $i"
        done
    else
        echo "$res" | while read i; do
            log "$i"
        done
        return 1
    fi
}

start_wg()
{
    local i

    [ "$(nvram get vpnc_type)" == "3" -a "$(nvram get vpnc_enable)" == "1" ] || die "disabled"
    is_started && die "already started"

    prepare_wg

    ip link add dev $IF_NAME type wireguard || error "cannot create $IF_NAME"
    ip link set dev $IF_NAME mtu $IF_MTU

    for i in $(echo "$IF_ADDR" | tr ',' '\n'); do
        ip addr add $i dev $IF_NAME 2>/dev/null || log "warning: cannot set $IF_NAME address $i"
    done

    local if_ip=$(ip addr show dev $IF_NAME | awk '/inet/{print $2}')
    [ "$if_ip" ] || error "$IF_NAME interface address not set"

    setconf_wg || die

    if ip link set $IF_NAME up; then
        log "client started, interface: $IF_NAME, addresses: "$if_ip
    else
        error "$IF_NAME startup failed"
    fi

    ip route replace default dev $IF_NAME table $FWMARK || error "unable to add default to table $FWMARK"

    if [ "$(nvram get vpnc_dgw)" == "1" ]; then
        # default wg enable
        wg set $IF_NAME fwmark $FWMARK

        ip rule add not fwmark $FWMARK table $FWMARK
        ip rule add table main suppress_prefixlength 0
        [ "$WAN_ADDR" ] && ip rule add from $WAN_ADDR lookup main

        sysctl -q net.ipv4.conf.all.src_valid_mark=1

        log "default route set"
    else
        [ -s $NETWORK_LIST ] && while read i; do
            ip rule add to $i table $FWMARK pref 5182 || log "warning: unable to add rule to $i"
        done < $NETWORK_LIST

        $WG show $IF_NAME allowed-ips | awk '{ for (i=2; i<=NF; i++) print $i }' | while read i; do
            echo $i | grep -qE "/0" && continue
            ip rule add to $i table $FWMARK pref 5182 || log "warning: unable to add rule to $i"
        done

        local endpoint=$($WG show $IF_NAME endpoints | awk -F'[\t:]' '/[0-9]\.[0-9]/{print $2}')
        [ "$endpoint" ] && ip rule add to $endpoint lookup main
    fi
}

stop_wg()
{
    local i

    if is_started; then
        ip route del default table $FWMARK 2>/dev/null
        while ip rule del table $FWMARK 2>/dev/null; do true; done

        for i in $(ip rule show | awk -F: '/from all lookup main suppress_prefixlength 0/{print $1}'); do
            ip rule del pref $i 2>/dev/null;
        done

        [ "$WAN_ADDR" ] && ip rule del from $WAN_ADDR lookup main 2>/dev/null

        local endpoint=$($WG show $IF_NAME endpoints | awk -F'[\t:]' '/[0-9]\.[0-9]/{print $2}')
        [ "$endpoint" ] && ip rule del to $endpoint lookup main

        ip link set $IF_NAME down
        ip link del dev $IF_NAME

        log "client stopped"
    fi
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
esac

IFNAME=$IF_NAME
# first interface address
IPLOCAL=$(echo "$IF_ADDR" | tr ',' '\n' | head -n1)
# IF_PRIVATE
# PEER_PUBLIC
# PEER_ENDPOINT
# PEER_KEEPALIVE
# PEER_ALLOWEDIPS

[ -s "$POST_SCRIPT" -a -x "$POST_SCRIPT" ] && . "$POST_SCRIPT"
