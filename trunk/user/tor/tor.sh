#!/bin/sh

TOR_BIN="/usr/sbin/tor"
PID_FILE="/var/run/tor.pid"

DATA_DIR="/tmp/tor"
[ -d "/opt/tmp" ] && DATA_DIR="/opt/tmp/tor"
GEOIP_DIR="/usr/share/tor"
CONFIG_DIR="/etc/storage/tor"
CONFIG_FILE="$CONFIG_DIR/torrc"

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
    [ ! -d "$CONFIG_DIR" ] && mkdir -p -m 755 $CONFIG_DIR

    cat > "$CONFIG_FILE" <<EOF
### See https://www.torproject.org/docs/tor-manual.html,
### for more options you can use in this file.

#VirtualAddrNetworkIPv4 172.16.0.0/12
#AutomapHostsOnResolve 1
SocksPort 127.0.0.1:9050
SocksPort ${lan_ip}:9050
#TransPort ${lan_ip}:9040 IsolateClientAddr IsolateClientProtocol IsolateDestAddr IsolateDestPort
#DNSPort 127.0.0.1:9053
Log notice syslog
#ExitPolicy reject *:*
#ExitPolicy reject6 *:*
#ExcludeExitNodes {RU}, {UA}, {BY}, {KZ}, {MD}, {AZ}, {AM}, {GE}, {LY}, {LT}, {TM}, {UZ}, {EE}
#StrictNodes 1
AvoidDiskWrites 1

UseBridges 1
### https://bridges.torproject.org/bridges?transport=vanilla
### https://torscan-ru.ntc.party
Bridge 168.119.231.166:9001 672FE851D668EA24FBE03018CAB0CA2DFBA1087F
#Bridge [2a01:4f8:1c1a:dea4::1]:9001 672FE851D668EA24FBE03018CAB0CA2DFBA1087F
Bridge 78.87.68.213:9001 D38463B7BB0A586974E6BAB28D521E8090581173
Bridge 159.196.197.176:9001 867212FE3B08E1DF9ED355338617FC628AE82666
Bridge 50.47.212.0:9001 857D86E69A435F55AEAB3A258B46D49974263F20
#Bridge [2001:470:e920::2]:9001 857D86E69A435F55AEAB3A258B46D49974263F20
Bridge 79.117.127.201:9002 45959A38ACAF2ECFB488A3C69D0C04F42438AB9D
Bridge 45.80.158.53:9200 CFCFA20CDE6BE83CD152FC1559A031CFB0BD0B89
#Bridge [2a12:a800:2:1:45:80:158:53]:9200 CFCFA20CDE6BE83CD152FC1559A031CFB0BD0B89
Bridge 213.33.114.214:443 0693E0271830CD4FC40094E517D3B13C919FF75D
#Bridge [2001:850:461f:30::2]:443 0693E0271830CD4FC40094E517D3B13C919FF75D
Bridge 151.243.109.167:443 0816D426BD84E83B2D55979245BD97A52D276FF2

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
    $TOR_BIN --RunAsDaemon 1 --PidFile $PID_FILE --DataDirectory $DATA_DIR
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
        func_create_config
    ;;

    *)
        echo "Usage: $0 {start|stop|reload}"
        exit 1
    ;;
esac

exit 0
