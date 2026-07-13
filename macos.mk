# Native macOS turnserver build (clang) — produces a universal (arm64 + x86_64)
# binary by default.
#
#     make -f macos.mk            # -> universal binary (default goal)
#     make -f macos.mk darwin-arm64 / darwin-x86_64   # single-arch slices
#
# NOT fully static: Apple ships no static libSystem and ld64 refuses -static,
# so OpenSSL and libevent are linked as static .a archives with only libSystem
# (and libresolv) remaining dynamic — the standard "static-ish" macOS binary.
#
# No Rosetta required, and builds on either host arch. The build never *runs* a
# foreign-arch binary: OpenSSL and coturn configure only compile their test
# programs (never execute them), and libevent is told to cross-compile via
# --host/--build (below) so its autotools stops trying to run a test binary.
# clang cross-compiles each slice with `-arch <arch>`; the slices are then
# lipo'd into the universal binary. (OpenSSL and libevent emit arch-specific
# assembly and their configure targets a single arch, so a one-shot
# `-arch x86_64 -arch arm64` build isn't possible for them — hence per-arch +
# lipo, which yields an identical universal artifact.)

include common.mk

HOST_ARCH := $(shell uname -m)
DARWIN_DL_DIR := $(DOWNLOAD_DIR)/darwin

# Per-arch path variables (defined as real make vars so the build macro below
# can reference them with $$(...) after $(call) substitution).
DARWIN_STAGING_arm64  := $(CURDIR)/$(BUILD_DIR)/staging/darwin-arm64
DARWIN_STAGING_x86_64 := $(CURDIR)/$(BUILD_DIR)/staging/darwin-x86_64
DARWIN_SRC_arm64      := $(BUILD_DIR)/src/darwin-arm64
DARWIN_SRC_x86_64     := $(BUILD_DIR)/src/darwin-x86_64

# Autotools cross-compile triples for libevent: when a slice's arch differs
# from the build host, passing --host (!= --build) puts autotools in
# cross-compile mode so it uses compile-only checks instead of running a test
# binary — which is the sole thing that would otherwise need Rosetta. The
# specific triple is inconsequential (CC is pinned to `clang -arch <arch>`); it
# only has to differ from --build and be accepted by config.sub.
ifeq ($(HOST_ARCH),arm64)
  DARWIN_CROSS_arm64  :=
  DARWIN_CROSS_x86_64 := --build=aarch64-apple-darwin --host=x86_64-apple-darwin
else
  DARWIN_CROSS_x86_64 :=
  DARWIN_CROSS_arm64  := --build=x86_64-apple-darwin --host=aarch64-apple-darwin
endif

.PHONY: darwin-universal darwin-arm64 darwin-x86_64 \
        verify-darwin-universal verify-darwin-arm64 verify-darwin-x86_64 clean
.DEFAULT_GOAL := darwin-universal

# --- Downloads (arch-independent tarballs, fetched once) --------------------
$(eval $(call DOWNLOAD_RULE,$(DARWIN_DL_DIR)/openssl-$(OPENSSL_VERSION).tar.gz,$(OPENSSL_URL)))
$(eval $(call DOWNLOAD_RULE,$(DARWIN_DL_DIR)/libevent-$(LIBEVENT_VERSION).tar.gz,$(LIBEVENT_URL)))
$(eval $(call DOWNLOAD_RULE,$(DARWIN_DL_DIR)/coturn-$(COTURN_VERSION).tar.gz,$(COTURN_URL)))

# --- Per-arch build macro ---------------------------------------------------
# $(call DARWIN_BUILD,<arch>,<openssl-configure-target>)
# <arch> is both the clang -arch value and the filename/path token.
define DARWIN_BUILD

darwin-$(1): $(STAMP_DIR)/darwin-$(1)-coturn.stamp | $(OUTPUT_DIR)
	cp $$(DARWIN_SRC_$(1))/coturn/bin/turnserver $(OUTPUT_DIR)/turnserver-darwin-$(1)

$(STAMP_DIR)/darwin-$(1)-openssl.stamp: $(DARWIN_DL_DIR)/openssl-$(OPENSSL_VERSION).tar.gz | $(STAMP_DIR)
	rm -rf $$(DARWIN_SRC_$(1))/openssl
	mkdir -p $$(DARWIN_SRC_$(1))/openssl
	tar xzf $$< -C $$(DARWIN_SRC_$(1))/openssl --strip-components=1
	cd $$(DARWIN_SRC_$(1))/openssl && \
		CC="clang -arch $(1)" ./Configure $(2) \
			--prefix="$$(DARWIN_STAGING_$(1))/openssl" \
			--openssldir="$$(DARWIN_STAGING_$(1))/openssl/ssl" \
			no-shared no-dso no-tests no-comp -DOPENSSL_NO_SECURE_MEMORY && \
		make -j$(NPROC) && \
		make install_sw
	touch $$@

