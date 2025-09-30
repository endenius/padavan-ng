#!/bin/sh
### Sample custom user script
### Called after executing the zapret.sh, all its variables and functions are available
### $1 - action: start/stop/reload/restart
###
### $DESYNC_MARK  - mark of processed packages, default 0x40000000
### $FILTER_MARK  - mark allowed clients, default 0x10000000
### $NFQUEUE_NUM  - queue number
### $ISP_IF       - list of WAN interfaces separated by line breaks
### $TCP_PORTS    - UDP ports separated by commas
### $UDP_PORTS    - UDP ports separated by commas
### $NFQWS_BIN    - nfqws binary


### uncomment required feature
### don't forget to remove the relevant filters from the strategies
# STUN4ALL=1
# WG4ALL=1
# DISCORD=1


post_start()
{
  # download additional domain lists
  # zapret.sh download-list

  custom_d stop
  custom_d start
  return 0
}

post_stop()
{
  custom_d stop
  return 0
}

post_reload()
{
  custom_d
  return 0
}

post_restart()
{
  custom_d stop
  custom_d start
  return 0
}

custom_d()
{
  [ "$NFT" ] && return

  modprobe -q xt_u32
  [ "$1" == "stop" ] && stop_custom && return

  [ "$STUN4ALL" ] && stun4all "$1"
  [ "$WG4ALL" ] && wg4all "$1"
  [ "$DISCORD" ] && discord "$1"
}

stun4all()
{
  local str="--dpi-desync=fake --dpi-desync-repeats=2"
  local qnum=300

  start_custom_fw "-p udp -m u32 --u32" "0>>22&0x3C@4>>16=28:65535&&0>>22&0x3C@12=0x2112A442&&0>>22&0x3C@8&0xC0000003=0" $qnum
  if [ "$1" == "start" ]; then
    $NFQWS_BIN --qnum=$qnum --daemon --user=nobody $str >/dev/null 2>&1
    log "custom rule stun4all started"
  fi
}

wg4all()
{
  local str="--dpi-desync=fake --dpi-desync-repeats=6"
  local qnum=301

  start_custom_fw "-p udp -m u32 --u32" "0>>22&0x3C@4>>16=0x9c&&0>>22&0x3C@8=0x01000000" $qnum
  if [ "$1" == "start" ]; then
    $NFQWS_BIN --qnum=$qnum --daemon --user=nobody $str >/dev/null 2>&1
    log "custom rule wg4all started"
  fi
}

discord()
{
  local str="--dpi-desync=fake --dpi-desync-repeats=2"
  local qnum=302

  start_custom_fw "-p udp --dport 50000:50099 -m u32 --u32" "0>>22&0x3C@4>>16=0x52&&0>>22&0x3C@8=0x00010046&&0>>22&0x3C@16=0&&0>>22&0x3C@76=0" $qnum
  if [ "$1" == "start" ]; then
    $NFQWS_BIN --qnum=$qnum --daemon --user=nobody $str >/dev/null 2>&1
    log "custom rule discord started"
  fi
}

start_custom_fw()
{
  # $1 - iptables params (proto, ports, u32)
  # $2 - iptables u32 params
  # $3 - queue number [ 300-309 ]

  for i in $ISP_IF; do
    iptables -t mangle -A POSTROUTING -o $i $1 "$2" -j NFQUEUE --queue-num $3 --queue-bypass
  done
}

stop_custom()
{
  eval "$(iptables-save -t mangle 2>/dev/null | grep "queue-num 30[0-9] " | sed 's/^-A/iptables -t mangle -D/g')"
  for i in $(ps | grep "nfqws --qnum=30[0-9]" | cut -d ' ' -f1); do
    kill $i
  done
}

case "$1" in
    start)
        post_start
    ;;

    stop)
        post_stop
    ;;

    reload)
        post_reload
    ;;

    restart)
        post_restart
    ;;
esac
