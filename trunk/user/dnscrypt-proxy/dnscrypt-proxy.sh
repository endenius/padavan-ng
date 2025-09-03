#!/bin/sh

DNSCRYPT_BIN="/usr/sbin/dnscrypt-proxy"
PID_FILE="/var/run/dnscrypt-proxy.pid"

resolver=$(nvram get dnscrypt_resolver)
localipaddr=$(nvram get dnscrypt_ipaddr)
localport=$(nvram get dnscrypt_port)
options=$(nvram get dnscrypt_options)

log()
{
    [ -n "$*" ] || return
    echo "$@"
    local pid
    [ -f "$PID_FILE" ] && pid="[$(cat "$PID_FILE" 2>/dev/null)]"
    logger -t "dnscrypt-proxy$pid" "$@"
}

error()
{
    log "error: $@"
    exit 1
}

func_start()
{
    if [ -f "$PID_FILE" ]; then
        echo "already running"
        return
    fi

    [ "$1" ] && resolver="$1"

    $DNSCRYPT_BIN -R $resolver -a $localipaddr:$localport -p $PID_FILE -u dnscrypt -d $options
    if pgrep -f "$DNSCRYPT_BIN -R" 2>&1 >/dev/null; then
        log "started, version 1.9.5, resolver \"$resolver\", listening on $localipaddr:$localport"
    fi

    [ ! -f "$PID_FILE" ] && error "failed to start, resolver \"$resolver\""
}

func_stop()
{
    killall -q $(basename "$DNSCRYPT_BIN") && log "stopped"

    local loop=0
    while pgrep -x "$DNSCRYPT_BIN" 2>&1 >/dev/null && [ $loop -lt 50 ]; do
        loop=$((loop+1))
        read -t 0.1
    done
}

case "$1" in
    start)
        func_start $2
    ;;

    stop)
        func_stop
    ;;

    restart)
        func_stop
        func_start $2
    ;;

    *)
        echo "Usage: $0 {start|stop|restart [resolver_name]}"
        exit 1
    ;;
esac

exit 0
