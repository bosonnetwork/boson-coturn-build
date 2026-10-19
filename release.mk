# Release packaging: license notices, the release tarball, SHA256SUMS and its
# signature by the Boson release key. Included by the root Makefile, so it runs
# on the macOS host that holds all four binaries.
#
#     make                # build the binaries
#     make verify         # check them
#     make release        # package + sign what was just verified
#
# It never builds anything itself: it packages the binaries already in
# $(OUTPUT_DIR), so a release is exactly what `make verify` looked at, and a
# missing binary is an error rather than a silent rebuild.
#
# Produces, under $(DIST_DIR):
#
#   boson-coturn-<version>.tar.gz   every binary, the license notices, BUILDINFO
#   SHA256SUMS                      over the tarball, sha256sum format
#   SHA256SUMS.asc                  its detached signature by the release key
#
# Those three files are the release assets. `make dist` stops before signing,
# for trying the packaging without the key.

DIST_DIR     := $(OUTPUT_DIR)/dist
LICENSE_DIR  := $(OUTPUT_DIR)/licenses
RELEASE_NAME := boson-coturn-$(RELEASE_VERSION)
TARBALL      := $(DIST_DIR)/$(RELEASE_NAME).tar.gz
STAGE        := $(DIST_DIR)/stage

# The single-arch binaries. The universal macOS binary is left out: it is these
# two darwin slices glued together, and would only double the download.
RELEASE_BINARIES := \
	turnserver-linux-amd64 \
	turnserver-linux-arm64 \
	turnserver-darwin-arm64 \
	turnserver-darwin-x86_64

# BosonNetwork <support@bosonnetwork.io>, the key that signs every Boson
# release. Its public half is committed at RELEASE_KEY_FILE, a copy of
# super-node-deployment/assets/keys/boson-release.asc.
RELEASE_KEY      := 5A012C930EEDB923B7AB4739A13B99C0C4AA495A
RELEASE_KEY_FILE := keys/boson-release.asc

.PHONY: licenses dist release release-check

# ============================================================================
# License notices
#
# Every binary is a combined work, and BSD-3 (coturn, libevent), Apache-2.0
# (OpenSSL) and MIT (musl, Linux only) all require their notice to travel with
# it. They are read straight out of the same pinned source tarballs the build
# uses, so they always match the versions actually compiled in.
#
# The macOS build downloads coturn, OpenSSL and libevent on this host; musl is
# only ever fetched inside the Linux build container, so it is fetched here too.
# ============================================================================

LICENSE_SRC_DIR := $(DOWNLOAD_DIR)/darwin
MUSL_SRC_DIR    := $(DOWNLOAD_DIR)/licenses

$(eval $(call DOWNLOAD_RULE,$(LICENSE_SRC_DIR)/coturn-$(COTURN_VERSION).tar.gz,$(COTURN_URL)))
$(eval $(call DOWNLOAD_RULE,$(LICENSE_SRC_DIR)/openssl-$(OPENSSL_VERSION).tar.gz,$(OPENSSL_URL)))
$(eval $(call DOWNLOAD_RULE,$(LICENSE_SRC_DIR)/libevent-$(LIBEVENT_VERSION).tar.gz,$(LIBEVENT_URL)))
$(eval $(call DOWNLOAD_RULE,$(MUSL_SRC_DIR)/musl-$(MUSL_VERSION).tar.gz,$(MUSL_URL)))

# $(call LICENSE_RULE,<component>,<tarball>,<member inside the tarball>)
# Written to a temporary file and checked non-empty, so a renamed upstream
# license file fails the release instead of shipping an empty notice.
define LICENSE_RULE
$(LICENSE_DIR)/$(1)/$(notdir $(3)): $(2)
	mkdir -p $$(dir $$@)
	tar -xzf $$< -O "$(3)" > $$@.tmp
	test -s $$@.tmp
	mv $$@.tmp $$@

LICENSE_FILES += $(LICENSE_DIR)/$(1)/$(notdir $(3))
endef

$(eval $(call LICENSE_RULE,coturn,$(LICENSE_SRC_DIR)/coturn-$(COTURN_VERSION).tar.gz,coturn-$(COTURN_VERSION)/LICENSE))
$(eval $(call LICENSE_RULE,openssl,$(LICENSE_SRC_DIR)/openssl-$(OPENSSL_VERSION).tar.gz,openssl-$(OPENSSL_VERSION)/LICENSE.txt))
$(eval $(call LICENSE_RULE,libevent,$(LICENSE_SRC_DIR)/libevent-$(LIBEVENT_VERSION).tar.gz,libevent-$(LIBEVENT_VERSION)/LICENSE))
$(eval $(call LICENSE_RULE,musl,$(MUSL_SRC_DIR)/musl-$(MUSL_VERSION).tar.gz,musl-$(MUSL_VERSION)/COPYRIGHT))

$(LICENSE_DIR)/README: version.mk release.mk
	mkdir -p $(dir $@)
	{ \
	  echo "The turnserver binaries in this release are built from the following"; \
	  echo "components. Each one's license notice is in the directory named after it."; \
	  echo; \
	  printf '  %-9s %-14s %-13s %s\n' coturn $(COTURN_VERSION) BSD-3-Clause "all binaries"; \
	  printf '  %-9s %-14s %-13s %s\n' OpenSSL $(OPENSSL_VERSION) Apache-2.0 "all binaries (statically linked)"; \
	  printf '  %-9s %-14s %-13s %s\n' libevent $(LIBEVENT_VERSION) BSD-3-Clause "all binaries (statically linked)"; \
	  printf '  %-9s %-14s %-13s %s\n' musl $(MUSL_VERSION) MIT "Linux binaries only (statically linked)"; \
	} > $@

