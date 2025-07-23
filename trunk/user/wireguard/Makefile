# https://www.wireguard.com

SRC_NAME = wireguard-tools-1.0.20250521
SRC_URL = https://git.zx2c4.com/wireguard-tools/snapshot/$(SRC_NAME).tar.xz

CFLAGS += -ffunction-sections -fdata-sections -fvisibility=hidden
LDFLAGS += -Wl,--gc-sections

all: download_test extract_test config_test
	$(MAKE) -j$(HOST_NCPU) -C $(SRC_NAME)/src

download_test:
	( if [ ! -f $(SRC_NAME).tar.xz ]; then \
		wget -t5 -T20 --no-check-certificate -O $(SRC_NAME).tar.xz $(SRC_URL) || rm -f $(SRC_NAME).tar.xz; \
	fi )

extract_test:
	( if [ ! -d $(SRC_NAME) ]; then \
		tar --xz -xf $(SRC_NAME).tar.xz; \
		find "$(shell pwd)"/patches -type f -name '*.patch' -print0 \
		  | sort -z \
		  | xargs -r -t -0 -n 1 patch -d $(SRC_NAME) -p1 -i; \
	fi )

config_test:
	( if [ -f ./config_done ]; then \
		echo "the same configuration"; \
	else \
		touch config_done; \
	fi )

clean:
	if [ -f $(SRC_NAME)/Makefile ] ; then \
		$(MAKE) -C $(SRC_NAME)/src clean ; \
	fi ; \
	rm config_done

romfs:
	$(ROMFSINST) $(SRC_NAME)/src/wg /usr/sbin/wg
	$(ROMFSINST) -p +x /usr/bin/wgs.sh
	$(ROMFSINST) -p +x /usr/bin/wgc.sh
	$(ROMFSINST) -p +x /usr/bin/wg-json.sh
