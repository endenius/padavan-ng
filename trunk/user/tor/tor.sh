#!/bin/sh

TOR_BIN="/usr/sbin/tor"
PID_FILE="/var/run/tor.pid"

DATA_DIR="/tmp/tor"
[ -d "/opt/tmp" ] && DATA_DIR="/opt/tmp/tor"
GEOIP_DIR="/usr/share/tor"
CONFIG_DIR="/etc/storage/tor"
CONFIG_FILE="$CONFIG_DIR/torrc"
DNS_PORT=9053

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
    local lan_ip=$(nvram get lan_ipaddr)
    [ "$lan_ip" ] || lan_ip="192.168.1.1"
    [ ! -d "$CONFIG_DIR" ] && mkdir -p -m 755 $CONFIG_DIR

    cat > "$CONFIG_FILE" <<EOF
### See https://www.torproject.org/docs/tor-manual.html,
### for more options you can use in this file.

# VirtualAddrNetworkIPv4 172.16.0.0/12
# AutomapHostsOnResolve 1
# TransPort ${lan_ip}:9040 IsolateClientAddr IsolateClientProtocol IsolateDestAddr IsolateDestPort
# ExitPolicy reject *:*
# ExitPolicy reject6 *:*
# ExcludeExitNodes {RU}, {UA}, {BY}, {KZ}, {MD}, {AZ}, {AM}, {GE}, {LY}, {LT}, {TM}, {UZ}, {EE}
# StrictNodes 1

SocksPort 127.0.0.1:9050
SocksPort ${lan_ip}:9050
# SocksPort 0.0.0.0:9050

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
    $TOR_BIN --RunAsDaemon 1 --DataDirectory $DATA_DIR --DNSPort $DNS_PORT --PidFile $PID_FILE
}

func_stop()
{
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

    config)
        [ ! -f "$CONFIG_FILE" ] && func_create_config
    ;;

    *)
        echo "Usage: $0 {start|stop|reload}"
        exit 1
    ;;
esac

exit 0
