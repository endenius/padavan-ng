# https://github.com/getdnsapi/getdns

SRC_NAME = getdns-1.7.3
SRC_URL = https://getdnsapi.net/dist/$(SRC_NAME).tar.gz

all: download_test extract_test config_test
	$(MAKE) -j$(HOST_NCPU) -C $(SRC_NAME)/build

download_test:
	( if [ ! -f $(SRC_NAME).tar.gz ]; then \
		wget -t5 -T20 --no-check-certificate -O $(SRC_NAME).tar.gz $(SRC_URL) \
			|| rm -f $(SRC_NAME).tar.gz; \
	fi )

extract_test:
	( if [ ! -d $(SRC_NAME) ]; then \
		tar zxf $(SRC_NAME).tar.gz; \
		find "$(shell pwd)"/patches -type f -name "*.patch" -print0 \
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
	( mkdir -p $(SRC_NAME)/build && cd $(SRC_NAME)/build ; \
	cmake	-DCMAKE_INSTALL_PREFIX:PATH=/ \
		-DUSE_LIBIDN2=OFF \
		-DENABLE_UNBOUND_EVENT_API=OFF \
		-DENABLE_STUB_ONLY=ON \
		-DBUILD_GETDNS_QUERY=OFF \
		-DBUILD_GETDNS_SERVER_MON=OFF \
		-DBUILD_STUBBY=OFF \
		-DBUILD_EXAMPLES=OFF \
		-DENABLE_STATIC=ON \
		-DENABLE_SHARED=OFF \
		-DBUILD_TESTING=OFF \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_TOOLCHAIN_FILE=$(ROOTDIR)/include/cross-mipsel-linux.cmake .. \
	)

clean:
	if [ -d $(SRC_NAME)/build ]; then \
		rm -rf $(SRC_NAME)/build; \
	fi; \
	rm -f config_done

install:
	$(MAKE) -C $(SRC_NAME)/build install DESTDIR=$(STAGEDIR)

romfs:
