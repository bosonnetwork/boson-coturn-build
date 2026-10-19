# Pinned component versions — single source of truth for both the
# Docker-based Linux/musl build and the native macOS build.

MUSL_VERSION     := 1.2.6
OPENSSL_VERSION  := 3.5.9
LIBEVENT_VERSION := 2.1.13-stable
COTURN_VERSION   := 4.18.0

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
# These are consumed as NAME=value assignments prefixed to ./configure, so they
# may only contain variables the configure script actually honours as probes
# (i.e. the TURN_NO_* family). Path overrides (prefix/turndbdir) and code
# defines (e.g. disabling OAuth) must NOT live here — see below.
COTURN_FEATURE_FLAGS := \
	TURN_NO_MYSQL=1 \
	TURN_NO_PQ=1 \
	TURN_NO_MONGO=1 \
	TURN_NO_HIREDIS=1 \
	TURN_NO_SQLITE=1 \
	TURN_NO_PROMETHEUS=1 \
	TURN_NO_SYSTEMD=1 \
	TURN_NO_SCTP=1

# OAuth (RFC 7635) is not wanted: only the TURN REST API is used. It can NOT be
# disabled through the TURN_NO_OAUTH environment variable — upstream commented
# that assignment out, so configure pastes an exported TURN_NO_OAUTH verbatim
# into the compiler arguments (a bare "1", which breaks the build). Pass the
# define ourselves instead.
COTURN_EXTRA_CFLAGS := -DTURN_NO_OAUTH

# Hardening applied to everything we compile. -O2 matters: coturn's
# configure/Makefile.in add no -O at all, so without it the relay builds at
# -O0, and _FORTIFY_SOURCE is inert without an optimizer.
HARDENING_CFLAGS  := -O2 -fstack-protector-strong -D_FORTIFY_SOURCE=2
# OpenSSL already builds at -O3; add only the two security flags so we don't
# downgrade its optimization.
OPENSSL_HARDENING := -fstack-protector-strong -D_FORTIFY_SOURCE=2

# Runtime paths baked into the binary. Defaults would point at the throwaway
# build-staging directory, which is gone once the build finishes; use
# conventional system paths instead. --disable-rpath is a no-op for a fully
# static binary but keeps the link line clean.
COTURN_CONFIGURE_EXTRA := --prefix=/usr/local --turndbdir=/var/lib/coturn --disable-rpath
