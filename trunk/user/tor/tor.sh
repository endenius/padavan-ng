#!/bin/sh

TOR_BIN="/usr/sbin/tor"
PID_FILE="/var/run/tor.pid"

DATA_DIR="/tmp/tor"
unset OPT
[ -d "/opt/tmp" ] && OPT="/opt"

GEOIP_DIR="/usr/share/tor"
CONFIG_DIR="/etc/storage/tor"
CONFIG_FILE="$CONFIG_DIR/torrc"
DNS_PORT=9053
TRANS_PORT=9040

CLIENTS="$(nvram get tor_clients | tr -s ' ,' '\n')"
LAN_IP=$(nvram get lan_ipaddr)
[ "$LAN_IP" ] || LAN_IP="192.168.1.1"

log()
{
    [ -n "$*" ] || return
    echo "$@"
    local pid
    [ -f "$PID_FILE" ] && pid="[$(cat "$PID_FILE" 2>/dev/null)]"
    logger -t "Tor$pid" "$@"
}

error()
{
    log "error: $@"
    exit 1
}

is_running()
{
    [ -z "$(pidof $(basename "$TOR_BIN"))" ] && return 1
    [ "$PID_FILE" ]
}

func_create_config()
{
    [ ! -d "$CONFIG_DIR" ] && mkdir -p -m 755 $CONFIG_DIR

    cat > "$CONFIG_FILE" <<EOF
### https://www.torproject.org/docs/tor-manual.html
### reserved: network 172.16.0.0/12, ports 80,443/TCP

# ExcludeExitNodes {RU}, {UA}, {BY}, {KZ}, {MD}, {AZ}, {AM}, {GE}, {LY}, {LT}, {TM}, {UZ}, {EE}
# StrictNodes 1

SocksPort ${LAN_IP}:9050
HTTPTunnelPort ${LAN_IP}:8181

ExitRelay 0
ExitPolicy reject *:*
ExitPolicy reject6 *:*
AutomapHostsOnResolve 1
Log notice syslog
AvoidDiskWrites 1
UseBridges 1

### https://bridges.torproject.org/bridges?transport=vanilla
### https://torscan-ru.ntc.party
Bridge 62.133.60.208:9300 9002E01C0A23349E46B0C3F104FEFFFA53645762
Bridge 152.53.252.143:9001 99E79C80A38FD7D79D5C047A2B5AFCEFA7D5EAAE
Bridge 5.181.181.13:30319 0CEA4E6376295B6B22AD73947573335EDD9C0F11
Bridge 190.120.229.2:443 1EA7A6645619538D286FDBED7688AFA7F82E0A51
Bridge [2800:ba0:2:ee01::7583]:443 1EA7A6645619538D286FDBED7688AFA7F82E0A51
Bridge 91.242.241.228:9003 9490B0B4EA0BE681D520763FC9DA62511348564F
EOF
    chmod 644 "$CONFIG_FILE"
}

func_start()
{
    if is_running; then
        echo "already running"
        return
    fi

    [ ! -f "$CONFIG_FILE" ] && func_create_config

    if [ -d "/opt/share/tor" ]
    then
        mount | grep -q $GEOIP_DIR || mount --bind /opt/share/tor $GEOIP_DIR
    fi

    log "started, data directory: ${OPT}${DATA_DIR}"
    rm -rf ${OPT}${DATA_DIR}
    rm -rf $DATA_DIR

    # 0.0.0.0 for TransPort, because REDIRECT between interfaces does not work
    $TOR_BIN --RunAsDaemon 1 \
        --DataDirectory ${OPT}${DATA_DIR} \
        --DNSPort $DNS_PORT \
        --VirtualAddrNetworkIPv4 172.16.0.0/12 \
        --TransPort 0.0.0.0:$TRANS_PORT \
        --TransPort [::]:$TRANS_PORT \
        --PidFile $PID_FILE

    # [ "$?" == "0" ] && redirect_start
}

func_stop()
{
    redirect_stop
    killall -q -SIGKILL $(basename "$TOR_BIN") && log "stopped"

    if mountpoint -q $GEOIP_DIR ; then
        umount -l $GEOIP_DIR
    fi

    rm -rf ${OPT}${DATA_DIR}
    rm -rf $DATA_DIR
    rm -f $PID_FILE
}

func_reload()
{
    is_running || return

    # redirect_start
    kill -SIGHUP $(cat "$PID_FILE") && log "reload"
}

### transparent proxy

make_exclude_rules()
{
    local i
    local wan0_ipaddr="$(nvram get wan0_ipaddr)"

    [ "$wan0_ipaddr" == "0.0.0.0" ] && unset wan0_ipaddr

    for i in $LAN_IP $wan0_ipaddr \
             0.0.0.0/8 127.0.0.0/8 169.254.0.0/16 224.0.0.0/4 240.0.0.0/4 \
             10.0.0.0/8 192.168.0.0/16; do
        echo "-A tor_proxy -d $i -j RETURN"
    done

#    echo "-A tor_proxy -m set ! --match-set tor.remote dst -j RETURN"
    echo "-A tor_proxy -m set ! --match-set unblock dst -j RETURN"
}

make_clients_rules()
{
    local i

    # get comma separated clients list for nvram
    for i in $CLIENTS; do
        echo "-A tor_proxy -s $i -j MARK --set-mark $TRANS_PORT"
    done
}

redirect_start()
{
    redirect_stop
    is_running || return

    # using the raw table due to a very old kernel
    res=$(iptables-restore 2>&1 -n <<EOF
*nat
-A PREROUTING -p tcp -m mark --mark $TRANS_PORT -j REDIRECT --to-port $TRANS_PORT
COMMIT
*raw
:tor_proxy - [0:0]
-A PREROUTING -p tcp -m multiport --dports 80,443 -j tor_proxy
-A tor_proxy -d 172.16.0.0/12 -j MARK --set-mark $TRANS_PORT
$(make_exclude_rules)
$(make_clients_rules)
COMMIT
EOF
    )

    [ ! "$?" == "0" ] && error "firewall rules failed to start: $(echo "$res" | head -n1 | cut -d ':' -f2-)"
}

redirect_stop()
{
    iptables -t raw -D PREROUTING -p tcp -m multiport --dports 80,443 -j tor_proxy 2>/dev/null
    iptables -t nat -D PREROUTING -p tcp -m mark --mark $TRANS_PORT -j REDIRECT --to-port $TRANS_PORT 2>/dev/null

    for i in tor_proxy tor_redirect; do
        iptables -t raw -F $i 2>/dev/null
        iptables -t raw -X $i 2>/dev/null
    done
}

case "$1" in
    start)
        func_start
    ;;

    stop)
        func_stop
    ;;

    restart)
        func_stop
        func_start
    ;;

    reload)
        func_reload
    ;;

    redirect-start)
        redirect_start
    ;;

    redirect-stop)
        redirect_stop
    ;;

    config|config-create)
        [ ! -f "$CONFIG_FILE" ] && func_create_config
    ;;

    *)
        echo "Usage: $0 {start|stop|reload}"
        exit 1
    ;;
esac

exit 0
