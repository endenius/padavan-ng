#!/bin/sh

dir_storage="/etc/storage/tor"
tor_config="$dir_storage/torrc"

func_create_config()
{
	ip_address=`ip address show br0 | grep -w inet | sed 's|.* \(.*\)/.*|\1|'`
	cat > "$tor_config" <<EOF
### See https://www.torproject.org/docs/tor-manual.html,
### for more options you can use in this file.

#VirtualAddrNetworkIPv4 172.16.0.0/12
#AutomapHostsOnResolve 1
SocksPort 127.0.0.1:9050
SocksPort ${ip_address}:9050
#TransPort ${ip_address}:9040 IsolateClientAddr IsolateClientProtocol IsolateDestAddr IsolateDestPort
#DNSPort 127.0.0.1:9053
Log notice syslog
#ExitPolicy reject *:*
#ExitPolicy reject6 *:*
#ExcludeExitNodes {RU}, {UA}, {BY}, {KZ}, {MD}, {AZ}, {AM}, {GE}, {LY}, {LT}, {TM}, {UZ}, {EE}
#StrictNodes 1

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
	chmod 644 "$tor_config"
	/sbin/mtd_storage.sh save
}

func_start()
{
	test -d "$dir_storage" || mkdir -p -m 755 $dir_storage
	if [ ! -f "$tor_config" ]; then
		func_create_config
	fi
	if [ -d "/opt/share/tor" ]
	then
		mount | grep -q /usr/share/tor || mount --bind /opt/share/tor /usr/share/tor
	fi
	/usr/bin/logger -t tor Start TOR
	/usr/sbin/tor --RunAsDaemon 1 --PidFile /var/run/tor.pid --DataDirectory /tmp/tor
}

func_stop()
{
	killall -q tor && /usr/bin/logger -t tor Stop TOR

	local loop=0
	while test -f /var/run/tor.pid 2>&1 >/dev/null && [ $loop -lt 100 ]; do
		loop=$((loop+1))
		read -t 0.2
	done

	if mountpoint -q /usr/share/tor ; then
		umount -l /usr/share/tor
	fi
	rm -rf /tmp/tor
}

func_reload()
{
	/usr/bin/logger -t tor Restart TOR
	kill -SIGHUP `cat /var/run/tor.pid`
}

case "$1" in
start)
	func_start $2
	;;
stop)
	func_stop
	;;
reload)
	func_reload
	;;
*)
	echo "Usage: $0 {start|stop|reload}"
	exit 1
	;;
esac

exit 0