LICENSE_FILES += $(LICENSE_DIR)/README

licenses: $(LICENSE_FILES)

# ============================================================================
# Tarball
# ============================================================================

# The binaries are never built from here; see the header. A file rule with no
# prerequisites runs only when the file is missing.
$(addprefix $(OUTPUT_DIR)/,$(RELEASE_BINARIES)):
	@echo "Missing $@ - build and check the binaries first: make && make verify" >&2
	@exit 1

# Laid out as boson-coturn-<version>/{bin,licenses}/ plus BUILDINFO, which
# records the exact inputs and each binary's sha256, so a binary found on its
# own can be traced back to its release.
#
# Deterministic for the same binaries: entries in sorted order, every mtime set
# to the last commit's time, owner root:root, no macOS metadata (COPYFILE_DISABLE
# and --no-mac-metadata keep AppleDouble ._ files out), and `gzip -n` keeps the
# current time out of the gzip header. Packaging the same output twice gives
# the same sha256. (The binaries themselves are not bit-reproducible builds.)
$(TARBALL): $(addprefix $(OUTPUT_DIR)/,$(RELEASE_BINARIES)) $(LICENSE_FILES) version.mk release.mk
	rm -rf $(STAGE)
	mkdir -p $(STAGE)/$(RELEASE_NAME)/bin $(STAGE)/$(RELEASE_NAME)/licenses
	cp $(addprefix $(OUTPUT_DIR)/,$(RELEASE_BINARIES)) $(STAGE)/$(RELEASE_NAME)/bin/
	cp -R $(LICENSE_DIR)/ $(STAGE)/$(RELEASE_NAME)/licenses/
	{ \
	  echo "release   $(RELEASE_VERSION)"; \
	  echo "commit    $$(git rev-parse HEAD)$$(test -z "$$(git status --porcelain)" || echo -dirty)"; \
	  echo; \
	  echo "coturn    $(COTURN_VERSION)"; \
	  echo "openssl   $(OPENSSL_VERSION)"; \
	  echo "libevent  $(LIBEVENT_VERSION)"; \
	  echo "musl      $(MUSL_VERSION) (Linux only)"; \
	  echo; \
	  echo "features  $(strip $(COTURN_FEATURE_FLAGS)) $(COTURN_EXTRA_CFLAGS)"; \
	  echo "configure $(COTURN_CONFIGURE_EXTRA)"; \
	  echo "cflags    $(HARDENING_CFLAGS)"; \
	  echo; \
	  cd $(STAGE)/$(RELEASE_NAME) && shasum -a 256 bin/*; \
	} > $(STAGE)/$(RELEASE_NAME)/BUILDINFO
	chmod 0755 $(STAGE)/$(RELEASE_NAME)/bin/*
	find $(STAGE)/$(RELEASE_NAME) -type d -exec chmod 0755 {} +
	find $(STAGE)/$(RELEASE_NAME) -type f ! -path '*/bin/*' -exec chmod 0644 {} +
	find $(STAGE)/$(RELEASE_NAME) -exec touch -h -t "$$(date -r "$$(git log -1 --format=%ct)" +%Y%m%d%H%M.%S)" {} +
	mkdir -p $(DIST_DIR)
	cd $(STAGE) && find $(RELEASE_NAME) | LC_ALL=C sort \
		| COPYFILE_DISABLE=1 tar --format ustar --uid 0 --gid 0 --uname root --gname root \
			--no-mac-metadata -n -T - -cf - \
		| gzip -n -9 > $(CURDIR)/$@.tmp
	mv $@.tmp $@
	rm -rf $(STAGE)

$(DIST_DIR)/SHA256SUMS: $(TARBALL)
	cd $(DIST_DIR) && shasum -a 256 $(notdir $(TARBALL)) > SHA256SUMS

dist: $(DIST_DIR)/SHA256SUMS
	@echo "=== $(DIST_DIR) (unsigned) ==="
	@ls -l $(DIST_DIR) | tail -n +2 | sed 's/^/  /'
	@echo; echo "=== contents ==="
	@tar -tvzf $(TARBALL) | sed 's/^/  /'

# ============================================================================
# Release: dist + signature
# ============================================================================

# BUILDINFO names the commit the binaries were packaged from, which only means
# something if that commit is all there is. The binaries may of course predate
# the commit; rebuilding after the last change is on whoever cuts the release.
release-check:
	@if [ -n "$$(git status --porcelain)" ]; then \
	  echo "Refusing to release from a dirty tree (git status is not clean):" >&2; \
	  git status --short >&2; exit 1; \
	fi

# Always re-signed: a signature is only as fresh as the SHA256SUMS it covers,
# and the .asc is cheap to remake.
release: release-check $(DIST_DIR)/SHA256SUMS
	./scripts/sign-release.sh $(DIST_DIR)/SHA256SUMS $(RELEASE_KEY) $(RELEASE_KEY_FILE)
	@echo
	@echo "=== Release $(RELEASE_VERSION): upload these three assets ==="
	@ls -l $(TARBALL) $(DIST_DIR)/SHA256SUMS $(DIST_DIR)/SHA256SUMS.asc | sed 's/^/  /'
	@echo
	@echo "  sha256: $$(cut -d' ' -f1 < $(DIST_DIR)/SHA256SUMS)"
	@echo
	@echo "  gh release create $(RELEASE_VERSION) --repo bosonnetwork/boson-coturn-build \\"
	@echo "      --title \"coturn $(RELEASE_VERSION)\" \\"
	@echo "      $(TARBALL) $(DIST_DIR)/SHA256SUMS $(DIST_DIR)/SHA256SUMS.asc"
