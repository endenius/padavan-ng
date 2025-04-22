#!/bin/sh

###

WG="wg"
IF_NAME="wg0"
IF_ADDR=$(nvram get vpnc_wg_if_addr)
IF_PRIVATE=$(nvram get vpnc_wg_if_private)
IF_PRESHARED=$(nvram get vpnc_wg_if_preshared)
PEER_PUBLIC=$(nvram get vpnc_wg_peer_public)
PEER_ENDPOINT=$(nvram get vpnc_wg_peer_endpoint)
PEER_KEEPALIVE=$(nvram get vpnc_wg_peer_keepalive)
PEER_ALLOWEDIPS=$(nvram get vpnc_wg_peer_allowedips)
POST_SCRIPT="/etc/storage/vpnc_server_script.sh"
NETWORK_LIST="/etc/storage/vpnc_remote_network.list"

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
    echo 1 > /proc/sys/net/ipv4/ip_forward
    echo 0 > /proc/sys/net/ipv4/conf/all/accept_redirects
    echo 0 > /proc/sys/net/ipv4/conf/all/send_redirects
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
    [ "$(nvram get vpnc_type)" == "3" -a "$(nvram get vpnc_enable)" == "1" ] || die "disabled"
    is_started && die "already started"

    prepare_wg

    ip link add dev $IF_NAME type wireguard || error "cannot create $IF_NAME"
    ip link set dev $IF_NAME mtu 1420

    for i in $(echo "$IF_ADDR" | tr ',' '\n'); do
        ip addr add $i dev $IF_NAME || log "warning: cannot set $IF_NAME address $i"
    done

    local if_ip=$(ip addr show dev $IF_NAME | awk '/inet /{print $2}')
    [ "$if_ip" ] || error "$IF_NAME interface address not set"

    setconf_wg || die

    if ip link set $IF_NAME up; then
        log "client started, interface: $IF_NAME, addresses: "$if_ip
    else
        error "$IF_NAME startup failed"
    fi

    if [ "$(nvram get vpnc_dgw)" == "1" ]; then
        # default wg enable
        for i in $($WG show $IF_NAME endpoints | awk -F'[\t:]' '/[0-9]\.[0-9]/{print $2}'); do
            ip route add $(ip route get $i \
                | sed '/ via [0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}/{s/^\(.* via [0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\).*/\1/}' \
                | head -n 1) metric 1
        done
        ip route add 0.0.0.0/128.0.0.0 dev $IF_NAME metric 1
        ip route add 128.0.0.0/128.0.0.0 dev $IF_NAME metric 1
        log "default route set"
    else
        [ -s $NETWORK_LIST ] && while read i; do
            ip route add $i dev $IF_NAME metric 1 || log "warning: unable to add route to $i"
        done < $NETWORK_LIST
    fi

    $WG show $IF_NAME allowed-ips | awk '{ for (i=2; i<=NF; i++) print $i }' | while read i; do
        echo $i | grep -qE ":|0\.0\.0\.0\/0" && continue
        ip route add $i dev $IF_NAME 2> /dev/null
    done
}

stop_wg()
{
    if is_started; then
        for i in $($WG show $IF_NAME endpoints | awk -F'[\t:]' '/[0-9]\.[0-9]/{print $2}'); do
            ip route del $(ip route get $i \
                | sed '/ via [0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}/{s/^\(.* via [0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\).*/\1/}' \
                | head -n 1) 2>/dev/null
        done
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
