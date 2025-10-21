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
[ "$(nvram get vpnc_dgw)" = "1" ] && DEFAULT=1

PID_WATCHDOG="/var/run/wg_watchdog.pid"

PEER_PUBLIC=$(nvram get vpnc_wg_peer_public)
PEER_PORT=$(nvram get vpnc_wg_peer_port)
PEER_ENDPOINT="$(nvram get vpnc_wg_peer_endpoint)${PEER_PORT:+":$PEER_PORT"}"
PEER_KEEPALIVE=$(nvram get vpnc_wg_peer_keepalive)
PEER_ALLOWEDIPS="$(nvram get vpnc_wg_peer_allowedips | tr -d ' ')"
POST_SCRIPT="/etc/storage/vpnc_server_script.sh"
REMOTE_NETWORK_LIST="/etc/storage/vpnc_remote_network.list"
EXCLUDE_NETWORK_LIST="/etc/storage/vpnc_exclude_network.list"
CLIENTS_LIST="/etc/storage/vpnc_clients.list"

TABLE=51
FWMARK=51820
PREF_WG=5182
PREF_MAIN=5181

DNSMASQ_REMOTE_IPSET="unblock"
CUSTOM_REMOTE_IPSET="custom.remote"

# nethash remote networks
VPN_REMOTE_IPSET="vpn.remote"
# nethash excluded remote networks
VPN_EXCLUDE_IPSET="vpn.exclude"
# nethash allowed LAN clients
VPN_CLIENTS_IPSET="vpn.clients"

###

unset IPSET
[ -x "/sbin/ipset" ] && IPSET=1

log()
{
    [ -n "$*" ] || return
    echo "$@"
    logger -t wireguard "$@"
}

error()
{
    log "error: $@" >&2
    exit 1
}

die()
{
    [ -n "$*" ] && echo "$@" >&2
    exit 1
}

is_started()
{
    ip link show ${IF_NAME} >/dev/null 2>&1
    return $?
}

prepare_wg()
{
    modprobe -q wireguard
    sysctl -q net.ipv4.conf.all.src_valid_mark=1
    sysctl -q net.ipv6.conf.all.disable_ipv6=0 2>/dev/null
    sysctl -q net.ipv6.conf.all.forwarding=1 2>/dev/null
}

wg_setdns()
{
    [ "$IF_DNS" ] || return

    local getdns=$(nvram get vpnc_pdns)
    [ "$getdns" = "0" ] && return

    nvram set vpnc_dns_t="$IF_DNS"

    if [ "$getdns" = "2" ]; then
        sed -i "/nameserver/d" /etc/resolv.conf
        echo "nameserver 127.0.0.1" >> /etc/resolv.conf
    fi

    for i in $(echo "$IF_DNS" | tr ', ' '\n'); do
        grep -q "nameserver[[:space:]]*${i}[[:space:]]*$" /etc/resolv.conf \
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

    echo "precedence ::ffff:0:0/96  100" > /etc/gai.conf
    local res=$($WG setconf $IF_NAME "/tmp/${IF_NAME}.conf.$$" 2>&1)
    rm -f /etc/gai.conf
    rm -f "/tmp/${IF_NAME}.conf.$$"

    [ "$1" = "reconnect" ] && return

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
    # ¯\_(ツ)_/¯
    sync && sysctl -q vm.drop_caches=3
    usleep 100000

    add_default_route

    # for local cloudflare warp support on the router
    # padavan does not support nat64
    ip addr show $IF_NAME | grep -q "inet6" \
        && ip -6 route add default dev $IF_NAME metric 1024

    local ep
    ep=$($WG show $IF_NAME endpoints | sed -r 's/^.+\t//; s/:[0-9]+$//; s/[][]*//g')
    [ -n "$ep" ] || return

    if [ "$ep" == "${ep#*:}" ]; then
        ip rule add to "$ep" table main pref $PREF_MAIN
    else
        ip -6 rule add to "$ep" table main pref $PREF_MAIN
    fi
}

