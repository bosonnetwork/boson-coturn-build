# Fully static (musl libc) turnserver build for Linux — native.
#
# Runs directly on a Linux host (no Docker, no macOS logic):
#     make -f linux.mk
# and is ALSO the exact logic executed inside docker/Dockerfile.musl, which
# just copies version.mk + common.mk + linux.mk into the container and runs
# `make -f linux.mk`. Building always targets the NATIVE architecture; the
# Dockerfile selects amd64 vs arm64 via buildx `--platform`, and a Linux dev
# building on their own host gets a binary for that host's arch.
#
# Host prerequisites (Debian/Ubuntu names): build-essential curl perl
# pkg-config linux-libc-dev. Alpine/other musl hosts work too — the from-source
# musl below is harmless there.
#
# Produces: $(OUTPUT_DIR)/turnserver-linux-$(GOARCH)

include common.mk

# --- Architecture detection -------------------------------------------------
ARCH := $(shell uname -m)

ifeq ($(ARCH),x86_64)
  GOARCH         := amd64
  OPENSSL_TARGET := linux-x86_64
else ifeq ($(ARCH),aarch64)
  GOARCH         := arm64
  OPENSSL_TARGET := linux-aarch64
else
  $(error unsupported Linux architecture: $(ARCH) (expected x86_64 or aarch64))
endif

DL_DIR      := $(DOWNLOAD_DIR)/linux-$(GOARCH)
STAGING     := $(CURDIR)/$(BUILD_DIR)/staging/linux-$(GOARCH)
SRC         := $(BUILD_DIR)/src/linux-$(GOARCH)
STAMP       := $(STAMP_DIR)/linux-$(GOARCH)
MUSL_GCC    := $(STAGING)/musl/bin/musl-gcc
BINARY      := $(OUTPUT_DIR)/turnserver-linux-$(GOARCH)

.PHONY: all verify clean
.DEFAULT_GOAL := all

all: $(BINARY)

# --- Downloads --------------------------------------------------------------
$(eval $(call DOWNLOAD_RULE,$(DL_DIR)/musl-$(MUSL_VERSION).tar.gz,$(MUSL_URL)))
$(eval $(call DOWNLOAD_RULE,$(DL_DIR)/openssl-$(OPENSSL_VERSION).tar.gz,$(OPENSSL_URL)))
$(eval $(call DOWNLOAD_RULE,$(DL_DIR)/libevent-$(LIBEVENT_VERSION).tar.gz,$(LIBEVENT_URL)))
$(eval $(call DOWNLOAD_RULE,$(DL_DIR)/coturn-$(COTURN_VERSION).tar.gz,$(COTURN_URL)))

# --- Phase 1: musl ----------------------------------------------------------
# musl-gcc runs -nostdinc and only searches musl's own include dir; musl ships
# no Linux kernel headers (linux/version.h, asm/*) that coturn needs, so copy
# them from linux-libc-dev. On Debian multiarch the arch-specific asm/ lives
# under /usr/include/<triplet>/.
$(STAMP)-musl.stamp: $(DL_DIR)/musl-$(MUSL_VERSION).tar.gz | $(STAMP_DIR)
	rm -rf $(SRC)/musl
	mkdir -p $(SRC)/musl
	tar xzf $< -C $(SRC)/musl --strip-components=1
	cd $(SRC)/musl && \
		./configure --prefix="$(STAGING)/musl" --disable-shared && \
		make -j$(NPROC) && \
		make install
	cp -r /usr/include/linux "$(STAGING)/musl/include/"
	cp -r /usr/include/asm-generic "$(STAGING)/musl/include/"
	cp -r "/usr/include/$(ARCH)-linux-gnu/asm" "$(STAGING)/musl/include/"
	touch $@

# --- Phase 2: OpenSSL -------------------------------------------------------
# no-async is mandatory: musl has no ucontext. --libdir=lib forces a consistent
# layout across arches (linux-x86_64 would otherwise install to lib64/).
$(STAMP)-openssl.stamp: $(DL_DIR)/openssl-$(OPENSSL_VERSION).tar.gz $(STAMP)-musl.stamp
	rm -rf $(SRC)/openssl
	mkdir -p $(SRC)/openssl
	tar xzf $< -C $(SRC)/openssl --strip-components=1
	cd $(SRC)/openssl && \
		CC="$(MUSL_GCC)" ./Configure $(OPENSSL_TARGET) \
			--prefix="$(STAGING)/openssl" \
			--openssldir="$(STAGING)/openssl/ssl" \
			--libdir=lib \
			no-shared no-dso no-async no-engine no-tests no-comp \
			-DOPENSSL_NO_SECURE_MEMORY && \
		make -j$(NPROC) && \
		make install_sw
	touch $@

# --- Phase 3: libevent ------------------------------------------------------
# CFLAGS=-static: musl is built --disable-shared, so no ld-musl-*.so.1 loader
# exists; libevent's autotools configure *runs* a compiled test binary, which
# fails without -static ("cannot run C compiled programs").
$(STAMP)-libevent.stamp: $(DL_DIR)/libevent-$(LIBEVENT_VERSION).tar.gz $(STAMP)-openssl.stamp
	rm -rf $(SRC)/libevent
	mkdir -p $(SRC)/libevent
	tar xzf $< -C $(SRC)/libevent --strip-components=1
	cd $(SRC)/libevent && \
		CC="$(MUSL_GCC)" ./configure \
			--prefix="$(STAGING)/libevent" \
			--disable-shared --enable-static \
			--disable-samples --disable-libevent-regress \
			CFLAGS="-static" \
			CPPFLAGS="-I$(STAGING)/openssl/include" \
			LDFLAGS="-L$(STAGING)/openssl/lib" \
			PKG_CONFIG_PATH="$(STAGING)/openssl/lib/pkgconfig" && \
		make -j$(NPROC) && \
		make install
	touch $@

# --- Phase 4: coturn --------------------------------------------------------
# SSL_LIBS/EVENT_LIBS point straight at the .a files (coturn's own override
# hooks) so the static archives are linked, bypassing pkg-config's non-static
# Libs line. $(COTURN_FEATURE_FLAGS) is expanded by make into literal
# NAME=value tokens, so they act as env-assignment prefixes to ./configure.
$(STAMP)-coturn.stamp: $(DL_DIR)/coturn-$(COTURN_VERSION).tar.gz $(STAMP)-libevent.stamp
	rm -rf $(SRC)/coturn
	mkdir -p $(SRC)/coturn
	tar xzf $< -C $(SRC)/coturn --strip-components=1
	cd $(SRC)/coturn && \
		CC="$(MUSL_GCC)" \
		CFLAGS="-static -I$(STAGING)/openssl/include -I$(STAGING)/libevent/include" \
		LDFLAGS="-static -L$(STAGING)/openssl/lib -L$(STAGING)/libevent/lib" \
		SSL_CFLAGS="-I$(STAGING)/openssl/include" \
		SSL_LIBS="$(STAGING)/openssl/lib/libssl.a $(STAGING)/openssl/lib/libcrypto.a" \
		EVENT_CFLAGS="-I$(STAGING)/libevent/include" \
		EVENT_LIBS="$(STAGING)/libevent/lib/libevent.a $(STAGING)/libevent/lib/libevent_openssl.a $(STAGING)/libevent/lib/libevent_pthreads.a" \
		$(COTURN_FEATURE_FLAGS) \
		./configure --prefix="$(STAGING)/coturn" && \
		make -j$(NPROC)
	touch $@

$(BINARY): $(STAMP)-coturn.stamp | $(OUTPUT_DIR)
	cp $(SRC)/coturn/bin/turnserver $@

# --- Verify (native) --------------------------------------------------------
# A fully static ELF has no interpreter and no NEEDED entries.
verify: $(BINARY)
	@echo "== file =="; file $(BINARY)
	@echo "== ldd =="; (ldd $(BINARY) 2>&1 || true)
	@echo "== readelf -d (NEEDED entries) =="; (readelf -d $(BINARY) | grep -i needed || echo "  (none)")
	@echo "== run =="; $(BINARY) --version

clean:
	rm -rf $(BUILD_DIR)/staging/linux-$(GOARCH) $(BUILD_DIR)/src/linux-$(GOARCH) $(STAMP)-*.stamp
