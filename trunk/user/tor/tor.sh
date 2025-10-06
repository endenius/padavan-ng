#!/bin/sh

TOR_BIN="/usr/sbin/tor"
PID_FILE="/var/run/tor.pid"

DATA_DIR="/tmp/tor"
[ -d "/opt/tmp" ] && DATA_DIR="/opt/tmp/tor"
GEOIP_DIR="/usr/share/tor"
CONFIG_DIR="/etc/storage/tor"
CONFIG_FILE="$CONFIG_DIR/torrc"
DNS_PORT=9053
TRANS_PORT=9040
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
### See https://www.torproject.org/docs/tor-manual.html,
### for more options you can use in this file.

# ExitPolicy reject *:*
# ExitPolicy reject6 *:*
# ExcludeExitNodes {RU}, {UA}, {BY}, {KZ}, {MD}, {AZ}, {AM}, {GE}, {LY}, {LT}, {TM}, {UZ}, {EE}
# StrictNodes 1

SocksPort ${LAN_IP}:9050
HTTPTunnelPort ${LAN_IP}:8181

VirtualAddrNetworkIPv4 172.16.0.0/12
VirtualAddrNetworkIPv6 [FC00::]/7
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
Bridge 82.69.44.102:4433 9B3526A418DE61D3BD1719C4E38A29A3BDDCE2DC
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

    log "started, data directory: $DATA_DIR"
    rm -rf $DATA_DIR
    $TOR_BIN --RunAsDaemon 1 --DataDirectory $DATA_DIR --DNSPort $DNS_PORT --TransPort $LAN_IP:$TRANS_PORT --PidFile $PID_FILE
}

func_stop()
{
    redirect_stop
    killall -q -SIGKILL $(basename "$TOR_BIN") && log "stopped"

    if mountpoint -q $GEOIP_DIR ; then
        umount -l $GEOIP_DIR
    fi

    rm -rf $DATA_DIR
    rm -f $PID_FILE
}

func_reload()
{
    is_running || return

    log "reload"
    kill -SIGHUP $(cat "$PID_FILE")
}

redirect_start()
{
    # for testing

    local i

    redirect_stop
    is_running || return


    make_clients_rules()
    {
        # get comma separated clients list for nvram
        local tor_proxy_clients="$(nvram get tor_proxy_clients | tr -s ' ,' '\n')"

        for i in $tor_proxy_clients; do
            echo "-A tor_proxy -p tcp -s $i -j REDIRECT --to-ports 9040"
        done
    }

    make_exclude_rules()
    {
        local wan_ipaddr="$(nvram get wan_ipaddr)"
        [ "$wan_ipaddr" == "0.0.0.0" ] && unset wan_ipaddr

        local wan0_ipaddr="$(nvram get wan0_ipaddr)"
        [ "$wan0_ipaddr" == "0.0.0.0" ] && unset wan0_ipaddr

        for i in $LAN_IP $wan_ipaddr $wan0_ipaddr "$(nvram get vpns_vnet)/24"; do
            echo "-A tor_proxy -d $i -j RETURN"
        done
    }


    iptables-restore -n 2>/dev/null <<EOF
*nat
:tor_proxy - [0:0]
-A PREROUTING -p tcp -m multiport --dports 80,443 -j tor_proxy
$(make_exclude_rules)
$(make_clients_rules)
COMMIT
EOF
    [ ! "$?" == "0" ] && error "failed to start transparent proxy redirect, check clients list"
}

redirect_stop()
{
    iptables -t nat -D PREROUTING -p tcp -m multiport --dports 80,443 -j tor_proxy 2>/dev/null
    iptables -t nat -F tor_proxy 2>/dev/null
    iptables -t nat -X tor_proxy 2>/dev/null
}

case "$1" in
    start)
        func_start
    ;;

    stop)
        func_stop
    ;;

    reload)
        func_reload
    ;;

    start-redirect)
        redirect_start
    ;;

    stop-redirect)
        redirect_stop
    ;;

    config)
        [ ! -f "$CONFIG_FILE" ] && func_create_config
    ;;

    *)
        echo "Usage: $0 {start|stop|reload}"
        exit 1
    ;;
esac

exit 0