wg_if_init()
{
    local i p

    prepare_wg

    ip link add dev $IF_NAME type wireguard 2>/dev/null || error "cannot create $IF_NAME"
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

reconnect_wg()
{
    # reconnect using current config

    if ! check_connected; then
        [ "$1" ] || log "trying reconnect to $PEER_ENDPOINT"
        setconf_wg reconnect
        check_connected
        if [ $? -eq 0 ]; then
            log "successfully connected"
            return 0
        else
            return 1
        fi
    fi
}

get_latest_handshake()
{
    # return latest handshake in sec

    is_started || return 1

    local lh=$($WG show $IF_NAME latest-handshakes | cut -f2)
    local delta=$(( $(date +'%s') - $lh ))

    case "$lh" in
        0) return 1 ;;

        [0-9]*)
            echo $delta
            if [ "$delta" -gt "300" ]; then
                return 1
            fi
        ;;

        *) return 1 ;;
    esac
}

send_ping()
{
    # trying to sending single packet trought wg interface for activating the connection web-indicator
    ping -c1 -W8 -I $IF_NAME 8.8.8.8 >/dev/null 2>&1
}

check_connected()
{
    get_latest_handshake >/dev/null || send_ping || return 1
}

start_wg()
{
    is_started && die "already started"

    wg_if_init
    add_route
    wg_setdns
    ipset_create

    if check_connected; then
        start_fw
        log "successfully connected"
    else
        stop_fw
        log "connection may be blocked: $PEER_ENDPOINT"
    fi

    start_watchdog &
    echo $! > "$PID_WATCHDOG"
}

start_watchdog()
{
    [ -f "$PID_WATCHDOG" ] || return
    log "connection watchdog timer started"
    sleep 10

    local no_log
    while is_started; do
        if reconnect_wg $no_log; then
            start_fw
            no_log=
        else
            stop_fw
            no_log=1
        fi
        sleep 10
    done

    rm -f "$PID_WATCHDOG"
}

reload_wg()
{
    is_started || return 1

    ipset_create
    update_wg
}

update_wg()
{
    is_started || return 1

    if reconnect_wg no_log; then
        start_fw
    else
        stop_fw
    fi
}

stop_wg()
{
    stop_fw

    ip route flush table $TABLE 2>/dev/null
    ip -6 route del default dev $IF_NAME 2>/dev/null

    while ip rule del pref $PREF_WG 2>/dev/null; do true; done
    while ip rule del pref $PREF_MAIN 2>/dev/null; do true; done
    while ip -6 rule del pref $PREF_MAIN 2>/dev/null; do true; done

    ip link set $IF_NAME down 2>/dev/null
    ip link del dev $IF_NAME 2>/dev/null \
        && log "client stopped"

    if [ -f "$PID_WATCHDOG" ]; then
        kill "$(cat "$PID_WATCHDOG")" 2>/dev/null
        rm -f "$PID_WATCHDOG"
        log "connection watchdog timer stopped"
    fi
}

filter_ipv4()
{
    grep -E -x '^[[:space:]]*((25[0-5]|2[0-4][0-9]|1[0-9]{2}|0?[0-9]{1,2})\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|0?[0-9]{1,2})(/(3[0-2]|[12]?[0-9]))?[[:space:]]*$' \
        | sed -E 's#/32|/0##g' | sort | uniq
}

ipset_load()
{
    # $1: "list" - file list; "" - var with line break

    local mode="$1"
    local name="$2"
    local list="$3"

    [ -n "$name" ] || return
    ipset -N $name nethash 2>/dev/null \
        && log "ipset '$name' created successfully"
    ipset flush $name

    if [ "$mode" = "list" ]; then
        [ -s "$list" ] || return
        filter_ipv4 < $list \
            | sed -E 's#^(.*)$#add '"$name"' \1#' \
            | ipset restore
    else
        [ -n "$list" ] || return
        printf '%s\n' "$list" | filter_ipv4 \
            | sed -E 's#^(.*)$#add '"$name"' \1#' \
            | ipset restore
    fi
    [ $? -ne 0 ] && log "ipset '$name' failed to update"
}

ipset_create()
{
    # create ipset ipv4 entrys

    [ -n "$IPSET" ] || return

    ipset -N $DNSMASQ_REMOTE_IPSET nethash timeout 3600 2>/dev/null
    ipset -N $CUSTOM_REMOTE_IPSET nethash 2>/dev/null

    ipset_load "list" $VPN_REMOTE_IPSET $REMOTE_NETWORK_LIST
    ipset_load "list" $VPN_EXCLUDE_IPSET $EXCLUDE_NETWORK_LIST
    ipset_load "list" $VPN_CLIENTS_IPSET $CLIENTS_LIST
}

