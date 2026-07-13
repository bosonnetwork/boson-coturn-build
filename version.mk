# Pinned component versions — single source of truth for both the
# Docker-based Linux/musl build and the native macOS build.

MUSL_VERSION     := 1.2.6
OPENSSL_VERSION  := 3.6.3
LIBEVENT_VERSION := 2.1.13-stable
COTURN_VERSION   := 4.14.0

MUSL_URL     := https://musl.libc.org/releases/musl-$(MUSL_VERSION).tar.gz
OPENSSL_URL  := https://github.com/openssl/openssl/releases/download/openssl-$(OPENSSL_VERSION)/openssl-$(OPENSSL_VERSION).tar.gz
LIBEVENT_URL := https://github.com/libevent/libevent/releases/download/release-$(LIBEVENT_VERSION)/libevent-$(LIBEVENT_VERSION).tar.gz
COTURN_URL   := https://github.com/coturn/coturn/archive/refs/tags/$(COTURN_VERSION).tar.gz

# coturn ./configure feature toggles shared by every target.
# TURN_NO_SYSTEMD and TURN_NO_SCTP matter even though they're not in the
# original plan: without them, coturn's configure script probes the build
# host's system paths (not just our staging prefix) via pkg-config / a
# hardcoded /usr/include check, and can pull in a dynamically-linked
# libsystemd or a glibc-ABI sctp.h if the host happens to have them
# installed — silently breaking the fully-static goal.
COTURN_FEATURE_FLAGS := \
	TURN_NO_MYSQL=1 \
	TURN_NO_PQ=1 \
	TURN_NO_MONGO=1 \
	TURN_NO_HIREDIS=1 \
	TURN_NO_SQLITE=1 \
	TURN_NO_PROMETHEUS=1 \
	TURN_NO_SYSTEMD=1 \
	TURN_NO_SCTP=1