$(STAMP_DIR)/darwin-$(1)-libevent.stamp: $(DARWIN_DL_DIR)/libevent-$(LIBEVENT_VERSION).tar.gz $(STAMP_DIR)/darwin-$(1)-openssl.stamp
	rm -rf $$(DARWIN_SRC_$(1))/libevent
	mkdir -p $$(DARWIN_SRC_$(1))/libevent
	tar xzf $$< -C $$(DARWIN_SRC_$(1))/libevent --strip-components=1
	cd $$(DARWIN_SRC_$(1))/libevent && \
		CC="clang -arch $(1)" ./configure \
			$(DARWIN_CROSS_$(1)) \
			--prefix="$$(DARWIN_STAGING_$(1))/libevent" \
			--disable-shared --enable-static \
			--disable-samples --disable-libevent-regress \
			CPPFLAGS="-I$$(DARWIN_STAGING_$(1))/openssl/include" \
			LDFLAGS="-L$$(DARWIN_STAGING_$(1))/openssl/lib" \
			PKG_CONFIG_PATH="$$(DARWIN_STAGING_$(1))/openssl/lib/pkgconfig" && \
		make -j$(NPROC) && \
		make install
	touch $$@

$(STAMP_DIR)/darwin-$(1)-coturn.stamp: $(DARWIN_DL_DIR)/coturn-$(COTURN_VERSION).tar.gz $(STAMP_DIR)/darwin-$(1)-libevent.stamp
	rm -rf $$(DARWIN_SRC_$(1))/coturn
	mkdir -p $$(DARWIN_SRC_$(1))/coturn
	tar xzf $$< -C $$(DARWIN_SRC_$(1))/coturn --strip-components=1
	cd $$(DARWIN_SRC_$(1))/coturn && \
		CC="clang -arch $(1)" \
		CFLAGS="-I$$(DARWIN_STAGING_$(1))/openssl/include -I$$(DARWIN_STAGING_$(1))/libevent/include" \
		LDFLAGS="-L$$(DARWIN_STAGING_$(1))/openssl/lib -L$$(DARWIN_STAGING_$(1))/libevent/lib" \
		SSL_CFLAGS="-I$$(DARWIN_STAGING_$(1))/openssl/include" \
		SSL_LIBS="$$(DARWIN_STAGING_$(1))/openssl/lib/libssl.a $$(DARWIN_STAGING_$(1))/openssl/lib/libcrypto.a" \
		EVENT_CFLAGS="-I$$(DARWIN_STAGING_$(1))/libevent/include" \
		EVENT_LIBS="$$(DARWIN_STAGING_$(1))/libevent/lib/libevent.a $$(DARWIN_STAGING_$(1))/libevent/lib/libevent_openssl.a $$(DARWIN_STAGING_$(1))/libevent/lib/libevent_pthreads.a" \
		$(COTURN_FEATURE_FLAGS) \
		./configure --prefix="$$(DARWIN_STAGING_$(1))/coturn" && \
		make -j$(NPROC)
	touch $$@

verify-darwin-$(1): $(OUTPUT_DIR)/turnserver-darwin-$(1)
	@echo "== file =="; file $$<
	@echo "== otool -L =="; otool -L $$<
	@echo "== run =="; $$< --version

endef

$(eval $(call DARWIN_BUILD,arm64,darwin64-arm64-cc))
$(eval $(call DARWIN_BUILD,x86_64,darwin64-x86_64-cc))

# --- Universal (fat) binary -------------------------------------------------
darwin-universal: darwin-arm64 darwin-x86_64 | $(OUTPUT_DIR)
	lipo -create -output $(OUTPUT_DIR)/turnserver-darwin-universal \
		$(OUTPUT_DIR)/turnserver-darwin-arm64 $(OUTPUT_DIR)/turnserver-darwin-x86_64

verify-darwin-universal: $(OUTPUT_DIR)/turnserver-darwin-universal
	@echo "== file =="; file $<
	@echo "== lipo -info =="; lipo -info $<
	@echo "== otool -L =="; otool -L $<
	@echo "== run =="; $< --version

clean:
	rm -rf $(BUILD_DIR)/staging/darwin-* $(BUILD_DIR)/src/darwin-* $(STAMP_DIR)/darwin-*.stamp