ipt_set_rules()
{
    local i

    if [ -n "$IPSET" ]; then
        echo "-A vpnc_wireguard -m set ! --match-set $VPN_CLIENTS_IPSET src -j RETURN"
        echo "-A vpnc_wireguard -m set --match-set $VPN_EXCLUDE_IPSET dst -j RETURN"

        if [ -n "$DEFAULT" ]; then
            echo "-A vpnc_wireguard -j vpnc_wireguard_mark"
        else
            for i in "$DNSMASQ_REMOTE_IPSET" "$VPN_REMOTE_IPSET" "$CUSTOM_REMOTE_IPSET"; do
                [ -n "$i" ] && echo "-A vpnc_wireguard -m set --match-set $i dst -j vpnc_wireguard_mark"
            done
        fi
    else
        for i in $(filter_ipv4 < "$EXCLUDE_NETWORK_LIST"); do
            echo "-A vpnc_wireguard -d $i -j RETURN"
        done

        for i in $(filter_ipv4 < "$CLIENTS_LIST"); do
            echo "-A vpnc_wireguard -s $i -j vpnc_wireguard_remote"
        done

        if [ -n "$DEFAULT" ]; then
            echo "-A vpnc_wireguard_remote -j vpnc_wireguard_mark"
        else
            for i in $(filter_ipv4 < "$REMOTE_NETWORK_LIST"); do
                echo "-A vpnc_wireguard_remote -d $i -j vpnc_wireguard_mark"
            done
        fi
    fi
}

stop_fw()
{
    ipt_remove_rule(){ while iptables -t $1 -C $2 2>/dev/null; do iptables -t $1 -D $2; done }
    ipt_remove_chain(){ iptables -t $1 -F $2 2>/dev/null && iptables -t $1 -X $2 2>/dev/null; }

    ipt_remove_rule "mangle" "PREROUTING -j vpnc_wireguard"
    ipt_remove_rule "mangle" "OUTPUT -j vpnc_wireguard"

    ipt_remove_chain "mangle" "vpnc_wireguard"
    ipt_remove_chain "mangle" "vpnc_wireguard_remote"
    ipt_remove_chain "mangle" "vpnc_wireguard_mark"
}

start_fw()
{
    stop_fw
    is_started || return 1

    iptables-restore -n <<EOF
*mangle
:vpnc_wireguard - [0:0]
:vpnc_wireguard_remote - [0:0]
:vpnc_wireguard_mark - [0:0]
-A PREROUTING -j vpnc_wireguard
-A OUTPUT -j vpnc_wireguard
-A vpnc_wireguard -d 0.0.0.0/8 -j RETURN
-A vpnc_wireguard -d 127.0.0.0/8 -j RETURN
-A vpnc_wireguard -d 169.254.0.0/16 -j RETURN
-A vpnc_wireguard -d 224.0.0.0/4 -j RETURN
-A vpnc_wireguard -d 240.0.0.0/4 -j RETURN
-A vpnc_wireguard -p udp --dport 53 -j RETURN
-A vpnc_wireguard -p tcp --dport 53 -j RETURN
-A vpnc_wireguard -p udp --dport 123 -j RETURN
$(ipt_set_rules)
-A vpnc_wireguard_mark -j CONNMARK --restore-mark
-A vpnc_wireguard_mark -m mark --mark $FWMARK -j RETURN
-A vpnc_wireguard_mark -m conntrack --ctstate NEW -j MARK --set-mark $FWMARK
-A vpnc_wireguard_mark -m mark --mark $FWMARK -j CONNMARK --save-mark
COMMIT
EOF
    [ $? -ne 0 ] && error "firewall rules update failed"
    return 0
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

    update)
        update_wg
    ;;

    reload)
        reload_wg
    ;;

    connected)
        check_connected || exit 1
    ;;

    reconnect)
        reconnect_wg || exit 1
    ;;

    handshake)
        get_latest_handshake || exit 1
    ;;
esac

IFNAME=$IF_NAME

[ -s "$POST_SCRIPT" -a -x "$POST_SCRIPT" ] && . "$POST_SCRIPT"
