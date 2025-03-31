#!/bin/sh

set -o pipefail

### default vars

# wg_private - router private key, getting from: wg genkey
# wg_iface - internal interface name, default: wg0
# wg_iface_addr - internal interface address (/24 mask) ending in 1, default: 10.127.0.1
# wg_wan_port - external port wan for incoming connections, default: 51820

# not in use yet
# wg_wan_addr - external address wan (ip or domain name), use only for creating client config

unset need_commit

[ ! "$(nvram get wg_private)" ] && nvram set wg_private="$(wg genkey)" && need_commit=1
[ ! "$(nvram get wg_iface)" ] && nvram set wg_iface="wg0" && need_commit=1
[ ! "$(nvram get wg_iface_addr)" ] && nvram set wg_iface_addr="10.127.0.1" && need_commit=1
[ ! "$(nvram get wg_wan_port)" ] && nvram set wg_wan_port="51820" && need_commit=1

[ "$need_commit" ] && nvram commit

###

WAN=$(nvram get wan_ifname)

if [ "$(nvram get ddns_enable_x)" = "1" ]; then
    WAN_ADDR="$(nvram get ddns_hostname_x)"
else
    WAN_ADDR=$(nvram get wan0_ipaddr)
fi

# lan addr is used to access the router's dns (ex. DoT/DoH)
LAN_ADDR=$(nvram get lan_ipaddr)
IFACE="$(nvram get wg_iface)"
IFACE_ADDR="$(nvram get wg_iface_addr)"
PORT="$(nvram get wg_wan_port)"
PRIVATE=$(nvram get wg_private)
CLIENTS="/etc/storage/wireguard/clients"

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

wg_setconf()
{
    is_started || return 0

    cat > "/tmp/${IFACE}.conf.$$" <<EOF
[Interface]
ListenPort=${PORT}
PrivateKey=${PRIVATE}

$(cat "${CLIENTS}"/* 2>/dev/null)
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
    ip link set dev wg0 mtu 1420

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

wg_show()
{
    wg show ${IFACE}
}

wg_showconf()
{
    wg showconf ${IFACE}
}

wg_addclient()
{
    # $1 - client name

    local client_ips client_free_ip client_addr client_key client_config_private client_config_public

    [ ! "$WAN_ADDR" -o "$WAN_ADDR" = "0.0.0.0" ] && error "WAN interface address not recognized"

    client_ips=$(awk -F[./,] '/^AllowedIPs/{print $4}' "$CLIENTS"/* 2>/dev/null)
    [ ! "$client_ips" ] && client_ips=1
    client_free_ip=$(seq 2 255 | grep -vwF "$client_ips" | head -n1)

    client_name="client_$client_free_ip"
    [ "$1" ] && client_name="$1"

    [ -d "$CLIENTS/$client_name" ] && rm -rf "$CLIENTS/$client_name"
    [ -s "$CLIENTS/$client_name" ] && die "already exist"

    client_addr="$(echo $IFACE_ADDR | sed 's/\.1$//').$client_free_ip"
    client_key=$(wg genkey)

    read -r -d '' client_config_private <<EOF
[Interface]
PrivateKey = $client_key
Address = $client_addr
DNS = $LAN_ADDR

[Peer]
PublicKey = $(echo $PRIVATE | wg pubkey)
Endpoint = ${WAN_ADDR}:${PORT}
PersistentKeepalive = 20
AllowedIPs = 0.0.0.0/0
EOF

    read -r -d '' client_config_public <<EOF
[Peer]
PublicKey = $(echo $client_key | wg pubkey)
AllowedIPs = $client_addr
EOF

    echo "$client_config_public" > "${CLIENTS}/$client_name"
    sync

    wg_setconf
    if [ $? -eq 0 ]; then
        if [ -x /usr/bin/qrencode ]; then
            echo "$client_config_private" | qrencode -t UTF8i
            #echo "$client_config_private" | qrencode -t SVG -o "/tmp/$client_name.svg"
        fi
        echo
        echo "### one-time showing config for $client_name ###"
        echo
        echo "$client_config_private" # | tee "/tmp/$client_name.conf"
        echo
        echo "### end config ###"
        echo
        log "client \"$client_name\" added"
    else
        rm -f "${CLIENTS}/$client_name"
    fi
}

wg_delclient()
{
    # $1 - client name

    [ "$1" ] || return

    if rm "$CLIENTS/$1" 2>/dev/null; then
        sync
        log "client \"$1\" deleted"
        wg_setconf
    else
        die "not found"
    fi
}

wg_wipeclients()
{
    rm -rf "$CLIENTS"
    mkdir -p "$CLIENTS"
    sync

    log "all clients wiped"
    wg_setconf
}

wg_listclients()
{
    local clients w peers public

    clients=$(find "$CLIENTS" -type f -print0 | xargs -0 -r -n 1 basename | sort -V)
    [ ! "$clients" ] && die "not found"
    w=$(echo "$clients" | wc -L)

    if ! is_started; then
        echo "$clients" | while read i; do
            public=$(cat "$CLIENTS/$i" | grep -Ei "^PublicKey|^AllowedIPs" | cut -d '=' -f2- | tr -d " ")
            printf "%-${w}s %s %s\n" "$i" $public
        done
        return
    fi

    peers=$(wg show ${IFACE} dump | awk '
        function bf(bytes){
            if (bytes >= 1024^3) printf "%.2fG", bytes/(1024^3);
            else if (bytes >= 1024^2) printf "%.2fM", bytes/(1024^2);
            else if (bytes >= 1024) printf "%.2fK", bytes/1024;
            else printf "%d", bytes;
        }
        function tf(n){
            diff = systime() - n;
            if (diff < 0 || n == 0) return "never";
            h = int(diff / 3600);
            m = int( (diff - h * 3600) / 60);
            s = diff - m * 60 - h * 3600;
            printf "%02d:%02d:%02d", h, m, s;
        } NR>1 {print $1, tf($5), bf($6), bf($7), gensub("[)(]", "", "", $3), $4}')

    echo "$clients" | while read i; do
        public=$(awk -F= '/^PublicKey/{print $2}' "$CLIENTS/$i")
        printf "%-${w}s %s %s %s↓ %s↑ %s %s\n" "$i" $(echo "$peers" | grep $public)
    done
}

[ ! -d ""$CLIENTS"" ] && mkdir -p "$CLIENTS"

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

    status)
        is_started
    ;;

    show)
        wg_show
    ;;

    showconf)
        wg_showconf
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

            wipe)
                wg_wipeclients
            ;;

            list|"")
                wg_listclients
            ;;
        esac
    ;;

    *)
        echo "Usage: $0 {start|stop|restart| client [ add|del|wipe|list ] }" >&2
        exit 1
    ;;
esac
