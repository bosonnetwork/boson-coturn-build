# Shared definitions and rules for every build (root orchestrator + the
# platform Makefiles macos.mk / linux.mk). Pulls in the pinned versions from
# version.mk so all callers agree on what to fetch.
#
# Included files resolve relative to the current working directory, so every
# consumer must be invoked from the repo root (natively) or from a directory
# that holds these three .mk files (inside the Docker build container).

include version.mk

# --- Directories ------------------------------------------------------------
# `?=` so a parent Makefile can override before including (none currently do).
BUILD_DIR    ?= build
DOWNLOAD_DIR ?= $(BUILD_DIR)/downloads
STAMP_DIR    ?= $(BUILD_DIR)/.stamps
OUTPUT_DIR   ?= output

# Parallel job count: nproc on Linux, sysctl on macOS, 4 as a last resort.
NPROC ?= $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

$(BUILD_DIR) $(DOWNLOAD_DIR) $(STAMP_DIR) $(OUTPUT_DIR):
	mkdir -p $@

# --- Download helper --------------------------------------------------------
# $(call DOWNLOAD_RULE,<dest-tarball-path>,<url>) emits a self-contained rule
# that creates the destination directory and fetches the tarball. Stamp/extract
# logic lives in the platform Makefiles since staging layouts differ per
# platform.
define DOWNLOAD_RULE
$(1):
	mkdir -p $$(dir $$@)
	curl -fL "$(2)" -o $$@
endef
