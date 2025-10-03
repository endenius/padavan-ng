#!/bin/sh

LISTEN_PORT=65054
STUBBY_BIN="/usr/sbin/stubby"
STUBBY_CONFIG="/etc/storage/stubby/stubby.yml"
PID_FILE="/var/run/stubby.pid"
MARK="####### LIST OF SERVERS ######"

make_default_config()
{
    mkdir -p $(dirname "$STUBBY_CONFIG")
    cat << EOF > $STUBBY_CONFIG
####### STUBBY YAML CONFIG FILE ######
resolution_type: GETDNS_RESOLUTION_STUB
dns_transport_list:
  - GETDNS_TRANSPORT_TLS
tls_authentication: GETDNS_AUTHENTICATION_REQUIRED
tls_query_padding_blocksize: 128
edns_client_subnet_private : 1
round_robin_upstreams: 1
idle_timeout: 10000
listen_addresses:
  - 127.0.0.1@$LISTEN_PORT
  - 0::1@$LISTEN_PORT
####### DNSSEC SETTINGS ######
#dnssec_return_status: GETDNS_EXTENSION_TRUE
#dnssec_return_only_secure: GETDNS_EXTENSION_TRUE
#trust_anchors_backoff_time: 2500
#appdata_dir: "/var/lib/stubby"
#######  UPSTREAMS  ######
upstream_recursive_servers:
$MARK
EOF
}

log()
{
    [ -n "$*" ] || return
    echo "$@"
    local pid
    [ -f "$PID_FILE" ] && pid="[$(cat "$PID_FILE" 2>/dev/null)]"
    logger -t "stubby$pid" "$@"
}

error()
{
    log "error: $@"
    exit 1
}

check_config()
{
    if [ ! -f "$STUBBY_CONFIG" ] || \
       ! grep -q "^upstream_recursive_servers:$" "$STUBBY_CONFIG" || \
       ! grep -q "^$MARK$" "$STUBBY_CONFIG"
    then
        make_default_config || return 1
    fi

    # if no ipv6 - remove ipv6 listen address
    [ -d /proc/sys/net/ipv6 ] || sed -e '/::.*@/d' -i $STUBBY_CONFIG

    sync
}

start_service()
{
    if [ -f "$PID_FILE" ]; then
        echo "already running"
        return
    fi

    check_config || error "unable to make config $STUBBY_CONFIG"

    sed -i "1,/$MARK/!d" $STUBBY_CONFIG >/dev/null 2>&1

    local resolvers
    make_config_servers()
    {
        [ "$1" ] || return
        [ "$2" ] || return
        echo "  - address_data: $2" >> $STUBBY_CONFIG
        echo "    tls_auth_name: $1" >> $STUBBY_CONFIG
        [ "$resolvers" ] && resolvers=$(echo "$resolvers, $1") || resolvers="$1"
    }

    for i in 1 2 3; do
        make_config_servers "$(nvram get stubby_server$i | tr -d ' ')" "$(nvram get stubby_server_ip$i | tr -d ' ')"
    done
    sync

    res=$($STUBBY_BIN -i 2>&1 | grep -o "Error parsing config file")
    if [ "$res" ]; then
        make_default_config
        error "failed to start: $res"
    else
        $STUBBY_BIN -g
        if pgrep -x "$STUBBY_BIN" 2>&1 >/dev/null; then
            log "started, version $($STUBBY_BIN -V | awk '{print $2}'), listening on 127.0.0.1:$LISTEN_PORT"
            [ "$resolvers" ] && log "resolvers: $resolvers"
        else
            make_default_config
            error "failed to start"
        fi
    fi
}

stop_service()
{
    killall -q -SIGKILL $(basename "$STUBBY_BIN") && log "stopped"
    rm -f "$PID_FILE"
}

case "$1" in
    start)
        start_service
    ;;

    stop)
        stop_service
    ;;

    restart)
        stop_service
        start_service
    ;;

    *)
        echo "Usage: $0 {start|stop|restart}"
        exit 1
    ;;
esac

exit 0
