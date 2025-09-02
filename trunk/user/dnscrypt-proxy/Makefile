# https://github.com/DNSCrypt/dnscrypt-resolvers
# https://github.com/openwrt/packages/tree/master/net/dnscrypt-proxy/patches

SRC_NAME = dnscrypt-proxy-1.9.5
SRC_URL = https://launchpad.net/ubuntu/+archive/primary/+files/dnscrypt-proxy_1.9.5.orig.tar.gz
CSV_URL = https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v1/dnscrypt-resolvers.csv

CFLAGS += $(COPT) -ffunction-sections -fdata-sections -fvisibility=hidden
LDFLAGS += -Wl,--gc-sections

all: download_test extract_test config_test
	$(MAKE) -j$(HOST_NCPU) -C $(SRC_NAME)

download_test:
	( if [ ! -f $(SRC_NAME).tar.gz ]; then \
		wget -t5 -T20 --no-check-certificate -O $(SRC_NAME).tar.gz $(SRC_URL) || rm -f $(SRC_NAME).tar.gz; \
	fi; \
	if [ ! -f dnscrypt-resolvers.csv ]; then \
		wget -t5 -T20 --no-check-certificate -O dnscrypt-resolvers.csv $(CSV_URL) \
			|| cp $(SRC_NAME)/dnscrypt-resolvers.csv .; \
	fi )

extract_test:
	( if [ ! -d $(SRC_NAME) ]; then \
		tar zxf $(SRC_NAME).tar.gz; \
		find "$(shell pwd)"/patches -type f -name '*.patch' -print0 \
		  | sort -z \
		  | xargs -r -t -0 -n 1 patch -d $(SRC_NAME) -p1 -i; \
	fi )

config_test:
	( if [ -f ./config_done ]; then \
		echo "the same configuration"; \
	else \
		make configure && touch config_done; \
	fi )

configure:
	( cd $(SRC_NAME) ; \
	CPPFLAGS="-I$(STAGEDIR)/include" \
	./configure \
		--prefix=/usr \
		--sysconfdir=/etc/storage/dnscrypt-proxy \
		--disable-ssp \
		--disable-plugins \
		--host=$(HOST_TARGET) \
		--build=$(HOST_BUILD); \
	)

clean:
	if [ -f $(SRC_NAME)/Makefile ] ; then \
		$(MAKE) -C $(SRC_NAME) distclean ; \
	fi ; \
	rm -f config_done

romfs:
	$(ROMFSINST) $(SRC_NAME)/src/proxy/dnscrypt-proxy /usr/sbin/dnscrypt-proxy
	$(ROMFSINST) -d dnscrypt-resolvers.csv /usr/share/dnscrypt-proxy/dnscrypt-resolvers.csv
	$(ROMFSINST) -p +x /usr/bin/dnscrypt-proxy.sh
