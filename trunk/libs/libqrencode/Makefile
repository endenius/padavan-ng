# https://github.com/fukuchi/libqrencode

SRC_VER=4.1.1
SRC_NAME=libqrencode-$(SRC_VER)
SRC_URL=https://github.com/fukuchi/libqrencode/archive/refs/tags/v$(SRC_VER).tar.gz

all: download_test extract_test config_test
	$(MAKE) -j$(HOST_NCPU) -C $(SRC_NAME)

download_test:
	( if [ ! -f $(SRC_NAME).tar.gz ]; then \
		wget -t5 -T20 --no-check-certificate -O $(SRC_NAME).tar.gz $(SRC_URL) || rm -f $(SRC_NAME).tar.gz; \
	fi )

extract_test:
	( if [ ! -d $(SRC_NAME) ]; then \
		tar xf $(SRC_NAME).tar.gz; \
	fi )

config_test:
	( if [ -f ./config_done ]; then \
		echo "the same configuration"; \
	else \
		make configure && touch config_done; \
	fi )

configure:
	( cd $(SRC_NAME); \
	./autogen.sh; \
	./configure \
		--prefix=/ \
		--enable-static \
		--disable-shared \
		--without-png \
		--host=$(HOST_TARGET) \
		--build=$(HOST_BUILD); \
	)

clean:
	if [ -f $(SRC_NAME)/Makefile ]; then \
		$(MAKE) -C $(SRC_NAME) distclean; \
	fi; \
	rm -f config_done

install:
	$(MAKE) -C $(SRC_NAME) install DESTDIR=$(STAGEDIR);

romfs:
	$(ROMFSINST) $(DESTDIR)/bin/qrencode /usr/bin/qrencode
