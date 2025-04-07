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
LEASES_FILE="/tmp/vpns.leases"

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
    local pass rnet rmsk prefix i rlan max peers nvram_modified

    is_started || return 0

    max="$(nvram get vpns_num_x)"
    for i in $(seq 0 $((max-1))); do
        pass=$(nvram get vpns_pass_x$i | wg pubkey 2>/dev/null)
        [ "$pass" ] || continue
        if [ ! "$(nvram get vpns_public_x$i)" == "$pass" ]; then
        # save public keys to speed up creation of leases
            nvram set vpns_public_x$i="$pass"
            nvram_modified=1
        fi

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

    [ "$nvram_modified" ] && nvram commit

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
    [ "$(nvram get vpns_type)" == "3" -a "$(nvram get vpns_enable)" == "1" ] || die "disabled"

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
    wg_setconf && wg show ${IFACE} allowed-ips | awk '$3 {print $3}' | while read ip; do
        ip route add $ip dev $IFACE
    done
}

wg_addclient()
{
    # $1 - client name

    local max nums free_num addr key config

    max="$(nvram get vpns_num_x)"
    nums=$(for i in $(seq 0 $((max-1))); do
        nvram get vpns_addr_x$i
    done)

    [ ! "$nums" ] && ips=1
    free_num=$(seq 2 255 | grep -vwF "$nums" | head -n1)

    name="client${free_num}_wg"
    [ "$1" ] && name="$1"

    for i in $(seq 0 $((max-1))); do
        [ "$(nvram get vpns_user_x$i)" == "$name" ] && die "already exist"
    done

    addr="$(echo $IFACE_ADDR | sed 's/\.1$//').$free_num"
    key=$(wg genkey)

    nvram set vpns_user_x$max=$name
    nvram set vpns_pass_x$max=$key
    nvram set vpns_public_x$max=$(echo $key | wg pubkey)
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
        echo "$config" | qrencode -t UTF8
    fi
    log "client \"$name\" added"
    echo ---------------------------------------------------------
    echo "$config"
    echo
}

wg_listclients()
{
    local peers public_list users_list max

    max="$(nvram get vpns_num_x)"
    [ "$max" == "0" ] && return

    peers=$(wg show ${IFACE} dump 2>/dev/null | awk '
        function bf(bytes){
            if (bytes >= 1024^4) printf "%.1fT", bytes/(1024^3)
            else if (bytes >= 1024^3) printf "%.1fG", bytes/(1024^3)
            else if (bytes >= 1024^2) printf "%.1fM", bytes/(1024^2)
            else if (bytes >= 1024) printf "%.1fK", bytes/1024
            else printf "%d", bytes
        } NR>1 {
        print $1, $5, bf($6), bf($7), gensub("[)(]|:[0-9]+$", "", "", $3), $4}
    ')

    if [ ! "$peers" ]; then
        for i in $(seq 0 $((max-1))); do
            rnet=$(nvram get vpns_rnet_x$i)
            rmsk=$(nvram get vpns_rmsk_x$i)

            rlan=""
            if [ "$rnet" -a "$rmsk" ]; then
                prefix=$(_net_to_prefix $rmsk)
                rlan=",$rnet/$prefix"
            fi
            printf "%-12s %s %s%s\n" $(nvram get vpns_user_x$i) $(nvram get vpns_public_x$i) \
                $(nvram get vpns_vnet | sed 's/\.0$/./')$(nvram get vpns_addr_x$i) "$rlan"
        done
        return
    fi

    users_list=$(nvram show all | grep -E "vpns_user_x[0-9]+=.+" \
            | sed -E "s/vpns_user_x([0-9]*)=/vpns_public_x\1|/")
    public_list=$(nvram show all | grep -E "vpns_public_x[0-9]+=.+" \
            | sed -E "s/vpns_public_x([0-9]*)=/vpns_public_x\1|/")

    echo "$peers" | awk -v list1="$users_list" -v list2="$public_list" '
    BEGIN {
        split(list1, parts1, "\n");
        for (i in parts1) {
            split(parts1[i], keyval, "|");
            a[keyval[1]] = keyval[2];
        }

        split(list2, parts2, "\n");
        for (i in parts2) {
            split(parts2[i], keyval, "|");
            b[keyval[1]] = keyval[2]
        }

        for (key in a) {
            if (key in b) {
                c[b[key]] = a[key];
            }
        }
    } { printf "%-12s %s %s ↓%s ↑%s %s %s\n", c[$1], $1, $2, $3, $4, $5, $6, $7}'
}

wg_leases()
{
    is_started && wg_listclients | awk '$3 && $7 {print $3, gensub("\/.+", "", "", $7), $6, $1, $4, $5}' >$LEASES_FILE
}

wg_export()
{
    [ "$1" ] || return

    local i max

    rm -f "$EXPORT_CONF"

    max="$(nvram get vpns_num_x)"
    for i in $(seq 0 $((max-1))); do
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

    chmod 0600 "$EXPORT_CONF" || die "not found"
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

    export)
        wg_export "$2"
    ;;

    status)
        is_started
    ;;

    leases)
        wg_leases
    ;;

    add)
        wg_addclient "$2"
    ;;

    list)
        wg_listclients
    ;;

    *)
        echo "Usage: $0 { start|stop|restart|list| { export|add [client name] } }" >&2
        exit 1
    ;;
esac
