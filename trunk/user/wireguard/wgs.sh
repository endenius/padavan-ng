#!/bin/sh

set -o pipefail

###

PRIVATE=$(nvram get vpns_wg_private)
if [ ! "$PRIVATE" ]; then
    PRIVATE="$(wg genkey)"
    nvram set vpns_wg_private="$PRIVATE"
    nvram set vpns_wg_public="$(echo $PRIVATE | wg pubkey)"
    nvram commit
fi
WAN=$(nvram get wan_ifname)
if [ "$(nvram get vpns_wg_ext_addr)" ]; then
    WAN_ADDR="$(nvram get vpns_wg_ext_addr)"
elif [ "$(nvram get ddns_enable_x)" = "1" ]; then
    WAN_ADDR="$(nvram get ddns_hostname_x)"
else
    WAN_ADDR=$(nvram get wan0_ipaddr)
fi
# lan addr is used to access the router's dns (ex. DoT/DoH)
LAN_ADDR=$(nvram get lan_ipaddr)
IFACE="wg1"
IFACE_ADDR="$(nvram get vpns_vnet | sed 's/\.0$/.1/')"
PORT="$(nvram get vpns_wg_port)"
EXPORT_CONF="/tmp/client-wg.conf"

###

FW_RULES() ( echo "
$1 INPUT -i ${WAN} -p udp -m udp --dport ${PORT} -j ACCEPT
$1 INPUT -i ${IFACE} -j ACCEPT
$1 FORWARD -i ${IFACE} -j ACCEPT
")

FW_NAT_RULES()( echo "
$1 POSTROUTING -s ${IFACE_ADDR}/24 -o ${WAN} -j MASQUERADE
")

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
    ip link show ${IFACE} >/dev/null 2>&1
    return $?
}

_net_to_prefix()
{
    [ "$1" ] || return

    echo $1 | awk '
    function count1s(N) {
        r=""
        while(N!=0)
        {
            r=((N%2)?"1":"0") r
            N=int(N/2)
        }
        r=gsub(/1/,"",r)
        return r
    }
    function subnetmaskToPrefix(subnetmask)
    {
        split(subnetmask, v, ".")
        return count1s(v[1]) + count1s(v[2]) + count1s(v[3]) + count1s(v[4])
    }
    { print subnetmaskToPrefix($1) }'
}

wg_setconf()
{
    is_started || return 0

    local pass rnet rmsk prefix i rlan max peers

    max="$(nvram get vpns_num_x)"
    [ "$max" ] || return 0
    [ $max -eq 0 ] && return
    [ $max -gt 0 ] && max=$((max-1))

    for i in $(seq 0 $max); do
        pass=$(nvram get vpns_pass_x$i | wg pubkey 2>/dev/null)
        [ "$pass" ] || continue

        rlan=""
        rnet=$(nvram get vpns_rnet_x$i)
        rmsk=$(nvram get vpns_rmsk_x$i)

        if [ "$rnet" -a "$rmsk" ]; then
            prefix=$(_net_to_prefix $rmsk)
            rlan=", $rnet/$prefix"
        fi

        peers=$(echo "[Peer]"
                echo "PublicKey=$pass"
                echo "AllowedIPs=$(nvram get vpns_vnet | sed 's/\.0$/./')$(nvram get vpns_addr_x$i)$rlan"
                echo "$peers")
    done

    cat > "/tmp/${IFACE}.conf.$$" <<EOF
[Interface]
ListenPort=${PORT}
PrivateKey=${PRIVATE}
$peers
EOF

    local res=$(wg setconf ${IFACE} "/tmp/${IFACE}.conf.$$" 2>&1)
    rm -f "/tmp/${IFACE}.conf.$$"
    if ! echo $res | grep -q "error"; then
        log "${IFACE} configuration applied successfully, clients count: $(wg show ${IFACE} | grep 'peer:' | wc -l)"
    else
        log "$res"
        return 1
    fi
}

wg_prepare()
{
    modprobe -q wireguard >/dev/null 2>&1
    echo 1 > /proc/sys/net/ipv4/ip_forward
    echo 0 > /proc/sys/net/ipv4/conf/all/accept_redirects
    echo 0 > /proc/sys/net/ipv4/conf/all/send_redirects
}

wg_fw()
{
    iptables-restore -n 2>/dev/null <<EOF
*filter
$(FW_RULES $1)
COMMIT
*nat
$(FW_NAT_RULES $1)
COMMIT
EOF
}

wg_fw_stop()
{
    wg_fw -D
}

wg_fw_start()
{
    wg_fw -A
}

wg_stop()
{
    wg_fw_stop
    if is_started; then
        ip link del ${IFACE} >/dev/null 2>&1 && log "stopped"
    fi
}

wg_start()
{
    is_started && die "already started"
    wg_prepare

    ip link add dev ${IFACE} type wireguard || die
    ip addr add ${IFACE_ADDR}/24 dev ${IFACE}
    ip link set dev ${IFACE} mtu 1420

    if ip link set ${IFACE} up; then
        log "started, interface: ${IFACE}, address: ${IFACE_ADDR}:${PORT}"
    else
        ip link del ${IFACE} >/dev/null 2>&1
        die "${IFACE} startup failed"
    fi

    wg_fw_start
    wg_setconf
}

wg_reload()
{
    if is_started; then
        wg_fw_stop
        wg_fw_start
        wg_setconf
    else
        wg_start
    fi
}

wg_addclient()
{
    # $1 - client name

    local max nums free_num addr key config

    [ ! "$WAN_ADDR" -o "$WAN_ADDR" = "0.0.0.0" ] && error "WAN interface address not recognized"

    max="$(nvram get vpns_num_x)"
    [ "$max" ] || return 0
    [ $max -eq 0 ] && return
    [ $max -gt 0 ] && max=$((max-1))

    nums=$(for i in $(seq 0 $max); do
        nvram get vpns_addr_x$i
    done)

    [ ! "$nums" ] && ips=1
    free_num=$(seq 2 255 | grep -vwF "$nums" | head -n1)

    name="client$free_num.wg"
    [ "$1" ] && name="$1"

    for i in $(seq 0 $max); do
        [ $(nvram get vpns_user_x$i) == "$name" ] && die "already exist"
    done

    addr="$(echo $IFACE_ADDR | sed 's/\.1$//').$free_num"
    key=$(wg genkey)

    max="$(nvram get vpns_num_x)"
    nvram set vpns_user_x$max=$name
    nvram set vpns_pass_x$max=$key
    nvram set vpns_addr_x$max=$free_num
    nvram set vpns_rnet_x$max=""
    nvram set vpns_rmsk_x$max=""
    nvram set vpns_num_x=$((max+1))
    nvram commit

    read -r -d '' config <<EOF
[Interface]
PrivateKey = $key
Address = $addr
DNS = $LAN_ADDR

[Peer]
PublicKey = $(echo $PRIVATE | wg pubkey)
Endpoint = ${WAN_ADDR}:${PORT}
PersistentKeepalive = 20
AllowedIPs = 0.0.0.0/0
EOF
    wg_setconf || return

    if [ -x /usr/bin/qrencode ]; then
        echo "$config" | qrencode -t UTF8i -m 2
        #echo "$client_config_private" | qrencode -t SVG -o "/tmp/$client_name.svg"
    fi
    log "client \"$name\" added"
    echo
    echo "$config"
    echo
}

wg_delclient()
{
    echo "todo"
}

wg_listclients()
{
    local peers public user max net addr

    max="$(nvram get vpns_num_x)"
    [ "$max" ] || return 0
    [ $max -eq 0 ] && return
    [ $max -gt 0 ] && max=$((max-1))

    peers=$(wg show ${IFACE} dump 2>/dev/null| awk '
        function bf(bytes){
            if (bytes >= 1024^3) printf "%.2fG", bytes/(1024^3)
            else if (bytes >= 1024^2) printf "%.2fM", bytes/(1024^2)
            else if (bytes >= 1024) printf "%.2fK", bytes/1024
            else printf "%d", bytes
        }
        function tf(n){
            diff = systime() - n
            if (diff < 0 || n == 0) return "never"
            h = int(diff / 3600)
            m = int( (diff - h * 3600) / 60)
            s = diff - m * 60 - h * 3600
            printf "%02d:%02d:%02d", h, m, s
        } NR>1 {print $1, tf($5), bf($6), bf($7), gensub("[)(]|:.*", "", "", $3)}')

    net="$(nvram get vpns_vnet | sed 's/\.0$/./')"

    for i in $(seq 0 $max); do
        public="$(nvram get vpns_pass_x$i | wg pubkey 2>/dev/null)"
        [ "$public" ] || continue
        user="$(nvram get vpns_user_x$i)"
        addr="$(nvram get vpns_addr_x$i)"

        if [ "$peers" ]; then
            printf "%-12s %s %s %s↓ %s↑ %s %s\n" "$user" $(echo "$peers" | grep $public) "$net$addr"
        else
            printf "%-12s %s %s\n" "$user" "$public" "$net$addr"
        fi
    done
}

wg_leases()
{
    is_started && wg_listclients | awk '$3 != "never" && $7 {print $3, $7, $6, $1, $4, $5}' >/tmp/vpns.leases
}

wg_export()
{
    [ "$1" ] || return

    local i default max

    max="$(nvram get vpns_num_x)"
    [ "$max" ] || return
    [ $max -eq 0 ] && return
    [ $max -gt 0 ] && max=$((max-1))

    for i in $(seq 0 $max); do
        [ ! "$(nvram get vpns_user_x$i)" == "$1" ] && continue

        tee "$EXPORT_CONF" <<EOF
[Interface]
PrivateKey = $(nvram get vpns_pass_x$i)
Address = $(nvram get vpns_vnet | sed 's/\.0$/./')$(nvram get vpns_addr_x$i)/24
DNS = $LAN_ADDR

[Peer]
PublicKey = $(nvram get vpns_wg_public)
Endpoint = ${WAN_ADDR}:${PORT}
PersistentKeepalive = 20
AllowedIPs = 0.0.0.0/0
EOF
    done

    chmod 0600 "$EXPORT_CONF"
}

case "$1" in
    start)
        wg_start
    ;;

    stop)
        wg_stop
    ;;

    restart)
        wg_stop
        wg_start
    ;;

    reload)
        wg_reload
    ;;

    export)
        wg_export "$2"
    ;;

    status)
        is_started
    ;;

    leases)
        wg_leases
    ;;

    client)
        shift
        case "$1" in
            add)
                shift
                wg_addclient "$@"
            ;;

            del|remove)
                shift
                wg_delclient "$@"
            ;;

            list|"")
                wg_listclients
            ;;
        esac
    ;;

    *)
        echo "Usage: $0 {start|stop|restart| client [ add|del|list ] }" >&2
        exit 1
    ;;
esac
