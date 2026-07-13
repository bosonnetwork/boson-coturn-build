# Root orchestrator. Intended to run on a macOS host: it builds the native
# macOS universal binary via macos.mk and the fully-static Linux binaries via
# Docker buildx (which runs linux.mk inside the container).
#
# Layout:
#   version.mk  — pinned versions/URLs/flags (shared)
#   common.mk   — shared dirs, NPROC, download helper (includes version.mk)
#   macos.mk    — native macOS build (universal by default)
#   linux.mk    — native musl static build; also run inside the container
#   docker/Dockerfile.musl — copies the .mk files in and runs `make -f linux.mk`
#
# Linux developers don't need this file or Docker — they can build natively:
#   make -f linux.mk

include common.mk

# common.mk is included first and defines the directory mkdir rules, so without
# this the default goal would be the first of those ($(BUILD_DIR)) rather than
# `all`. Set it explicitly.
.DEFAULT_GOAL := all

.PHONY: all \
        linux linux-amd64 linux-arm64 \
        darwin darwin-universal darwin-arm64 darwin-x86_64 \
        verify verify-linux-amd64 verify-linux-arm64 \
        verify-darwin-universal verify-darwin-arm64 verify-darwin-x86_64 \
        clean distclean

all: linux darwin

# ============================================================================
# Linux — fully static musl binaries, built in Docker via buildx.
#
# The container build logic lives entirely in linux.mk (copied into the image
# by the Dockerfile), so this Makefile only selects the target platform. No
# --build-arg soup: linux.mk pulls versions/URLs from version.mk itself. buildx
# runs each platform natively (QEMU-emulated when cross). linux.mk names its
# output turnserver-linux-<arch>, matching the buildx --platform, so the
# extracted file needs only to move up one directory.
# ============================================================================

linux: linux-amd64 linux-arm64

define BUILDX_LINUX
	docker buildx build \
		--platform linux/$(1) \
		-f docker/Dockerfile.musl \
		--target export \
		-o type=local,dest=$(OUTPUT_DIR)/.linux-$(1) \
		.
	mv $(OUTPUT_DIR)/.linux-$(1)/turnserver-linux-$(1) $(OUTPUT_DIR)/turnserver-linux-$(1)
	rm -rf $(OUTPUT_DIR)/.linux-$(1)
endef

linux-amd64: | $(OUTPUT_DIR)
	$(call BUILDX_LINUX,amd64)

linux-arm64: | $(OUTPUT_DIR)
	$(call BUILDX_LINUX,arm64)

# file/readelf aren't in debian:*-slim, so install binutils+file first. The
# `ldd -> "not a dynamic executable"`, an empty `readelf -d`, and a working
# `--version` on a stock Debian image together prove the binary is fully static.
define VERIFY_LINUX
	docker run --rm --platform linux/$(1) -v "$(CURDIR)/$(OUTPUT_DIR)":/out debian:bookworm-slim sh -c '\
		apt-get update >/dev/null 2>&1 && apt-get install -y --no-install-recommends file binutils >/dev/null 2>&1; \
		echo "== file =="; file /out/turnserver-linux-$(1); \
		echo "== ldd =="; (ldd /out/turnserver-linux-$(1) || true); \
		echo "== readelf -d (NEEDED entries) =="; (readelf -d /out/turnserver-linux-$(1) | grep -i needed || echo "  (none)"); \
		echo "== run =="; /out/turnserver-linux-$(1) --version'
endef

verify-linux-amd64:
	$(call VERIFY_LINUX,amd64)

verify-linux-arm64:
	$(call VERIFY_LINUX,arm64)

# ============================================================================
# macOS — delegated to macos.mk (native clang, universal binary).
# ============================================================================

darwin: darwin-universal

darwin-universal darwin-arm64 darwin-x86_64 \
verify-darwin-universal verify-darwin-arm64 verify-darwin-x86_64:
	$(MAKE) -f macos.mk $@

# ============================================================================

verify: verify-linux-amd64 verify-linux-arm64 verify-darwin-universal

clean:
	rm -rf $(BUILD_DIR)/staging $(BUILD_DIR)/src $(STAMP_DIR)

distclean:
	rm -rf $(BUILD_DIR) $(OUTPUT_DIR)
