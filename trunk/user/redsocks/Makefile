# https://github.com/semigodking/redsocks

SRC_NAME = redsocks-release-0.71
SRC_URL = https://github.com/semigodking/redsocks/archive/refs/tags/release-0.71.tar.gz

CFLAGS  += -ffunction-sections -fdata-sections -fvisibility=hidden
LDFLAGS += -Wl,--gc-sections

OPTIONS  = DISABLE_SHADOWSOCKS=1
#OPTIONS += ENABLE_HTTPS_PROXY=1

all: download_test extract_test
	$(MAKE) -j$(HOST_NCPU) -C $(SRC_NAME) $(OPTIONS)

download_test:
	( if [ ! -f $(SRC_NAME).tar.gz ]; then \
		wget -t5 -T20 --no-check-certificate -O $(SRC_NAME).tar.gz $(SRC_URL) || rm -f $(SRC_NAME).tar.gz; \
	fi )

extract_test:
	( if [ ! -d $(SRC_NAME) ]; then \
		tar xf $(SRC_NAME).tar.gz ; \
	fi )

clean:
	( if [ -f $(SRC_NAME)/Makefile ] ; then \
		$(MAKE) -C $(SRC_NAME) clean ; \
	fi )

romfs:
	$(ROMFSINST) $(SRC_NAME)/redsocks2 /usr/bin/redsocks2
