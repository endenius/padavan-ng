#!/bin/sh

IF_NAME="wg0"
IF_ADDR=$(nvram get vpnc_wg_if_addr)
IF_PRIVATE=$(nvram get vpnc_wg_if_private)
PEER_PUBLIC=$(nvram get vpnc_wg_peer_public)
PEER_ENDPOINT=$(nvram get vpnc_wg_peer_endpoint)
PEER_KEEPALIVE=$(nvram get vpnc_wg_peer_keepalive)
PEER_ALLOWEDIPS=$(nvram get vpnc_wg_peer_allowedips)

POST_SCRIPT="/etc/storage/wireguard_client_script.sh"

log()
{
    [ -n "$*" ] || return
    echo "$@"
    logger -t wireguard "$@"
}

error()
{
    log "$@"
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
    is_started || return 0

    cat > "/tmp/${IF_NAME}.conf.$$" <<EOF
[Interface]
PrivateKey = $IF_PRIVATE

[Peer]
PublicKey = $PEER_PUBLIC
Endpoint = $PEER_ENDPOINT
PersistentKeepalive = $PEER_KEEPALIVE
AllowedIPs = $PEER_ALLOWEDIPS
EOF

    local res=$(wg setconf ${IF_NAME} "/tmp/${IF_NAME}.conf.$$" 2>&1)
    rm -f "/tmp/${IF_NAME}.conf.$$"
    if ! echo $res | grep -q "error"; then
        log "configuration $IF_NAME applied successfully, endpoint: $(wg show $IF_NAME endpoints | awk '{print $2}')"
    else
        log "$res"
        return 1
    fi
}

start_wg()
{

    [ "$(nvram get vpnc_type)" == "3" -a "$(nvram get vpnc_enable)" == "1" ] || die "disabled"

    is_started && die "already started"
    prepare_wg

    ip link add dev ${IF_NAME} type wireguard || error "cannot create $IF_NAME"
    ip addr add ${IF_ADDR} dev ${IF_NAME}
    ip link set dev $IF_NAME mtu 1420

    if ip link set ${IF_NAME} up; then
        log "client started, interface: ${IF_NAME}, address: ${IF_ADDR}"
    else
        ip link del ${IF_NAME} >/dev/null 2>&1
        die "${IF_NAME} startup failed"
    fi

    setconf_wg || die

    if [ "$(nvram get vpnc_dgw)" == "1" ]; then
        # default wg enable
        host="$(wg show $IF_NAME endpoints | sed -n 's/.*\t\(.*\):.*/\1/p')"
        ip route add $(ip route get $host |\
           sed '/ via [0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}/{s/^\(.* via [0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\).*/\1/}' | head -n 1)
        ip route add 0.0.0.0/128.0.0.0 dev $IF_NAME
        ip route add 128.0.0.0/128.0.0.0 dev $IF_NAME
    fi
}

stop_wg()
{
    if is_started; then
        host="$(wg show $IF_NAME endpoints 2>/dev/null | sed -n 's/.*\t\(.*\):.*/\1/p')"
        [ "$host" ] && ip route del $(ip route get $host |\
             sed '/ via [0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}/{s/^\(.* via [0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\).*/\1/}' | head -n 1) 2>/dev/null || true
        ip link del dev $IF_NAME 2>/dev/null
        log "client stopped"
    fi
}

case $1 in
    start|up)
        start_wg
    ;;

    stop|down)
        stop_wg
    ;;

    restart)
        stop_wg
        start_wg
    ;;
esac

# IF_NAME
# IF_ADDR
# IF_PRIVATE
# PEER_PUBLIC
# PEER_ENDPOINT
# PEER_KEEPALIVE
# PEER_ALLOWEDIPS

[ -s "$POST_SCRIPT" -a -x "$POST_SCRIPT" ] && . "$POST_SCRIPT"
